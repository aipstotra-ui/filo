import Foundation
import Combine

/// Orchestrates one accepted suggestion into a moved file plus an undoable
/// history row, and back again for undo. This is the only place the resolver,
/// the history store, and the mover meet.
///
/// Contract pinned by `MoveCoordinatorTests`:
/// - **fail closed** (founder decision 1): if the intent row cannot be written,
///   the file is NOT touched and `.failed(.historyUnavailable)` comes back
/// - the write order is intent row → move → finalize/markFailed, so a crash
///   mid-move leaves a stranded `inProgress` row the launch reconcile resolves
///   — never a move with no record of it (risk #6)
/// - one move per `fileEventID` at a time: a popup Accept and a menu Accept
///   racing the same file cannot both move it (risk #11); the loser fails
///   honestly and touches nothing
/// - a self-rename (same folder, same name) writes NO history row: there is
///   nothing to undo
/// - undo is purely path-based off the persisted resolved paths, so it works
///   after a relaunch, and it uses the SAME mover — so it can never overwrite
///   a newer file that has taken the original name (risk #2)
@MainActor
final class MoveCoordinator: ObservableObject {

    /// How many records the history list holds. Founder decision 3 set the
    /// retention at 200; founder decision 6 then moved the list out of the menu
    /// and into Settings, where a scrolling window has room for all of them —
    /// so this is the retention limit rather than the old "last 5 in the menu".
    static let historyLimit = MoveHistoryStore.retentionLimit

    /// The newest records, newest first, capped at `historyLimit`.
    @Published private(set) var recent: [MoveRecord] = []

    /// Files with a move running right now. The menu's Accept button and the
    /// popup's Accept are disabled for these.
    @Published private(set) var inFlight: Set<UUID> = []

    /// Records with an undo running right now.
    @Published private(set) var undoInFlight: Set<Int64> = []

    /// The last outcome per file, for the menu row's status line ("Moved to
    /// Invoices" / "Couldn't move — …") — the menu has no popup to hold open.
    @Published private(set) var outcomes: [UUID: AcceptOutcome] = [:]

    /// One honest line when the history database itself is misbehaving, or nil
    /// when it is fine.
    ///
    /// Every store failure that is not already reported through an
    /// `AcceptOutcome` lands here instead of a dev-build-only log: a release
    /// build was silent about a history it could not read, so "nothing happened
    /// yet" and "your undo history is unreadable" looked identical (M12).
    ///
    /// Deliberately generic sentences — no paths, no filenames, no SQLite text
    /// — because unlike `history.db` itself this string is destined for the
    /// screen.
    @Published private(set) var historyProblem: String?

    /// True when the current `historyProblem` describes something that HAPPENED
    /// — a move that ran but could not be recorded — rather than something that
    /// is merely true right now.
    ///
    /// A later successful read of the table clears the second kind and must not
    /// touch the first: re-reading the history does not un-happen a move that
    /// went unrecorded, and wiping that sentence microseconds after writing it
    /// meant the single most important line in this milestone was never once
    /// seen (F7).
    private var historyProblemSurvivesARefresh = false

    /// Records whose Undo button is withdrawn for the rest of this session.
    ///
    /// One case puts a record here: an undo that moved the file successfully but
    /// could not write the flip to `undone`. The row still says `moved` and
    /// still points at the destination folder, so offering Undo again would
    /// promise something that cannot work — and the failure text would read as
    /// an accusation that the user moved the file themselves (F8).
    @Published private(set) var undoWithdrawn: Set<Int64> = []

    private let store: MoveHistoryStore
    private let resolver: MoveDestinationResolver
    private let mover: FileMover
    private let now: () -> Date

    /// The watcher's claim box, so the names this app is about to write into the
    /// watched folder are registered before they can appear — and, just as
    /// importantly, so the collision-ladder rungs a move did not use are retired
    /// the instant it settles (M7). nil in tests that do not exercise claiming.
    private let claims: AppCreatedFileClaims?

    /// Called after a move that really changed where the file is or what it is
    /// called, so the watcher can drop it from the "recently detected" list.
    ///
    /// That list means *downloads waiting for a decision*, and a filed file is
    /// no longer one. Left in, it appeared twice — once there, once in the
    /// history — and its menu row still offered to reopen a suggestion pointing
    /// at a path the file has left (D6). nil in tests that do not need it.
    private let fileWasFiled: ((UUID) -> Void)?

    init(
        store: MoveHistoryStore,
        resolver: MoveDestinationResolver,
        mover: FileMover = FileMover(),
        claims: AppCreatedFileClaims? = nil,
        fileWasFiled: ((UUID) -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.resolver = resolver
        self.mover = mover
        self.claims = claims
        self.fileWasFiled = fileWasFiled
        self.now = now
    }

    /// Non-nil when the history database was unusable at launch and was moved
    /// aside: the undo history is gone and the UI must say so (risk #12).
    nonisolated var historyRecoveredFromCorruption: URL? {
        if case .recoveredFromCorruption(let movedTo) = store.openOutcome { return movedTo }
        return nil
    }

    /// Launch pass: reconcile stranded `inProgress` rows against disk, prune to
    /// the retention limit, and publish `recent`. Safe to call once at start.
    func start() async {
        // Everything accepted from this instant on belongs to a move THIS
        // instance is running; only what predates launch can be stranded (F6).
        let launchedAt = now()
        do {
            let report = try await store.reconcileInProgress(
                acceptedBefore: launchedAt,
                excluding: inFlight
            ) { record in
                Self.presence(of: record)
            }
            if !report.unresolved.isEmpty {
                devLog("rows the reconcile could not settle: \(report.unresolved)")
                noteHistoryProblem(
                    "\(report.unresolved.count) interrupted "
                    + (report.unresolved.count == 1 ? "move" : "moves")
                    + " couldn't be checked, so they can't be undone."
                )
            }
        } catch {
            devLog("could not reconcile interrupted moves: \(error)")
            noteHistoryProblem(
                "Interrupted moves couldn't be checked, so they can't be undone."
            )
        }
        await prune()
        await refreshRecent()
    }

    /// The disk facts one stranded row is judged against.
    ///
    /// `targetIsTheFileWeMoved` is what stops the reconcile adopting a
    /// stranger's file (C2). The row's final name is only the name the mover
    /// *intended* to use — a collision or the 255-byte trim sends the file
    /// somewhere else — so a file at that name may well be someone else's, and
    /// offering Undo on it would move a file this app never touched. Identity,
    /// not name, decides: `(volume, inode)` survives a same-volume rename, and
    /// anything we cannot match reads as "cannot prove".
    private nonisolated static func presence(of record: MoveRecord) -> DiskPresence {
        let recorded = record.sourceIdentity
        let atTarget = FileIdentity.ofItem(atPath: record.finalURL.path)
        return DiskPresence(
            sourceExists: itemExists(at: record.originalURL),
            targetExists: itemExists(at: record.finalURL),
            targetIsTheFileWeMoved: recorded != nil && recorded == atTarget
        )
    }

    /// The Accept seam (`SuggestionAccepting`). The return value is the failure
    /// channel that stops the popup ever closing as success on a move that did
    /// not happen.
    func accept(_ decision: AcceptedSuggestion) async -> AcceptOutcome {
        // Claimed BEFORE the first `await`, or a popup Accept and a menu Accept
        // pressed together would both sail past this guard (risk #11). The
        // loser is not recorded in `outcomes`: the winner owns this file's story.
        guard !inFlight.contains(decision.fileEventID) else {
            return .failed(.alreadyInFlight)
        }
        inFlight.insert(decision.fileEventID)
        defer { inFlight.remove(decision.fileEventID) }

        let outcome = await performAccept(decision)
        outcomes[decision.fileEventID] = outcome
        return outcome
    }

    /// One-click undo of a recorded move: puts the file back under its original
    /// name, or under a deduped name if that name has been taken since.
    func undo(recordID: Int64) async -> UndoOutcome {
        guard !undoInFlight.contains(recordID) else {
            return .failed(.alreadyInFlight)
        }
        undoInFlight.insert(recordID)
        defer { undoInFlight.remove(recordID) }

        let stored: MoveRecord?
        do {
            stored = try await store.record(id: recordID)
        } catch {
            return .failed(.historyUnavailable(detail: "\(error)"))
        }
        guard let record = stored else {
            return .failed(.unknownRecord(id: recordID))
        }
        guard record.isUndoable else {
            return .failed(.notUndoable(state: record.state))
        }

        // The file has to be exactly where we left it. We never search the disk
        // and never guess: a file the user has since moved, renamed, or deleted
        // is theirs to place, not ours to chase.
        guard Self.itemExists(at: record.finalURL) else {
            return .failed(.fileNotWhereWeLeftIt(expectedPath: record.finalURL.path))
        }
        // ...and it has to be the same FILE, not merely something with the same
        // name. Retention is 200 rows, not 200 hours: deleting a moved file and
        // months later filing an unrelated `report.pdf` into Invoices by hand is
        // ordinary housekeeping, and the row is still sitting there offering
        // Undo. Without this, that Undo relocates a file this app never touched
        // and renames it on the way (F1) — the same harm the launch reconcile
        // was hardened against, through the door nobody closed.
        //
        // Same-volume only, on purpose. A cross-volume move copies the file, so
        // it legitimately has a NEW inode and refusing on that basis would break
        // every cross-volume undo. Closing that half needs `final_device` /
        // `final_inode` columns — schema v3, written down in [[History-Undo]].
        if let recorded = record.sourceIdentity,
           let atFinalPath = FileIdentity.ofItem(atPath: record.finalURL.path),
           recorded.deviceID == atFinalPath.deviceID,
           recorded.inode != atFinalPath.inode {
            return .failed(.fileNotWhereWeLeftIt(expectedPath: record.finalURL.path))
        }
        guard !undoWithdrawn.contains(recordID) else {
            return .failed(.notUndoable(state: record.state))
        }
        // Creating folders on the user's behalf is not this app's job.
        guard Self.directoryExists(at: record.originalDirectory) else {
            return .failed(.originalDirectoryMissing(path: record.originalDirectory.path))
        }
        // The same write-bounds gate the accept path goes through. Undo takes
        // its destination straight from a database column, and a column is not
        // a promise: a row written during a different session — or an edited
        // one — would otherwise make Undo "move any readable file into any
        // writable directory" (M14).
        guard resolver.allowsWriting(into: record.originalDirectory) else {
            return .failed(
                .destinationOutsideAllowedFolders(path: record.originalDirectory.path)
            )
        }

        // The SAME mover as the forward move, so undo inherits its no-clobber
        // guarantee: a newer file that has taken the original name is never
        // overwritten — the restored file gets a deduped name instead (risk #2).
        switch await performMove(
            from: record.finalURL,
            into: record.originalDirectory,
            preferredName: record.originalName
        ) {
        case .failure(let error):
            return .failed(.restoreFailed(error))
        case .success(let outcome):
            do {
                let flipped = try await store.markUndone(
                    id: recordID,
                    restoredDirectory: outcome.finalURL.deletingLastPathComponent(),
                    restoredName: outcome.finalName,
                    at: now()
                )
                if !flipped {
                    // Another undo settled the row first. The file really is
                    // back, so that is what we report.
                    devLog("history row \(recordID) was already settled when its undo finished")
                }
            } catch {
                // The file IS back in Downloads — the mover already returned.
                // Calling this a failure would be a lie about the user's disk;
                // the row is what is wrong, not the move. So: report the truth
                // about the file, say the record is stale, and withdraw an Undo
                // that would now only produce "that file isn't where the app
                // left it" — which reads as an accusation (F8).
                devLog("the undo happened but its history row could not be updated: \(error)")
                noteHistoryProblem(
                    "A file was put back, but the history couldn't be updated, "
                    + "so its entry still shows as moved.",
                    survivesARefresh: true
                )
                undoWithdrawn.insert(recordID)
                await refreshRecent()
                return .restored(
                    restoredURL: outcome.finalURL,
                    wasRenamedForCollision: outcome.wasRenamedForCollision
                )
            }
            await refreshRecent()
            return .restored(
                restoredURL: outcome.finalURL,
                wasRenamedForCollision: outcome.wasRenamedForCollision
            )
        }
    }

    /// Founder decision 3: "Clear history" in Settings. Returns nil on success,
    /// or the typed store failure so Settings can say so honestly.
    ///
    /// Refused outright while a move or an undo is running: clearing deletes
    /// the row that move is about to settle, which would leave a moved file
    /// with no record of it anywhere (M17). Better to ask the user to try again
    /// in a moment than to clear "most of" the history and lose a move.
    @discardableResult
    func clearHistory() async -> ClearHistoryFailure? {
        guard inFlight.isEmpty, undoInFlight.isEmpty else {
            return .busyWithAMove
        }
        let outcome: ClearOutcome
        do {
            outcome = try await store.clearAll()
        } catch {
            // Nothing was deleted: the store throws only from before its commit
            // point. The list stays exactly as it is, which is the truth.
            return .historyUnavailable(detail: "\(error)")
        }

        // Past the store's commit point, so the rows really are gone — the list
        // is emptied on every path from here, whatever else went wrong (F5).
        recent = []
        historyProblem = nil
        historyProblemSurvivesARefresh = false
        undoWithdrawn = []

        // The store never deletes a row for a move that is still running. The
        // in-flight check above should make that impossible, so a non-zero
        // count here means the two disagree — say so rather than report a
        // clean sweep. A nil count means we could not check, which is its own
        // answer and not the same as zero.
        switch outcome.rowsKept {
        case .some(0), .none:
            break
        case .some(let kept):
            return .someRowsKept(count: kept)
        }
        return outcome.compactionFailed ? .clearedButNotCompacted : nil
    }

    // MARK: - Accept, step by step

    private func performAccept(_ decision: AcceptedSuggestion) async -> AcceptOutcome {
        // Everything the popup captured is re-checked against the live world
        // here: the file may have moved, and the folder may be gone or may not
        // even be the same folder any more.
        let resolved: ResolvedDestination
        do {
            resolved = try resolver.resolve(decision)
        } catch {
            return .failed(.moveFailed(error))
        }

        // Accepting the name a file already has, in the folder it is already
        // in, changes nothing on disk — so there is nothing to undo, and no
        // history row is written.
        //
        // Unless a REQUESTED folder turned out to be unusable. Then the
        // resolver has already rewritten the destination to the file's own
        // folder, and "nothing changed" is not what the user asked for: they
        // asked for Invoices. Closing as a silent success would leave them
        // believing the file moved, with no row and no message anywhere to say
        // otherwise (M4). So the fallback case goes through the ordinary path
        // below — the mover reports its own no-op, and the outcome carries the
        // reason.
        let isNoOp = FileMover.isNoOp(
            source: resolved.sourceURL,
            directory: resolved.directory,
            preferredName: resolved.preferredName
        )
        if isNoOp, resolved.fallbackReason == nil {
            return .unchanged
        }

        // Founder decision 1: the intent row is written BEFORE the file is
        // touched, and if it cannot be written the file is not touched at all.
        // An unrecorded move is worse than no move.
        let recordID: Int64
        do {
            recordID = try await store.recordIntent(MoveIntent(
                fileEventID: decision.fileEventID,
                originalDirectory: resolved.sourceURL.deletingLastPathComponent(),
                originalName: resolved.sourceURL.lastPathComponent,
                intendedDirectory: resolved.directory,
                intendedName: resolved.preferredName,
                destinationFolderName: resolved.destinationFolderName,
                fallbackReason: resolved.fallbackReason,
                // Read a moment before the file is touched, so a crash
                // mid-move leaves the reconcile able to PROVE which file is
                // ours rather than trusting a name (C2).
                sourceIdentity: FileIdentity.ofItem(atPath: resolved.sourceURL.path),
                acceptedAt: now()
            ))
        } catch {
            devLog("refusing to move: the history row could not be written: \(error)")
            return .failed(.historyUnavailable(detail: "\(error)"))
        }

        switch await performMove(
            from: resolved.sourceURL,
            into: resolved.directory,
            preferredName: resolved.preferredName
        ) {
        case .success(let outcome):
            let summary = MoveSummary(
                recordID: recordID,
                finalURL: outcome.finalURL,
                destinationFolderName: resolved.destinationFolderName,
                fallbackReason: resolved.fallbackReason,
                wasRenamedForCollision: outcome.wasRenamedForCollision,
                requestedName: resolved.preferredName,
                nothingChangedOnDisk: outcome.wasNoOp,
                originalRemained: outcome.originalRemained
            )
            // The popup is dismissed in seconds; the history is what the user
            // comes back to, so the same words go into the row — minus the
            // fallback clause, which the row derives from its own column and
            // would otherwise say twice (X9).
            await settle(recordID: recordID, after: outcome, noting: summary.historyNote)
            // Only when something actually changed: a no-op left the file
            // exactly where the dropdown says it is, so there is nothing stale
            // to clear away.
            if !outcome.wasNoOp { fileWasFiled?(decision.fileEventID) }
            return .moved(summary)
        case .failure(let error):
            await recordFailure(
                error, on: recordID, folderNamed: resolved.destinationFolderName
            )
            return .failed(.moveFailed(error))
        }
    }

    /// Settles the row of a move that did NOT happen. Extracted so
    /// `performAccept` reads as the four steps it is.
    private func recordFailure(
        _ error: MoveError, on recordID: Int64, folderNamed folder: String?
    ) async {
        do {
            try await store.markFailed(
                id: recordID,
                // Plain language, the folder named, and no error code: this
                // column is read straight onto the screen weeks later (D4/D5).
                // The one specific that must survive is the leftover partial
                // file from a failed cross-volume copy (C1/M13) — it has its
                // own flag on the error rather than living in free text.
                detail: error.historyDetail(namingFolder: folder),
                at: now()
            )
        } catch {
            devLog("could not mark the history row failed: \(error)")
            noteHistoryProblem(
                "A failed move couldn't be written to the history.",
                survivesARefresh: true
            )
        }
        await refreshRecent()
    }

    /// Settles the row of a move that succeeded, then refreshes what the menu
    /// shows. Extracted so `performAccept` reads as the four steps it is.
    private func settle(recordID: Int64, after outcome: MoveOutcome, noting note: String?) async {
        do {
            try await store.finalize(
                id: recordID,
                finalDirectory: outcome.finalURL.deletingLastPathComponent(),
                finalName: outcome.finalName,
                note: note,
                at: now()
            )
            // Founder decision 3 promises the history keeps the last 200
            // actions. A menu-bar app runs for weeks, so pruning only at launch
            // would leave that untrue for the whole session (M18).
            await prune()
        } catch {
            // The file HAS moved, so reporting a failure would be a lie. The
            // row stays `inProgress`, which offers no Undo and which the next
            // launch's reconcile pass settles from disk — but the user is told,
            // because "no Undo for this move" is not something to discover.
            devLog("the move happened but its history row could not be settled: \(error)")
            noteHistoryProblem(
                "That move happened, but the history couldn't be updated, "
                + "so it can't be undone.",
                survivesARefresh: true
            )
        }
        await refreshRecent()
    }

    // NOTE: the user-facing sentence for "cross-volume copy verified, original
    // couldn't be deleted" lives in `MoveRecord.outcomeNote` — the one place
    // that actually renders it. A second, unused copy used to sit here; it was
    // removed 2026-07-30 so the wording can never drift between two homes.

    // MARK: - Plumbing

    /// Runs the mover off the main actor: a rename is one fast syscall, but the
    /// cross-volume fallback copies the whole file, and the menu bar must not
    /// freeze while it does. `Result` rather than `throws` so the typed
    /// `MoveError` survives the hop back.
    private func performMove(
        from source: URL, into directory: URL, preferredName: String
    ) async -> Result<MoveOutcome, MoveError> {
        let mover = self.mover
        // One group per move, so this move's announced candidates can be
        // retired together without disturbing a move running alongside it.
        let claimGroup = UUID()
        let result = await Task.detached { () -> Result<MoveOutcome, MoveError> in
            do throws(MoveError) {
                return .success(try mover.move(
                    from: source,
                    intoDirectory: directory,
                    preferredName: preferredName,
                    claimGroup: claimGroup
                ))
            } catch {
                return .failure(error)
            }
        }.value

        // The move is over, so every rung it announced but did not use is now
        // dead weight — and dead weight here is not harmless: a leftover claim
        // would adopt a genuine download that happens to share the name and it
        // would never be announced to the user (M7). A failed move used nothing
        // at all, so all of its claims go.
        switch result {
        case .success(let outcome):
            claims?.releaseUnused(group: claimGroup, keeping: outcome.finalURL)
        case .failure:
            claims?.releaseUnused(group: claimGroup, keeping: nil)
        }
        return result
    }

    private func refreshRecent() async {
        do {
            recent = try await store.recent(limit: Self.historyLimit)
            // A read that skipped rows it could not decode still returns a list,
            // and a shorter list is indistinguishable from a shorter history —
            // so it is said out loud rather than left to look like the truth.
            let unreadable = await store.unreadableRowsInLastRead
            guard unreadable == 0 else {
                noteHistoryProblem(
                    "\(unreadable) " + (unreadable == 1 ? "entry" : "entries")
                    + " in your history couldn't be read, so "
                    + (unreadable == 1 ? "it isn't" : "they aren't") + " listed below."
                )
                return
            }
            // Clears only a problem this method is entitled to clear. It is
            // called at the end of every path that just wrote one, so clearing
            // unconditionally erased the move-path sentences microseconds after
            // they were set — leaving "your undo history couldn't be read" as
            // the only message that could ever actually appear (F7).
            if !historyProblemSurvivesARefresh { historyProblem = nil }
        } catch {
            // `recent` keeps whatever it held, which may be stale or empty —
            // and a single unreadable row makes the whole read fail. Silence
            // here made "nothing has happened yet" and "your undo history is
            // unreadable" look identical in the menu (M12).
            devLog("could not read the recent history: \(error)")
            noteHistoryProblem("Your undo history couldn't be read.")
        }
    }

    private func prune() async {
        do {
            try await store.pruneBeyond(MoveHistoryStore.retentionLimit)
        } catch {
            devLog("could not prune the history: \(error)")
            noteHistoryProblem("Old history entries couldn't be tidied up.")
        }
    }

    /// Records one honest, non-technical line for the UI. Newest wins: the most
    /// recent problem is the one worth showing.
    ///
    /// `survivesARefresh` marks a message about something that HAPPENED — a move
    /// or an undo that ran but could not be recorded. Re-reading the table does
    /// not un-happen it, so a later successful read must leave it alone (F7).
    /// Everything else describes the table's current state and is cleared the
    /// moment the table reads cleanly again.
    private func noteHistoryProblem(_ message: String, survivesARefresh: Bool = false) {
        historyProblem = message
        historyProblemSurvivesARefresh = survivesARefresh
    }

    /// Surfaces a failed "Clear History" on the same honest line the store's own
    /// problems use. A Clear that quietly did nothing while the user watched the
    /// list stay put is its own kind of lie.
    func reportClearFailure(_ failure: ClearHistoryFailure) {
        noteHistoryProblem(failure.message)
    }

    // MARK: - Quitting

    /// True while this app is part-way through changing one of the user's files.
    var isBusy: Bool { !inFlight.isEmpty || !undoInFlight.isEmpty }

    /// Waits for every running move and undo to finish, giving up after
    /// `limit` seconds.
    ///
    /// Bounded on purpose: a quit that waits forever on a stuck copy is worse
    /// than one that gives up, and a move still running past the limit settles
    /// at the next launch exactly as a crash would (F10).
    func waitUntilIdle(limit: TimeInterval) async {
        let deadline = now().addingTimeInterval(limit)
        while isBusy, now() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Closes the history connection, so quitting is a clean close rather than
    /// an abandoned one (X4).
    func closeStore() async {
        await store.close()
    }

    /// `nonisolated` because the launch reconcile probes disk from inside the
    /// store actor, off the main actor.
    private nonisolated static func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Dev-build diagnostics only, control-character-sanitized (LogSanitizer
    /// discipline). Never file contents; typed error descriptions may carry a
    /// path, which is dev-build-only per docs/process/engineering-rules.md.
    private func devLog(_ message: String) {
        #if DEBUG
        print("MoveCoordinator: \(LogSanitizer.sanitized(message))")
        #endif
    }
}

/// Compile-time proof that the coordinator satisfies the popup's Accept seam
/// unchanged, so wiring it into `App.swift` in place of `NoMoveAccepting` is a
/// one-line change once the history UI clears its founder mockup gate.
extension MoveCoordinator: SuggestionAccepting {}
