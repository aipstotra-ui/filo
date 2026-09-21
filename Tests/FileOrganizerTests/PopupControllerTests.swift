import Foundation
import Testing
@testable import FileOrganizer

/// Data-guarding tests for the popup (M5 spec §7, extended by M6). The
/// invariants that matter most are pinned here, not eyeballed:
///   1. `NoMoveAccepting` — still what the app injects — moves NOTHING.
///   2. The (possibly edited) name that becomes a real filename is validated at
///      the Accept boundary — no separators, traversal, or control characters
///      ever reach the hand-off seam.
///   3. The popup closes ONLY on success. A failed move leaves it open with an
///      honest message; closing it would report a lie as a success.
///   4. Hiding the panel mid-move (founder decision 5) never cancels the move,
///      never blocks the queue, and a finished move never resurrects a panel
///      the user sent away.
/// Plus the queue semantics (FIFO, enqueue-once, cap, seam call counts). All
/// windowing and timing are mocked, so no real panel or clock is involved.
@MainActor
@Suite("Popup controller")
struct PopupControllerTests {

    // MARK: - 1. Zero-I/O pin (the hard M5 boundary)

    @Test("NoMoveAccepting.accept performs no filesystem mutation")
    func acceptMovesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopupZeroIO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("Scan 2026-07-20 14.33.pdf")
        try Data("hello".utf8).write(to: source)
        let before = try Self.snapshot(of: dir)

        let accepter = NoMoveAccepting()
        let outcome = await accepter.accept(AcceptedSuggestion(
            fileEventID: UUID(),
            sourceURL: source,
            originalName: "Scan 2026-07-20 14.33.pdf",
            chosenFilename: "2026-06_Chase_Statement.pdf",
            destinationFolderID: 7,
            destinationFolderName: "Invoices"
        ))

        let after = try Self.snapshot(of: dir)
        #expect(before == after,
                "Accept must not move, rename, delete, or create any file")
        #expect(FileManager.default.fileExists(atPath: source.path),
                "the source file must be untouched")
        #expect(outcome == .unchanged,
                "nothing on disk changed and nothing was recorded, so there is nothing to undo")
        // The decision is still recorded in memory, just with no disk effect.
        #expect(accepter.lastAccepted?.chosenFilename == "2026-06_Chase_Statement.pdf")
    }

    // MARK: - 2. Edited-name validation at the Accept boundary

    @Test("Empty or unusable edited names are refused — the seam is never called",
          arguments: ["", "   ", "\n\t ", "///:::...", "\u{0}\u{1B}\r\n"])
    func unusableEditedNameRefused(name: String) async {
        let presenter = MockPresenter()
        let accepter = NoMoveAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        _ = present(controller)

        controller.accept(editedName: name)
        await controller.waitForActiveMoves()

        #expect(accepter.accepted.isEmpty, "an unusable name must not reach the seam")
        #expect(controller.current != nil, "the popup stays open when the name is refused")
        #expect(presenter.hideCount == 0)
    }

    @Test("Dangerous characters never reach the seam in the chosen filename",
          arguments: [
            "bank/state:ment", "../../etc/passwd", "..\\..\\windows\\system32",
            "na\u{202E}me", "re\u{0}port",
          ])
    func dangerousCharsStrippedAtBoundary(name: String) async {
        let accepter = NoMoveAccepting()
        let controller = makeController(accepter: accepter)
        _ = present(controller)

        controller.accept(editedName: name)
        await controller.waitForActiveMoves()

        // Either the hand-off was refused (nil) or it carried a CLEANED name —
        // but never one still containing a separator, traversal, or control char.
        if let chosen = accepter.lastAccepted?.chosenFilename {
            #expect(!chosen.contains("/"))
            #expect(!chosen.contains(":"))
            #expect(!chosen.contains("\\"))
            #expect(!chosen.contains(".."))
            #expect(!chosen.unicodeScalars.contains { $0 == "\u{0}" || $0 == "\u{202E}" })
        }
    }

    @Test("A valid edited name passes through unchanged and closes the popup")
    func validNamePassesThrough() async {
        let presenter = MockPresenter()
        let accepter = NoMoveAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        _ = present(controller, suggested: "Chase Statement June 2026.pdf")

        controller.accept(editedName: "Chase Statement June 2026.pdf")
        await controller.waitForActiveMoves()

        #expect(accepter.accepted.count == 1)
        #expect(accepter.lastAccepted?.chosenFilename == "Chase Statement June 2026.pdf")
        #expect(presenter.hideCount == 1)
        #expect(controller.current == nil)
    }

    @Test("An edited name without an extension gets the real one re-applied")
    func extensionReapplied() async {
        let accepter = NoMoveAccepting()
        let controller = makeController(accepter: accepter)
        _ = present(controller, name: "orig.pdf")

        controller.accept(editedName: "My statement")
        await controller.waitForActiveMoves()

        #expect(accepter.lastAccepted?.chosenFilename == "My statement.pdf")
    }

    // MARK: - 3. Queue semantics

    @Test("Files are shown one at a time in FIFO (detection) order")
    func fifoOrder() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let t0 = Date()
        let a = makeEvent(name: "a.pdf", detectedAt: t0)
        let b = makeEvent(name: "b.pdf", detectedAt: t0.addingTimeInterval(1))
        let c = makeEvent(name: "c.pdf", detectedAt: t0.addingTimeInterval(2))
        // Delivered all at once, in a deliberately shuffled dictionary.
        controller.ingest([
            b.id: settledState(event: b, suggestedName: "B.pdf", destination: .noMatch),
            a.id: settledState(event: a, suggestedName: "A.pdf", destination: .noMatch),
            c.id: settledState(event: c, suggestedName: "C.pdf", destination: .noMatch),
        ])

        #expect(presenter.visible?.fileEventID == a.id, "oldest shows first")
        controller.dismiss()
        #expect(presenter.visible?.fileEventID == b.id)
        controller.dismiss()
        #expect(presenter.visible?.fileEventID == c.id)
        controller.dismiss()
        #expect(presenter.visible == nil)
    }

    @Test("A settled suggestion is enqueued exactly once across repeated publishes")
    func enqueueExactlyOnce() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let a = makeEvent(name: "a.pdf", detectedAt: Date())
        let states = [a.id: settledState(event: a, suggestedName: "A.pdf", destination: .noMatch)]

        // Combine republishes the whole dictionary on every change.
        controller.ingest(states)
        controller.ingest(states)
        controller.ingest(states)
        #expect(presenter.showLog.count == 1, "the same file must not pop repeatedly")

        controller.dismiss()
        controller.ingest(states)   // a decided file never re-pops, even after dismissal
        #expect(presenter.showLog.count == 1)
        #expect(presenter.visible == nil)
    }

    @Test("Unavailable results, pending destinations, and mid-extraction files never pop")
    func onlySettledSuggestionsPop() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let unavailable = makeEvent(name: "u.pdf", detectedAt: Date())
        let pending = makeEvent(name: "p.pdf", detectedAt: Date())
        let extracting = makeEvent(name: "e.pdf", detectedAt: Date())
        let unavailableContent = ExtractedContent(
            event: unavailable, snippet: "s", method: .plainText, wordCount: 1
        )

        controller.ingest([
            unavailable.id: .suggested(unavailableContent, .unavailable(.generationFailed), .quiet),
            pending.id: settledState(event: pending, suggestedName: "P.pdf", destination: .pending),
            extracting.id: .extracting,
        ])

        #expect(presenter.showLog.isEmpty,
                "no popup for unavailable, still-matching, or still-extracting files")
    }

    @Test("A suggestion with a quiet destination still pops — name only, no destination line")
    func quietDestinationPopsNameOnly() {
        // AI named the file but matching produced no verdict (no folders indexed,
        // match backstop, or the matched folder vanished). Spec §1.3: a settled
        // suggestion with dest != .pending pops; .quiet just shows no destination.
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let a = makeEvent(name: "a.zip", detectedAt: Date())

        controller.ingest([a.id: settledState(
            event: a, suggestedName: "Project archive.zip", destination: .quiet
        )])

        #expect(presenter.showLog.count == 1, "a .suggestion result with a .quiet destination pops")
        #expect(presenter.visible?.destination == .quiet, "no destination line for quiet")
        #expect(presenter.visible?.suggestedFilename == "Project archive.zip")
    }

    @Test("A file pops when its destination settles, not while it is pending")
    func popsOnSettle() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let a = makeEvent(name: "a.pdf", detectedAt: Date())

        controller.ingest([a.id: settledState(event: a, suggestedName: "A.pdf", destination: .pending)])
        #expect(presenter.showLog.isEmpty)

        controller.ingest([a.id: settledState(
            event: a, suggestedName: "A.pdf", destination: .match(folderName: "Invoices", folderID: 3)
        )])
        #expect(presenter.showLog.count == 1)
        #expect(presenter.visible?.destination == .folder(name: "Invoices", id: 3))
    }

    @Test("At most three popups wait; a fifth pending file overflows to the menu only")
    func queueCapWithOverflow() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        var states: [UUID: PipelineModel.FileState] = [:]
        var events: [FileEvent] = []
        // Deliver one at a time (the realistic serial path), cumulative dictionary.
        for i in 0..<5 {
            let event = makeEvent(name: "f\(i).pdf", detectedAt: Date().addingTimeInterval(Double(i)))
            events.append(event)
            states[event.id] = settledState(event: event, suggestedName: "F\(i).pdf", destination: .noMatch)
            controller.ingest(states)
        }

        // f0 shows; f1..f3 wait (cap = 3); f4 overflows.
        #expect(presenter.visible?.fileEventID == events[0].id)
        var shownIDs = [events[0].id]
        for _ in 0..<4 {
            controller.dismiss()
            if let visible = presenter.visible { shownIDs.append(visible.fileEventID) }
        }
        #expect(shownIDs == [events[0].id, events[1].id, events[2].id, events[3].id])
        #expect(presenter.visible == nil)
        #expect(!shownIDs.contains(events[4].id),
                "the 5th settled file overflowed the cap-3 queue and stays menu-only")
    }

    @Test("Accept builds the decision with folder identity and calls the seam once")
    func acceptBuildsDecision() async {
        let presenter = MockPresenter()
        let accepter = NoMoveAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let event = present(
            controller, name: "Scan 2026.pdf", suggested: "Chase Statement.pdf",
            destination: .match(folderName: "Invoices", folderID: 42)
        )

        controller.accept(editedName: "Chase Statement.pdf")
        await controller.waitForActiveMoves()

        #expect(accepter.accepted.count == 1, "the seam is called exactly once")
        let decision = accepter.lastAccepted
        #expect(decision?.fileEventID == event.id)
        #expect(decision?.originalName == "Scan 2026.pdf")
        #expect(decision?.chosenFilename == "Chase Statement.pdf")
        #expect(decision?.destinationFolderID == 42)
        #expect(decision?.destinationFolderName == "Invoices")
        #expect(presenter.hideCount == 1)
        #expect(controller.current == nil)
    }

    @Test("Accepting a no-folder suggestion carries a nil destination")
    func acceptNoFolderCarriesNilDestination() async {
        let accepter = NoMoveAccepting()
        let controller = makeController(accepter: accepter)
        _ = present(controller, name: "img.heic", suggested: "Whiteboard notes.heic", destination: .noMatch)

        controller.accept(editedName: "Whiteboard notes.heic")
        await controller.waitForActiveMoves()

        #expect(accepter.lastAccepted?.destinationFolderID == nil)
        #expect(accepter.lastAccepted?.destinationFolderName == nil)
        #expect(accepter.lastAccepted?.chosenFilename == "Whiteboard notes.heic")
    }

    @Test("Dismiss closes without calling the seam")
    func dismissCallsSeamZeroTimes() {
        let presenter = MockPresenter()
        let accepter = NoMoveAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        _ = present(controller)

        controller.dismiss()

        #expect(accepter.accepted.isEmpty)
        #expect(presenter.hideCount == 1)
        #expect(controller.current == nil)
    }

    @Test("Auto-dismiss closes without calling the seam")
    func autoDismissCallsSeamZeroTimes() {
        let presenter = MockPresenter()
        let accepter = NoMoveAccepting()
        let scheduler = ManualScheduler()
        let controller = makeController(presenter: presenter, accepter: accepter, scheduler: scheduler)
        _ = present(controller)

        #expect(scheduler.liveTimerCount == 1, "a countdown starts when the popup shows")
        scheduler.fireLatest()   // simulate the ~15 s elapsing

        #expect(accepter.accepted.isEmpty, "auto-dismiss performs no action")
        #expect(presenter.hideCount == 1)
        #expect(controller.current == nil)
    }

    @Test("Accept is idempotent — a second call after closing does not re-fire the seam")
    func acceptIsIdempotent() async {
        let accepter = NoMoveAccepting()
        let controller = makeController(accepter: accepter)
        _ = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        controller.accept(editedName: "A.pdf")   // e.g. Return in field + default-action button
        await controller.waitForActiveMoves()

        #expect(accepter.accepted.count == 1, "the seam fires exactly once per popup")
    }

    @Test("A stale Accept callback from a closed popup never acts on the next queued popup")
    func staleCallbackDoesNotHitNextPopup() async throws {
        let presenter = MockPresenter()
        let accepter = NoMoveAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = makeEvent(name: "a.pdf", detectedAt: Date())
        let b = makeEvent(name: "b.pdf", detectedAt: Date().addingTimeInterval(1))
        controller.ingest([
            a.id: settledState(event: a, suggestedName: "A.pdf", destination: .noMatch),
            b.id: settledState(event: b, suggestedName: "B.pdf", destination: .noMatch),
        ])

        // A is on screen, B is queued behind it. Grab A's callbacks — the exact
        // closures A's view holds. A single Return can fire the field's onSubmit
        // AND the default-action button: two onAccept calls from A's view.
        #expect(presenter.visible?.fileEventID == a.id)
        let aCallbacks = try #require(presenter.lastCallbacks)

        aCallbacks.onAccept("A.pdf")   // first fire: accepts A, which starts a move
        // Accept no longer advances the queue on its own — the popup stays on
        // screen in its moving state until the seam answers. Only once A's move
        // completes does the queue advance, which is what puts B on screen and
        // makes A's surviving callbacks genuinely stale.
        #expect(presenter.visible?.fileEventID == a.id, "A stays up while its move runs")
        await controller.waitForActiveMoves()
        #expect(presenter.visible?.fileEventID == b.id, "A's completed move advances to the queued B")

        aCallbacks.onAccept("A.pdf")   // stale second fire from A's now-closed view
        // Await again before judging: a move crosses the seam on a Task, so an
        // unguarded stale accept would not have reached `accepter` yet. Without
        // this the assertions below pass even with the identity guard deleted —
        // verified by mutation, and the reason this wait exists.
        await controller.waitForActiveMoves()

        #expect(accepter.accepted.count == 1, "the stale callback must not accept B")
        #expect(accepter.lastAccepted?.fileEventID == a.id, "only A was ever accepted")
        #expect(presenter.visible?.fileEventID == b.id, "B is still on screen, untouched")
    }

    // MARK: - The move in flight (M6)

    @Test("A failed move keeps the popup open with its error — it never closes as success")
    func failedMoveKeepsPopupOpen() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")
        present(controller, name: "b.pdf", suggested: "B.pdf",
                detectedAt: Date().addingTimeInterval(1))

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        #expect(controller.activity == PopupActivity.moving)

        accepter.complete(a.id, with: .failed(.historyUnavailable(detail: "disk full")))
        await controller.waitForActiveMoves()

        // This is the bug M6 exists to kill: a failure that closes the popup
        // would read as success, and the file would silently still be in Downloads.
        #expect(presenter.visible?.fileEventID == a.id, "the failed popup stays on screen")
        #expect(presenter.hideCount == 0, "nothing was hidden")
        if case .failed(let message, _) = controller.activity {
            #expect(!message.isEmpty, "the user is told what went wrong")
        } else {
            Issue.record("expected the failed state, got \(controller.activity)")
        }
    }

    @Test("M6: every activity change is pushed to the panel on screen")
    func activityChangesReachThePanel() async throws {
        // The controller knowing it failed is worth nothing on its own. Before
        // this, `activity` had no readers at all and `PanelPresenting` could
        // only show and hide — so a failed move left the popup looking exactly
        // as it did before the click, which reads as "my Accept didn't
        // register". This asserts on what the panel was actually told.
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }

        #expect(presenter.activityLog == [.moving],
                "the panel is told a move started, so it can show 'Moving…'")

        accepter.complete(a.id, with: .failed(.historyUnavailable(detail: "disk full")))
        await controller.waitForActiveMoves()

        #expect(presenter.activityLog.count == 2)
        if case .failed(let message, _) = presenter.activityLog.last {
            #expect(!message.isEmpty, "and it is told what to say when the move fails")
        } else {
            Issue.record("the panel was never told about the failure: \(presenter.activityLog)")
        }
    }

    @Test("M6: a successful move never leaves a stale failure on the next popup")
    func activityResetsForTheNextPopup() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")
        present(controller, name: "b.pdf", suggested: "B.pdf",
                detectedAt: Date().addingTimeInterval(1))

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        accepter.complete(a.id, with: .failed(.historyUnavailable(detail: "disk full")))
        await controller.waitForActiveMoves()
        #expect(controller.activity != PopupActivity.editing, "guard: A really did fail")

        // Dismissing A advances to B, which has not been touched at all.
        controller.dismiss()

        #expect(controller.activity == PopupActivity.editing,
                "B must not inherit A's failure message")
        #expect(presenter.activityLog.last == .editing,
                "and the panel must be told, not just the controller")
    }

    @Test("Accept is available again after a failure, so the user can retry")
    func acceptRetriesAfterFailure() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        accepter.complete(a.id, with: .failed(.historyUnavailable(detail: "disk full")))
        await controller.waitForActiveMoves()

        controller.accept(editedName: "A better name.pdf")
        await waitUntil { accepter.inFlightCount == 1 }

        #expect(accepter.accepted.count == 2, "the retry reaches the seam")
        #expect(accepter.accepted.last?.chosenFilename == "A better name.pdf",
                "the retry carries the user's edit")
    }

    @Test("The auto-dismiss countdown cannot take the panel away mid-move")
    func autoDismissNeverFiresDuringAMove() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let scheduler = ManualScheduler()
        let controller = makeController(
            presenter: presenter, accepter: accepter, scheduler: scheduler
        )
        let a = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }

        scheduler.fireLatest()   // a timer that somehow survived the cancel

        #expect(presenter.visible?.fileEventID == a.id, "the panel is still there")
        #expect(presenter.hideCount == 0, "a move must never be hidden by a timer")

        accepter.complete(a.id, with: .moved(Self.summary()))
        await controller.waitForActiveMoves()
        #expect(presenter.hideCount == 1, "and it closes normally once the move succeeds")
    }

    @Test("Hiding mid-move does not cancel it — the move still completes and still records")
    func hidingMidMoveDoesNotCancelIt() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }

        controller.dismiss()   // the "Hide" button, or Esc, during the move
        #expect(presenter.visible == nil, "the panel is out of the way immediately")

        accepter.complete(a.id, with: .moved(Self.summary()))
        await controller.waitForActiveMoves()

        // Founder decision 5: Hide is not Cancel. The move runs to completion and
        // its outcome is recorded, which is what the history list will show.
        #expect(accepter.accepted.count == 1, "the move was never abandoned")
        #expect(accepter.accepted.first?.fileEventID == a.id)
    }

    @Test("A move that finishes after its panel was hidden never resurrects the panel")
    func completedMoveDoesNotResurrectAHiddenPopup() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        controller.dismiss()
        let showsBeforeCompletion = presenter.showLog.count

        // Even a failure must not reopen it — the user sent this panel away.
        accepter.complete(a.id, with: .failed(.historyUnavailable(detail: "disk full")))
        await controller.waitForActiveMoves()

        #expect(presenter.visible == nil, "nothing came back on screen")
        #expect(presenter.showLog.count == showsBeforeCompletion, "no popup was re-shown")
    }

    @Test("Hiding a popup mid-move frees the queue — the next file is not blocked behind it")
    func hidingMidMoveDoesNotBlockTheQueue() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")
        let b = makeEvent(name: "b.pdf", detectedAt: Date().addingTimeInterval(1))
        controller.ingest([b.id: settledState(
            event: b, suggestedName: "B.pdf", destination: .noMatch
        )])

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        #expect(presenter.visible?.fileEventID == a.id, "B waits while A moves")

        controller.dismiss()
        #expect(presenter.visible?.fileEventID == b.id, "hiding A lets B through at once")

        accepter.complete(a.id, with: .moved(Self.summary()))
        await controller.waitForActiveMoves()

        #expect(presenter.visible?.fileEventID == b.id, "B is still up, untouched by A's result")
        #expect(accepter.accepted.count == 1, "A's completion never accepted B")
    }

    /// Yields until `condition` holds. A move crosses the seam on a Task, so a
    /// test cannot observe the in-flight state without letting that Task run.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never became true")
    }

    // MARK: - Telling the user the name changed (M5, founder-reported 2026-07-28)

    @Test("A move that had to rename for a collision does NOT close silently")
    func collisionRenameIsSurfaced() async throws {
        // Reported from live use: two files were suggested the same name. The
        // mover deduped correctly and nothing was overwritten — but the popup
        // closed as an ordinary success, so the only way to discover the file
        // had been given a different name was to go and open the folder.
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "Aiden_Chung.pdf")

        controller.accept(editedName: "Aiden_Chung.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        accepter.complete(a.id, with: .moved(Self.summary(
            finalName: "Aiden_Chung 2.pdf",
            requestedName: "Aiden_Chung.pdf",
            wasRenamedForCollision: true
        )))
        await controller.waitForActiveMoves()

        #expect(presenter.visible?.fileEventID == a.id, "the popup stays up to say so")
        #expect(presenter.hideCount == 0)
        guard case .completed(let notice) = controller.activity else {
            Issue.record("expected the completed-with-notice state, got \(controller.activity)")
            return
        }
        // Both names, so the user knows exactly what happened and what to look for.
        #expect(notice.contains("Aiden_Chung.pdf"))
        #expect(notice.contains("Aiden_Chung 2.pdf"))
        #expect(notice.contains("Nothing was overwritten"))
        #expect(presenter.activityLog.last == .completed(notice: notice),
                "and the panel is told, not just the controller")
    }

    @Test("A move that went exactly as asked still closes without ceremony")
    func cleanMoveClosesSilently() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        accepter.complete(a.id, with: .moved(Self.summary(finalName: "A.pdf")))
        await controller.waitForActiveMoves()

        #expect(controller.current == nil, "nothing surprising happened — no notice to read")
        #expect(presenter.hideCount == 1)
    }

    @Test("After a notice the popup offers no Accept — the file has already moved")
    func noticeStateOffersNoSecondMove() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "Aiden_Chung.pdf")

        controller.accept(editedName: "Aiden_Chung.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        accepter.complete(a.id, with: .moved(Self.summary(
            finalName: "Aiden_Chung 2.pdf",
            requestedName: "Aiden_Chung.pdf",
            wasRenamedForCollision: true
        )))
        await controller.waitForActiveMoves()

        // Pressing Accept again would try to move a file that is no longer at
        // the path this popup knows about: the move succeeded, so the source is
        // gone, the retry fails, and a `failed` history row gets written about a
        // move that in fact worked (F13).
        //
        // NOTE the shape of this assertion. It used to `await
        // waitForActiveMoves()` here, which hung the ENTIRE suite forever: the
        // guard did not hold, a second move really did start, and nothing ever
        // completed it. A test that hangs reports nothing — so this one now
        // observes the count directly and never awaits a move that must never
        // have existed.
        controller.accept(editedName: "Aiden_Chung.pdf")
        await Task.yield()

        #expect(accepter.accepted.count == 1, "a second move must not be startable")
        #expect(accepter.inFlightCount == 0, "and none may be left running")
        guard case .completed = controller.activity else {
            Issue.record("the refused accept must leave the state alone, got \(controller.activity)")
            return
        }
        controller.dismiss()
        #expect(controller.current == nil, "and OK/Esc closes it normally")
    }

    // MARK: - F2 / A5: the degraded seam, and what a success says out loud

    @Test("F2: with no history database the popup does NOT close as success")
    func degradedSeamNeverClosesAsSuccess() async {
        // The shape of the bug: `history.db` won't open → the app fell back to
        // an accepter returning `.unchanged`, which is a success → the popup
        // closed exactly as it does after a real move, while the file sat
        // untouched in Downloads with no row and no message anywhere. Founder
        // decision 1 is fail *closed*, and closed has to be visible.
        let presenter = MockPresenter()
        let accepter = AlwaysRefusingAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        _ = present(controller, suggested: "Statement.pdf")

        controller.accept(editedName: "Statement.pdf")
        await controller.waitForActiveMoves()

        #expect(presenter.hideCount == 0, "the popup must stay on screen")
        #expect(controller.current != nil)
        guard case .failed(let message, _) = controller.activity else {
            Issue.record("expected an honest failure, got \(controller.activity)")
            return
        }
        #expect(message.contains("untouched"), "and it says the file was not touched")
    }

    @Test("F2: the app's real fallback accepter refuses rather than reporting success")
    func refusingAcceptingRefuses() async {
        // Pins the type `App.swift` actually injects, so swapping it back to
        // `NoMoveAccepting` fails here rather than in front of the founder.
        let outcome = await RefusingAccepting().accept(AcceptedSuggestion(
            fileEventID: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/x.pdf"),
            originalName: "x.pdf",
            chosenFilename: "y.pdf",
            destinationFolderID: nil,
            destinationFolderName: nil
        ))

        guard case .failed(.historyUnavailable) = outcome else {
            Issue.record("the degraded seam must fail closed, got \(outcome)")
            return
        }
    }

    @Test("A5: a move that succeeds cleanly is spoken before the popup vanishes")
    func successIsAnnounced() async {
        // Success closes the popup, so there is no state left for a view to
        // announce. Without this the entire success path is silent to VoiceOver
        // — the panel simply disappears.
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        accepter.complete(a.id, with: .moved(Self.summary(finalName: "A.pdf")))
        await controller.waitForActiveMoves()

        let spoken = try? #require(presenter.announcements.last)
        #expect(spoken?.contains("A.pdf") == true, "it names the file")
        #expect(presenter.hideCount == 1, "and the popup still closes")
    }

    @Test("A5: the spoken success line names the destination folder when there is one")
    func successAnnouncementNamesTheFolder() {
        let withFolder = PopupController.successAnnouncement(for: Self.summary(
            finalName: "Statement.pdf", folderName: "Invoices"
        ))
        #expect(withFolder == "Moved. Statement.pdf is now in Invoices.")

        let renameInPlace = PopupController.successAnnouncement(for: Self.summary(
            finalName: "Statement.pdf", folderName: nil
        ))
        #expect(renameInPlace == "Renamed to Statement.pdf.")
    }

    // MARK: - Reopening from the menu (M5 hand-off #3)

    @Test("A dismissed file can be brought back from its menu row")
    func reopenBringsBackADismissedFile() {
        // Without this there was no way to act on a file at all once it had been
        // dismissed or had overflowed the queue — it sat in the menu, read-only,
        // forever.
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let a = present(controller, suggested: "A.pdf")
        controller.dismiss()
        #expect(presenter.visible == nil, "guard: it really is gone")

        #expect(controller.canReopen(fileEventID: a.id))
        controller.reopen(fileEventID: a.id)

        #expect(presenter.visible?.fileEventID == a.id)
        #expect(controller.current?.fileEventID == a.id)
    }

    @Test("An overflow file — one that never got a popup — can be reopened")
    func reopenReachesAnOverflowFile() {
        // The queue is capped, so a burst of downloads leaves later files with
        // no popup at all. They are exactly the ones this exists for.
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        var events: [FileEvent] = []
        for index in 0...(PopupController.maxQueued + 2) {
            events.append(present(
                controller,
                name: "file-\(index).pdf",
                suggested: "Name \(index).pdf",
                detectedAt: Date().addingTimeInterval(Double(index))
            ))
        }
        let overflowed = events.last!
        #expect(presenter.showLog.contains { $0.fileEventID == overflowed.id } == false,
                "guard: this file never got a popup on its own")

        controller.reopen(fileEventID: overflowed.id)

        #expect(presenter.visible?.fileEventID == overflowed.id)
    }

    @Test("Reopening the file whose move is running does NOT start a second move")
    func reopenIsRefusedWhileThatFileIsMoving() async throws {
        let presenter = MockPresenter()
        let accepter = ControllableAccepting()
        let controller = makeController(presenter: presenter, accepter: accepter)
        let a = present(controller, suggested: "A.pdf")

        controller.accept(editedName: "A.pdf")
        await waitUntil { accepter.inFlightCount == 1 }
        // Founder decision 5: the user hides the panel; the move carries on.
        controller.dismiss()

        #expect(controller.canReopen(fileEventID: a.id) == false,
                "its move is still running — there is nothing to decide again")
        controller.reopen(fileEventID: a.id)

        #expect(presenter.visible?.fileEventID != a.id)
        #expect(accepter.accepted.count == 1, "a second move must never be startable")

        accepter.complete(a.id, with: .moved(Self.summary()))
        await controller.waitForActiveMoves()
    }

    @Test("Reopening the popup already on screen does nothing")
    func reopenIsANoOpForTheCurrentPopup() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let a = present(controller, suggested: "A.pdf")

        #expect(controller.canReopen(fileEventID: a.id) == false)
        controller.reopen(fileEventID: a.id)

        #expect(presenter.showLog.count == 1, "no flicker, no re-show")
    }

    @Test("Reopening a file with no settled suggestion is refused")
    func reopenRefusesAnUnsettledFile() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let event = makeEvent(name: "still-reading.pdf", detectedAt: Date())
        controller.ingest([event.id: .extracting])

        #expect(controller.canReopen(fileEventID: event.id) == false)
        controller.reopen(fileEventID: event.id)

        #expect(presenter.visible == nil, "there is no suggestion to show yet")
    }

    // MARK: - Snapshot & pruning behavior

    @Test("A shown popup renders from its enqueue-time snapshot, not later state")
    func popupUsesEnqueueSnapshot() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let a = makeEvent(name: "a.pdf", detectedAt: Date())

        controller.ingest([a.id: settledState(
            event: a, suggestedName: "First.pdf", destination: .match(folderName: "Invoices", folderID: 1)
        )])
        #expect(presenter.visible?.suggestedFilename == "First.pdf")

        // The pipeline re-suggests a different name/destination for the same file.
        controller.ingest([a.id: settledState(
            event: a, suggestedName: "Second.pdf", destination: .match(folderName: "Taxes", folderID: 2)
        )])
        #expect(presenter.visible?.suggestedFilename == "First.pdf",
                "the shown popup is frozen to its snapshot")
        #expect(presenter.showLog.count == 1)
    }

    @Test("A queued file pruned before it is shown is skipped, not shown stale")
    func prunedQueuedItemSkipped() {
        let presenter = MockPresenter()
        let controller = makeController(presenter: presenter)
        let a = makeEvent(name: "a.pdf", detectedAt: Date().addingTimeInterval(0))
        let b = makeEvent(name: "b.pdf", detectedAt: Date().addingTimeInterval(1))
        let aState = settledState(event: a, suggestedName: "A.pdf", destination: .noMatch)
        let bState = settledState(event: b, suggestedName: "B.pdf", destination: .noMatch)

        controller.ingest([a.id: aState, b.id: bState])   // a shows, b queued
        #expect(presenter.visible?.fileEventID == a.id)

        controller.ingest([a.id: aState])   // b pruned from fileStates while waiting
        controller.dismiss()                 // advancing must skip the pruned b

        #expect(presenter.visible == nil, "a pruned queued file is not shown")
        #expect(presenter.showLog.map(\.fileEventID) == [a.id])
    }

    // MARK: - Auto-dismiss yields to interaction & assistive tech (a11y must-fix #3)

    @Test("Hovering the panel pauses the auto-dismiss countdown; leaving resumes it")
    func hoverPausesAutoDismiss() {
        let scheduler = ManualScheduler()
        let controller = makeController(scheduler: scheduler)
        _ = present(controller)

        #expect(scheduler.liveTimerCount == 1)
        controller.setPointerInside(true)
        #expect(scheduler.liveTimerCount == 0, "no live countdown while hovering")
        controller.setPointerInside(false)
        #expect(scheduler.liveTimerCount == 1, "countdown resumes when the pointer leaves")
    }

    @Test("The panel becoming key (e.g. editing the field) pauses auto-dismiss")
    func keyPausesAutoDismiss() {
        let scheduler = ManualScheduler()
        let controller = makeController(scheduler: scheduler)
        _ = present(controller)

        controller.setPanelKey(true)
        #expect(scheduler.liveTimerCount == 0, "no countdown while the user is interacting")
        controller.setPanelKey(false)
        #expect(scheduler.liveTimerCount == 1)
    }

    @Test("Auto-dismiss never starts while VoiceOver / Full Keyboard Access is active")
    func noAutoDismissUnderAssistiveTech() {
        let scheduler = ManualScheduler()
        let controller = makeController(scheduler: scheduler, accessibility: StubAccessibility(persistent: true))
        _ = present(controller)

        #expect(scheduler.liveTimerCount == 0,
                "assistive tech requires an explicit choice — the popup must not auto-close")
        #expect(controller.current != nil)
    }

    // MARK: - Helpers

    // Defaults are built in the body (not as default arguments) because a
    // default-argument expression is evaluated in a nonisolated context, and
    // these test doubles are @MainActor.
    private func makeController(
        presenter: MockPresenter? = nil,
        accepter: (any SuggestionAccepting)? = nil,
        scheduler: ManualScheduler? = nil,
        accessibility: AccessibilityStatusReading? = nil
    ) -> PopupController {
        PopupController(
            presenter: presenter ?? MockPresenter(),
            accepter: accepter ?? NoMoveAccepting(),
            scheduler: scheduler ?? ManualScheduler(),
            accessibility: accessibility ?? StubAccessibility()
        )
    }

    /// Delivers one settled suggestion and returns its event (so the caller has
    /// the id). The popup is shown synchronously.
    @discardableResult
    private func present(
        _ controller: PopupController,
        name: String = "orig.pdf",
        suggested: String = "Chase Statement June 2026.pdf",
        destination: PipelineModel.DestinationState = .match(folderName: "Invoices", folderID: 7),
        detectedAt: Date = Date()
    ) -> FileEvent {
        let event = makeEvent(name: name, detectedAt: detectedAt)
        controller.ingest([event.id: settledState(
            event: event, suggestedName: suggested, destination: destination
        )])
        return event
    }

    private func makeEvent(name: String, detectedAt: Date) -> FileEvent {
        FileEvent(
            url: URL(fileURLWithPath: "/Users/someone/Downloads/\(name)"),
            size: 1234, detectedAt: detectedAt
        )
    }

    private func settledState(
        event: FileEvent, suggestedName: String, destination: PipelineModel.DestinationState
    ) -> PipelineModel.FileState {
        let content = ExtractedContent(event: event, snippet: "snippet", method: .plainText, wordCount: 10)
        let suggestion = AISuggestion(summary: "summary", suggestedFilename: suggestedName, embedding: nil)
        return .suggested(content, .suggestion(suggestion), destination)
    }

    /// A plausible successful-move result, for tests that only care that the
    /// outcome was a success rather than what it contained.
    private static func summary(
        finalName: String = "A.pdf",
        requestedName: String? = nil,
        wasRenamedForCollision: Bool = false,
        folderName: String? = "Invoices"
    ) -> MoveSummary {
        MoveSummary(
            recordID: 1,
            finalURL: URL(fileURLWithPath: "/Users/someone/Invoices/\(finalName)"),
            destinationFolderName: folderName,
            fallbackReason: nil,
            wasRenamedForCollision: wasRenamedForCollision,
            requestedName: requestedName ?? finalName
        )
    }

    /// A sorted "relative-path:size" listing of a directory tree — any move,
    /// rename, delete, or create changes it.
    private static func snapshot(of dir: URL) throws -> [String] {
        let manager = FileManager.default
        return try manager.subpathsOfDirectory(atPath: dir.path).sorted().map { relative in
            let attrs = try manager.attributesOfItem(
                atPath: dir.appendingPathComponent(relative).path
            )
            let size = (attrs[.size] as? Int) ?? -1
            return "\(relative):\(size)"
        }
    }
}

// MARK: - Test doubles (AppKit- and clock-free)

/// Records what was shown/hidden without any real window.
@MainActor
final class MockPresenter: PanelPresenting {
    private(set) var showLog: [PopupSuggestion] = []
    private(set) var hideCount = 0
    private(set) var visible: PopupSuggestion?
    /// The callbacks handed to the most recent `show` — lets a test fire a
    /// popup's accept/dismiss the way the real view would.
    private(set) var lastCallbacks: PopupCallbacks?
    /// Every activity pushed to the panel, in order. This is what the user
    /// would actually have seen — asserting on the controller's own `activity`
    /// property alone would pass even if nothing ever reached the screen (M6).
    private(set) var activityLog: [PopupActivity] = []
    /// Every line spoken to VoiceOver, in order. A move that succeeds closes the
    /// popup, so this is the only record that anything was said at all (A5).
    private(set) var announcements: [String] = []

    func show(_ suggestion: PopupSuggestion, callbacks: PopupCallbacks) {
        showLog.append(suggestion)
        visible = suggestion
        lastCallbacks = callbacks
    }

    func update(activity: PopupActivity) {
        activityLog.append(activity)
    }

    func announce(_ message: String) {
        announcements.append(message)
    }

    func hide() {
        hideCount += 1
        visible = nil
    }
}

/// A hand-driven clock: timers do not fire until the test fires them.
@MainActor
final class ManualScheduler: PopupScheduling {
    final class Token: PopupTimerToken {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    private(set) var scheduled: [(token: Token, action: () -> Void)] = []

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> PopupTimerToken {
        let token = Token()
        scheduled.append((token, action))
        return token
    }

    /// Fires the most recently scheduled, still-live timer (simulates the delay).
    func fireLatest() {
        guard let last = scheduled.last, !last.token.cancelled else { return }
        last.action()
    }

    /// How many scheduled timers have not been cancelled.
    var liveTimerCount: Int { scheduled.filter { !$0.token.cancelled }.count }
}

/// A seam a test can hold open. `accept` records the decision and then suspends
/// until the test releases it with a chosen outcome, so the popup's in-flight
/// state — and what happens when a move lands late — can be observed exactly.
@MainActor
final class ControllableAccepting: SuggestionAccepting {
    private(set) var accepted: [AcceptedSuggestion] = []
    private var waiting: [UUID: CheckedContinuation<AcceptOutcome, Never>] = [:]

    /// Moves currently suspended at the seam.
    var inFlightCount: Int { waiting.count }

    func accept(_ decision: AcceptedSuggestion) async -> AcceptOutcome {
        accepted.append(decision)
        return await withCheckedContinuation { continuation in
            waiting[decision.fileEventID] = continuation
        }
    }

    /// Lets a held move finish with the given outcome.
    func complete(_ fileEventID: UUID, with outcome: AcceptOutcome) {
        waiting.removeValue(forKey: fileEventID)?.resume(returning: outcome)
    }
}

/// Always refuses, the way the app's seam does when `history.db` will not open.
@MainActor
private final class AlwaysRefusingAccepting: SuggestionAccepting {
    private(set) var callCount = 0
    func accept(_ decision: AcceptedSuggestion) async -> AcceptOutcome {
        callCount += 1
        return .failed(.historyUnavailable(detail: "no database"))
    }
}

/// Fixed VoiceOver / Full Keyboard Access answer for tests.
@MainActor
final class StubAccessibility: AccessibilityStatusReading {
    var wantsPersistentInteraction: Bool
    init(persistent: Bool = false) { wantsPersistentInteraction = persistent }
}
