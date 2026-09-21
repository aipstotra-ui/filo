import Foundation
import Testing
@testable import FileOrganizer

/// The words in Settings › History. This milestone exists so the user is never
/// misled about what happened to their file, and "never misled" is a property of
/// these sentences — so they are pinned here rather than eyeballed.
///
/// The two rules underneath every case, from the founder-approved mockup:
/// **the app never offers an action it cannot actually perform, and never claims
/// knowledge it does not have.**
/// `@MainActor` because the day-grouping helpers are: their `DateFormatter`
/// statics are main-actor-isolated so they are not shared mutable globals (X6).
@MainActor
@Suite("History row presentation")
struct HistoryRowPresentationTests {

    private let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
    private let invoices = URL(fileURLWithPath: "/Users/test/Invoices", isDirectory: true)

    private func record(
        state: MoveState,
        originalName: String = "chase_stmt_2026-06 (1).pdf",
        finalName: String = "2026-06 Chase statement.pdf",
        finalDirectory: URL? = nil,
        folderName: String? = "Invoices",
        fallbackReason: MoveFallbackReason? = nil,
        failureDetail: String? = nil
    ) -> MoveRecord {
        MoveRecord(
            id: 1,
            fileEventID: UUID(),
            originalDirectory: downloads,
            originalName: originalName,
            finalDirectory: finalDirectory ?? invoices,
            finalName: finalName,
            destinationFolderName: folderName,
            state: state,
            fallbackReason: fallbackReason,
            failureDetail: failureDetail,
            sourceIdentity: nil,
            acceptedAt: Date(timeIntervalSince1970: 1_800_000_000),
            settledAt: Date(timeIntervalSince1970: 1_800_000_060)
        )
    }

    // MARK: - The everyday cases

    @Test("A moved file leads with the name it has NOW, and offers Undo")
    func movedRow() {
        let row = HistoryRowPresentation(record: record(state: .moved))

        // Line 1 is what you would type into Spotlight — the reversal from the
        // popup, which leads with the old name, is deliberate.
        #expect(row.currentName == "2026-06 Chase statement.pdf")
        #expect(row.headline == "Moved to")
        #expect(row.headlineFolder == "Invoices")
        #expect(row.detail == "was chase_stmt_2026-06 (1).pdf")
        #expect(row.tone == .normal)
        #expect(row.showsUndo)
    }

    @Test("A rename in place says WHY, naming the folder that wasn't there")
    func renamedInPlaceRow() {
        // Founder decision 2: the destination folder was unusable, so the file
        // was renamed where it is. Closing as a silent success would leave the
        // user believing it reached Receipts.
        let row = HistoryRowPresentation(record: record(
            state: .moved,
            originalName: "rent-receipt-june.pdf",
            finalName: "2026-06 Rent receipt.pdf",
            finalDirectory: downloads,
            folderName: "Receipts",
            fallbackReason: .folderMissing
        ))

        #expect(row.headline == "Renamed in Downloads — Receipts isn't there any more")
        #expect(row.headlineFolder == nil, "the folder is named inside the sentence here")
        #expect(row.tone == .caution, "the file is fine, but not what was asked for")
        #expect(row.showsUndo, "it still moved, so it can still be put back")
    }

    @Test("Every fallback reason names the folder rather than saying 'that folder'",
          arguments: MoveFallbackReason.allCases)
    func fallbackReasonsNameTheFolder(reason: MoveFallbackReason) {
        let row = HistoryRowPresentation(record: record(
            state: .moved, folderName: "Tax & Accounting 2026", fallbackReason: reason
        ))

        #expect(row.headline.contains("Tax & Accounting 2026"))
        #expect(!row.headline.contains("that folder"),
                "the row has room for the real name; the generic wording is for the popup")
    }

    @Test("A fallback with no folder name still reads as a sentence")
    func fallbackWithoutAFolderName() {
        let row = HistoryRowPresentation(record: record(
            state: .moved, folderName: nil, fallbackReason: .folderMissing
        ))

        #expect(row.headline == "Renamed in Downloads — that folder isn't there any more")
    }

    // MARK: - The honest answers when something went wrong

    @Test("A failed move leads with the name the file ACTUALLY has, and offers NO undo")
    func failedRow() {
        // F3, and the fixture is the finding. This used to pass `originalName`
        // and `finalName` identical — a rename that renames nothing, which is
        // not what a failed accept produces. With them the same, a row leading
        // with the wrong one looks exactly like a row leading with the right
        // one, so the test could not see the bug it was written to catch.
        //
        // `recordIntent` writes `final_name = intendedName` and `markFailed`
        // never rewrites it. So the row's most prominent field was the app's
        // *intended* name — the one name the file is guaranteed NOT to have —
        // above a line reading "Still in Downloads under this name."
        let row = HistoryRowPresentation(record: record(
            state: .failed,
            originalName: "statement(1).pdf",
            finalName: "2026-05 Chase statement.pdf",
            failureDetail: "Couldn't move — macOS wouldn't let this app write into Tax & Accounting 2026"
        ))

        #expect(row.currentName == "statement(1).pdf",
                "what you would type into Spotlight right now")
        #expect(row.currentName != "2026-05 Chase statement.pdf",
                "the intended name never reached the file")
        #expect(row.headline.hasPrefix("Couldn't move"))
        #expect(row.detail == "Still in Downloads under this name. Nothing was changed.")
        #expect(row.tone == .failure)
        #expect(row.showsUndo == false, "there is nothing to undo — nothing happened")
    }

    @Test("An unknown row leads with the original name too — the move was never confirmed")
    func unknownRowLeadsWithTheOriginalName() {
        let row = HistoryRowPresentation(record: record(
            state: .unknown,
            originalName: "statement(1).pdf",
            finalName: "2026-05 Chase statement.pdf"
        ))

        #expect(row.currentName == "statement(1).pdf",
                "the app cannot prove the file was ever renamed, so it claims nothing")
    }

    @Test("A failed row with no stored detail still says something honest")
    func failedRowWithoutDetail() {
        let row = HistoryRowPresentation(record: record(state: .failed, failureDetail: nil))

        #expect(!row.headline.isEmpty)
        #expect(row.showsUndo == false)
    }

    @Test("An unknown result names BOTH places to look and offers no undo")
    func unknownRow() {
        // The app stopped mid-move and cannot prove where the file went.
        // Guessing here is exactly what C2 was: it could relocate a file the app
        // never touched.
        let row = HistoryRowPresentation(record: record(
            state: .unknown,
            originalName: "lease-agreement-signed.pdf",
            finalName: "Lease agreement 2026.pdf",
            finalDirectory: URL(fileURLWithPath: "/Users/test/Documents", isDirectory: true),
            folderName: "Documents"
        ))

        #expect(row.headline == "Result unknown — the app stopped mid-move")
        let detail = try? #require(row.detail)
        #expect(detail?.contains("Downloads for lease-agreement-signed.pdf") == true)
        #expect(detail?.contains("Documents for Lease agreement 2026.pdf") == true)
        #expect(detail?.contains("can't confirm") == true)
        #expect(row.showsUndo == false, "an unknown row must NEVER offer undo")
    }

    @Test("A cross-volume move whose original survived is flagged, not called tidy")
    func movedButOriginalRemained() {
        // C1/M13: the copy succeeded and the original could not be removed, so
        // the user has a duplicate. That is exactly the thing they must hear.
        let row = HistoryRowPresentation(record: record(
            state: .moved,
            failureDetail: "the original couldn't be removed"
        ))

        #expect(row.tone == .caution, "a duplicate left behind is not a clean success")
        #expect(row.detail?.contains("the original couldn't be removed") == true)
        #expect(row.showsUndo)
    }

    // MARK: - Undo's own outcomes

    @Test("An undone row says where it came from and drops the Undo button")
    func undoneRow() {
        let row = HistoryRowPresentation(record: record(
            state: .undone,
            originalName: "2026-05 Chase statement.pdf",
            finalName: "2026-05 Chase statement.pdf",
            finalDirectory: downloads
        ))

        #expect(row.headline == "Undone — back in Downloads")
        #expect(row.detail == "had been in Invoices")
        #expect(row.showsUndo == false, "undo cannot be redone in M6")
    }

    @Test("An undo that had to dedupe explains the new name and says nothing was overwritten")
    func undoneWithCollision() {
        // Undo reuses the forward mover, so a newer file holding the original
        // name is never clobbered — the restored file gets a deduped name. The
        // difference between "the app renamed my file for no reason" and "the
        // app protected the other file" is entirely in this sentence.
        let row = HistoryRowPresentation(record: record(
            state: .undone,
            originalName: "rent-receipt-may.pdf",
            finalName: "rent-receipt-may 2.pdf",
            finalDirectory: downloads
        ))

        let detail = try? #require(row.detail)
        #expect(detail?.contains("rent-receipt-may.pdf was already taken") == true)
        #expect(detail?.contains("came back as rent-receipt-may 2.pdf") == true)
        #expect(detail?.contains("Nothing was overwritten") == true)
    }

    @Test("A move that really IS running says 'Moving…' and shows no Undo")
    func inProgressRowThatIsLive() {
        let row = HistoryRowPresentation(
            record: record(state: .inProgress, folderName: "Photos"), isLive: true
        )

        #expect(row.headline == "Moving…")
        #expect(row.detail == "to Photos")
        #expect(row.showsUndo == false, "a move that hasn't finished cannot be undone")
    }

    @Test("An in-progress row with nothing running says it was INTERRUPTED, not 'Moving…'")
    func inProgressRowThatIsStranded() {
        // F11. `recent` is never refreshed between writing the intent row and
        // settling it, so a genuinely running move barely reaches this pane at
        // all. The ways an `inProgress` row DOES get here are: finalize threw, a
        // reconcile couldn't settle it, or it belongs to another instance — and
        // in every one of those the app is not moving that file. A spinner and
        // "Moving…" then promised work nobody was doing, for as long as the user
        // cared to watch.
        let row = HistoryRowPresentation(
            record: record(state: .inProgress, folderName: "Photos"), isLive: false
        )

        #expect(row.headline == "Interrupted — the app can't confirm this one")
        #expect(row.tone == .caution)
        #expect(row.showsUndo == false)
        let detail = try? #require(row.detail)
        #expect(detail?.contains("Look in Downloads") == true,
                "it names where to look instead of pretending to know")
        #expect(detail?.contains("Photos") == true)
    }

    // MARK: - Rules that hold across every state

    @Test("Undo is offered on exactly the undoable states, and never otherwise",
          arguments: [MoveState.inProgress, .moved, .undone, .failed, .unknown])
    func undoMatchesUndoability(state: MoveState) {
        let stored = record(state: state)
        let row = HistoryRowPresentation(record: stored)

        #expect(row.showsUndo == stored.isUndoable,
                "the button must agree with what the coordinator will actually accept")
    }

    @Test("Every state produces a non-empty headline that stands alone without colour",
          arguments: [MoveState.inProgress, .moved, .undone, .failed, .unknown])
    func headlinesAreSelfSufficient(state: MoveState) {
        let row = HistoryRowPresentation(record: record(state: state))

        #expect(!row.headline.isEmpty)
        // Colour is never the only carrier of meaning: strip it and the sentence
        // still says what happened.
        #expect(row.headline.count > 5)
    }

    @Test("VoiceOver reads the FULL name, never the middle-truncated one")
    func accessibilityLabelUsesTheWholeName() {
        let long = "acme-invoice-final-FINAL-v3-signed(3)-approved-2026.pdf"
        let row = HistoryRowPresentation(record: record(state: .moved, finalName: long))

        let spoken = row.accessibilityLabel(timeSpokenAs: "today at 11:04")

        #expect(spoken.contains(long), "the app never stores or speaks a shortened name")
        #expect(spoken.contains("today at 11:04"))
        #expect(spoken.contains("Moved to Invoices"))
        #expect(!spoken.contains("…"))
    }
}

/// Day grouping for the history list.
@Suite("History day grouping")
struct HistoryDayTests {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(id: Int64, at date: Date) -> MoveRecord {
        MoveRecord(
            id: id,
            fileEventID: UUID(),
            originalDirectory: URL(fileURLWithPath: "/d", isDirectory: true),
            originalName: "a.pdf",
            finalDirectory: URL(fileURLWithPath: "/i", isDirectory: true),
            finalName: "b.pdf",
            destinationFolderName: "Invoices",
            state: .moved,
            fallbackReason: nil,
            failureDetail: nil,
            sourceIdentity: nil,
            acceptedAt: date,
            settledAt: date
        )
    }

    @Test("Today and Yesterday are named; older days get a weekday and date")
    @MainActor
    func dayTitles() {
        #expect(HistoryDay.title(for: now, now: now, calendar: calendar) == "Today")

        let yesterday = now.addingTimeInterval(-86_400)
        #expect(HistoryDay.title(for: yesterday, now: now, calendar: calendar) == "Yesterday")

        let lastWeek = now.addingTimeInterval(-86_400 * 6)
        let title = HistoryDay.title(for: lastWeek, now: now, calendar: calendar)
        #expect(title != "Today" && title != "Yesterday")
        #expect(!title.isEmpty)
    }

    @Test("Consecutive records on the same day share one section, in order")
    @MainActor
    func groupingPreservesOrder() {
        let records = [
            record(id: 3, at: now),
            record(id: 2, at: now.addingTimeInterval(-3600)),
            record(id: 1, at: now.addingTimeInterval(-86_400)),
        ]

        let days = HistoryDay.grouped(records, now: now, calendar: calendar)

        #expect(days.count == 2)
        #expect(days[0].title == "Today")
        #expect(days[0].records.map(\.id) == [3, 2], "newest-first order is preserved")
        #expect(days[1].title == "Yesterday")
        #expect(days[1].records.map(\.id) == [1])
    }

    @Test("An empty history produces no sections")
    @MainActor
    func emptyGrouping() {
        #expect(HistoryDay.grouped([], now: now, calendar: calendar).isEmpty)
    }
}
