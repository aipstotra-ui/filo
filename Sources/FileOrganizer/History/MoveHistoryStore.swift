import Foundation
import SQLite3

/// The disk facts the launch reconcile needs about one stranded `inProgress`
/// row. Gathered by the caller (which owns the filesystem), so the *rule* that
/// turns them into a state is pure and fully testable.
struct DiskPresence: Sendable, Equatable {
    /// Is the file still at the row's original path?
    let sourceExists: Bool
    /// Is a file at the row's intended final path?
    let targetExists: Bool
    /// Is the file at the row's target path *the file this row is about*?
    ///
    /// Proven by identity (volume + inode), never by name. The row's
    /// `final_name` is only the name the mover *intended* to use: a collision
    /// sends it to "report 2.pdf", and the 255-byte trim can change it too. So
    /// "a file with that name is there" says nothing about whose file it is,
    /// and adopting a stranger would offer the user an Undo that moves a file
    /// this app never touched (C2).
    let targetIsTheFileWeMoved: Bool
}

/// What one launch reconcile pass did.
struct ReconcileReport: Sendable, Equatable {
    /// One stranded row the pass could not settle.
    struct UnresolvedRow: Sendable, Equatable {
        let id: Int64
        /// Why it could not be settled. Diagnostics only — never shown raw.
        let detail: String
    }

    /// The rows that were settled, in their new states.
    let settled: [MoveRecord]
    /// The rows that could not be settled. The pass runs once per launch, so a
    /// row abandoned here stays `inProgress` — offering no undo — until the
    /// next launch. That is why it is returned rather than logged (M12).
    let unresolved: [UnresolvedRow]
}

/// What one "Clear history" actually did.
///
/// It exists because the delete and the tidy-up afterwards can succeed and fail
/// independently, and the user's question — *is my history gone?* — is answered
/// by the delete alone. Reporting a failed `VACUUM` as a failed clear told them
/// the opposite of the truth (F5).
struct ClearOutcome: Sendable, Equatable {
    /// Rows deliberately left behind because a move was still running, or nil
    /// when the count itself could not be read. nil is not zero: "we didn't
    /// check" must never be reported as "a clean sweep".
    let rowsKept: Int?
    /// The rows are gone, but the file could not be rewritten or its
    /// write-ahead log truncated, so the cleared names may still sit in unused
    /// pages until a later clear succeeds.
    let compactionFailed: Bool

    /// True when the clear did exactly what it says on the button.
    var wasComplete: Bool { rowsKept == 0 && !compactionFailed }
}

/// SQLite-backed history of every move this app made, in its own `history.db`
/// — deliberately NOT the index database. The index has a "corrupt → move
/// aside → rebuild fresh" policy because it can always be rebuilt by rescanning;
/// the history is the only record of what we did to the user's files and can
/// never be rebuilt, so it does not share a file with a wipe-and-restart path.
///
/// An actor: the sqlite3 handle is mutable state confined here. Raw built-in
/// C API (`import SQLite3`) — no third-party packages.
///
/// Schema contract pinned by `MoveHistoryStoreTests` (this store is the only
/// schema owner), mirroring `FolderIndexStore`:
/// - `PRAGMA user_version` == `MoveHistoryStore.schemaVersion` after open
/// - WAL journal mode, `synchronous=FULL`, `secure_delete=ON`; every runtime
///   value bound, never interpolated
/// - on-disk permissions: DB file 0o600, parent directory 0o700
/// - a file that is genuinely **not a database** (`SQLITE_CORRUPT` /
///   `SQLITE_NOTADB`) is moved aside byte-for-byte intact and reported via
///   `OpenOutcome.recoveredFromCorruption` — surfaced to the user, never a
///   silent reset (risk #12). Every other failure — a busy lock, a full disk,
///   an I/O error — leaves the file exactly where it is
/// - an unknown FUTURE `user_version` is a typed refusal, file untouched
/// - **two-phase, intent-first**: `recordIntent` writes an `inProgress` row
///   BEFORE the file is touched; `finalize`/`markFailed` settle it afterwards
/// - `markUndone` is state-guarded INSIDE the UPDATE statement, so a second
///   (or concurrent) undo cannot win the race
actor MoveHistoryStore {

    /// Bump only with a real migration step in `migrate(on:from:)`.
    /// - 1: the `moves` table.
    /// - 2: `source_device` / `source_inode`, so the launch reconcile can prove
    ///   the file at a stranded row's target is the one we moved (C2).
    static let schemaVersion: Int32 = 2

    /// Founder decision 3: the database keeps the last 200 actions; undo never
    /// expires inside that window.
    static let retentionLimit = 200

    /// SQLite's SQLITE_TRANSIENT destructor constant, unavailable directly from
    /// Swift because it is a C macro casting -1 to a function pointer. Tells
    /// SQLite to copy bound bytes immediately, so Swift-managed buffers may be
    /// freed as soon as the bind call returns.
    private static let transientBytes = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// How opening went.
    enum OpenOutcome: Sendable, Equatable {
        case createdFresh
        case openedExisting
        /// The existing file was not a usable database. It was moved aside
        /// (byte-for-byte intact, at the associated URL) and a fresh one
        /// created. The UI MUST surface this — history was lost.
        case recoveredFromCorruption(corruptFileMovedTo: URL)
    }

    /// Typed store failures.
    enum StoreError: Error, Equatable {
        case cannotOpen(path: String, detail: String)
        case unsupportedSchemaVersion(found: Int32, supported: Int32)
        /// A statement failed. `code` is SQLite's own result code, and carrying
        /// it is what separates "this file is not a database"
        /// (`SQLITE_CORRUPT` / `SQLITE_NOTADB`) from "another process holds the
        /// lock", "the disk is full", or "the read failed". Only the first
        /// justifies moving the user's irreplaceable history aside; treating a
        /// busy lock as corruption orphans the real history forever (M8).
        case queryFailed(detail: String, code: Int32)
        case recordNotFound(id: Int64)
        /// `pruneBeyond` was asked to keep zero rows or fewer, which would
        /// delete the entire irreplaceable table. Refused (M16).
        case invalidRetentionLimit(keeping: Int)
    }

    /// How opening the database went; set once by init.
    nonisolated let openOutcome: OpenOutcome

    /// Where this store lives, for diagnostics.
    nonisolated let databaseURL: URL

    /// The single connection this actor owns. nil once `close()` has run.
    private var db: OpaquePointer?

    /// How many rows the most recent read had to skip because this build could
    /// not decode them. Non-zero means the history the user is looking at is
    /// incomplete — which the UI says out loud, rather than quietly showing a
    /// shorter list (X5).
    private(set) var unreadableRowsInLastRead = 0

    // Schema DDL. Table and column names are compile-time constants; every
    // value that ever varies at runtime is bound, never interpolated.
    private static let createMovesTable = """
        CREATE TABLE IF NOT EXISTS moves (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_event_id TEXT NOT NULL,
            original_directory TEXT NOT NULL,
            original_name TEXT NOT NULL,
            final_directory TEXT NOT NULL,
            final_name TEXT NOT NULL,
            destination_folder_name TEXT,
            state TEXT NOT NULL,
            fallback_reason TEXT,
            failure_detail TEXT,
            accepted_at REAL NOT NULL,
            settled_at REAL,
            source_device INTEGER,
            source_inode INTEGER
        )
        """

    /// The column list every read uses, so the decoder's indexes are the same
    /// everywhere. Order is the contract between `selectColumns` and `decode`.
    private static let selectColumns = """
        id, file_event_id, original_directory, original_name,
        final_directory, final_name, destination_folder_name, state,
        fallback_reason, failure_detail, accepted_at, settled_at,
        source_device, source_inode
        """

    /// Opens (creating parent directory, file, and schema as needed).
    /// Never returns a half-open store: any failure throws `StoreError`.
    /// Default on-disk location: ~/Library/Application Support/AI File
    /// Organizer/history.db — beside `index.db`, deliberately NOT inside it.
    /// The index can always be rebuilt by rescanning; this file is the only
    /// record of what the app did to the user's files, so it does not share a
    /// file with a wipe-and-rebuild recovery path.
    static func defaultDatabaseURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("AI File Organizer")
            .appendingPathComponent("history.db")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AI File Organizer/history.db")
    }

    init(databaseURL: URL) throws(StoreError) {
        self.databaseURL = databaseURL
        let path = databaseURL.path
        try Self.createParentDirectoryIfNeeded(for: databaseURL)

        let existed = FileManager.default.fileExists(atPath: path)
        if !existed {
            try Self.createEmptyDatabaseFile(at: databaseURL)
        }

        do throws(StoreError) {
            self.db = try Self.openAndPrepare(at: path, isFresh: !existed)
            self.openOutcome = existed ? .openedExisting : .createdFresh
        } catch {
            // ONLY a file that is genuinely not a database is moved aside. A
            // busy lock, a full disk, or an I/O error is transient: the history
            // is irreplaceable and moving it aside is one-way, so anything we
            // are not certain about leaves the file exactly where it is (M8).
            guard existed, Self.indicatesCorruption(error) else {
                throw Self.asOpenFailure(error, path: path)
            }
            let movedTo = try Self.moveCorruptDatabaseAside(at: databaseURL)
            try Self.createEmptyDatabaseFile(at: databaseURL)
            do throws(StoreError) {
                self.db = try Self.openAndPrepare(at: path, isFresh: true)
            } catch {
                // The replacement could not be opened either. Remove the empty
                // file we just created rather than leave one behind: the next
                // launch would open it happily and report `.openedExisting`,
                // telling the user nothing about the history that was lost.
                try? FileManager.default.removeItem(at: databaseURL)
                throw Self.asOpenFailure(error, path: path)
            }
            self.openOutcome = .recoveredFromCorruption(corruptFileMovedTo: movedTo)
        }
    }

    deinit {
        if let db {
            // close_v2 closes cleanly even if a statement were somehow still
            // live, where the v1 close would leave the handle open.
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Two-phase write

    /// Phase 1: writes the `inProgress` row and returns its id. Called BEFORE
    /// the file is touched. If this throws, founder decision 1 says the caller
    /// must NOT move the file.
    func recordIntent(_ intent: MoveIntent) throws(StoreError) -> Int64 {
        let db = try openHandle()
        let statement = try prepare(
            on: db,
            """
            INSERT INTO moves
                (file_event_id, original_directory, original_name,
                 final_directory, final_name, destination_folder_name, state,
                 fallback_reason, failure_detail, accepted_at, settled_at,
                 source_device, source_inode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        guard bindText(statement, 1, intent.fileEventID.uuidString),
              bindText(statement, 2, intent.originalDirectory.path),
              bindText(statement, 3, intent.originalName),
              bindText(statement, 4, intent.intendedDirectory.path),
              bindText(statement, 5, intent.intendedName),
              bindOptionalText(statement, 6, intent.destinationFolderName),
              bindText(statement, 7, MoveState.inProgress.rawValue),
              bindOptionalText(statement, 8, intent.fallbackReason?.rawValue),
              sqlite3_bind_double(statement, 9, intent.acceptedAt.timeIntervalSince1970) == SQLITE_OK,
              bindOptionalInt64(statement, 10, intent.sourceIdentity?.deviceID),
              bindOptionalInt64(statement, 11, intent.sourceIdentity?.inode)
        else {
            throw queryFailure("binding intent row", on: db)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw queryFailure("inserting intent row", on: db)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Phase 2, success: the file is at `finalDirectory`/`finalName` (which may
    /// differ from the intent when a collision forced a deduped name).
    ///
    /// `note` is the honest caveat a *successful* move can still carry — today,
    /// a cross-volume copy that was verified complete but whose original could
    /// not be deleted, leaving a duplicate behind (C1). nil for a clean move.
    func finalize(
        id: Int64, finalDirectory: URL, finalName: String, note: String? = nil, at date: Date
    ) throws(StoreError) {
        try consumeInjectedFailure()
        let db = try openHandle()
        let statement = try prepare(
            on: db,
            """
            UPDATE moves
            SET state = ?, final_directory = ?, final_name = ?,
                failure_detail = ?, settled_at = ?
            WHERE id = ? AND state = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        guard bindText(statement, 1, MoveState.moved.rawValue),
              bindText(statement, 2, finalDirectory.path),
              bindText(statement, 3, finalName),
              bindOptionalText(statement, 4, note),
              sqlite3_bind_double(statement, 5, date.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int64(statement, 6, id) == SQLITE_OK,
              bindText(statement, 7, MoveState.inProgress.rawValue) else {
            throw queryFailure("binding finalize", on: db)
        }
        try step(statement, on: db, describing: "finalize")
        guard sqlite3_changes(db) == 1 else {
            throw StoreError.queryFailed(
                detail: "row \(id) was no longer in progress, so it was not finalized",
                code: SQLITE_OK
            )
        }
    }

    /// Phase 2, failure: the move did not happen; the file is still at its
    /// original path. `detail` is stored for the honest menu line.
    func markFailed(id: Int64, detail: String, at date: Date) throws(StoreError) {
        try settle(id: id, as: .failed, detail: detail, at: date)
    }

    /// Marks a row undone — but ONLY if it is still `moved`. The guard lives
    /// inside the UPDATE statement (`WHERE id = ? AND state = 'moved'`), so two
    /// undos racing cannot both win.
    ///
    /// - Returns: true only if THIS call flipped the row.
    func markUndone(
        id: Int64, restoredDirectory: URL, restoredName: String, at date: Date
    ) throws(StoreError) -> Bool {
        try consumeInjectedFailure()
        let db = try openHandle()
        let statement = try prepare(
            on: db,
            """
            UPDATE moves
            SET state = ?, final_directory = ?, final_name = ?, settled_at = ?
            WHERE id = ? AND state = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        guard bindText(statement, 1, MoveState.undone.rawValue),
              bindText(statement, 2, restoredDirectory.path),
              bindText(statement, 3, restoredName),
              sqlite3_bind_double(statement, 4, date.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int64(statement, 5, id) == SQLITE_OK,
              bindText(statement, 6, MoveState.moved.rawValue) else {
            throw queryFailure("binding undo update", on: db)
        }
        try step(statement, on: db, describing: "undo update")
        // The state test is inside the statement, so SQLite decides the winner.
        return sqlite3_changes(db) == 1
    }

    // MARK: - Read

    /// The newest `limit` records, newest first (row id descending).
    func recent(limit: Int) throws(StoreError) -> [MoveRecord] {
        let db = try openHandle()
        let statement = try prepare(
            on: db, "SELECT \(Self.selectColumns) FROM moves ORDER BY id DESC LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, Int64(max(0, limit))) == SQLITE_OK else {
            throw queryFailure("binding recent limit", on: db)
        }
        return try readAll(statement, on: db, describing: "recent history")
    }

    /// One record by id, or nil when there is no such row.
    func record(id: Int64) throws(StoreError) -> MoveRecord? {
        let db = try openHandle()
        let statement = try prepare(
            on: db, "SELECT \(Self.selectColumns) FROM moves WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, id) == SQLITE_OK else {
            throw queryFailure("binding record id", on: db)
        }
        return try readAll(statement, on: db, describing: "one history row").first
    }

    /// Every row still in `inProgress`, oldest first — what the launch
    /// reconcile has to resolve.
    func inProgressRecords() throws(StoreError) -> [MoveRecord] {
        let db = try openHandle()
        let statement = try prepare(
            on: db, "SELECT \(Self.selectColumns) FROM moves WHERE state = ? ORDER BY id"
        )
        defer { sqlite3_finalize(statement) }
        guard bindText(statement, 1, MoveState.inProgress.rawValue) else {
            throw queryFailure("binding in-progress query", on: db)
        }
        return try readAll(statement, on: db, describing: "stranded rows")
    }

    // MARK: - Retention

    /// Deletes all but the newest `keeping` rows (founder decision 3: 200).
    ///
    /// Refuses `keeping <= 0`: `LIMIT 0` makes the `NOT IN (…)` test true for
    /// every row, so one stray zero would silently wipe the irreplaceable
    /// table (M16). Rows that are still `inProgress` are never pruned — a move
    /// happening right now still has to be able to settle.
    ///
    /// - Returns: how many rows were deleted.
    @discardableResult
    func pruneBeyond(_ keeping: Int) throws(StoreError) -> Int {
        guard keeping > 0 else { throw .invalidRetentionLimit(keeping: keeping) }
        let db = try openHandle()
        let statement = try prepare(
            on: db,
            """
            DELETE FROM moves
            WHERE state <> ?
              AND id NOT IN (SELECT id FROM moves ORDER BY id DESC LIMIT ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        guard bindText(statement, 1, MoveState.inProgress.rawValue),
              sqlite3_bind_int64(statement, 2, Int64(keeping)) == SQLITE_OK else {
            throw queryFailure("binding prune limit", on: db)
        }
        try step(statement, on: db, describing: "prune")
        return Int(sqlite3_changes(db))
    }

    /// Founder decision 3: the "Clear history" button in Settings. Deletes every
    /// settled row — and nothing on disk outside this database.
    ///
    /// Two things make "clear" mean clear:
    /// - A row still `inProgress` belongs to a move happening RIGHT NOW.
    ///   Deleting it would make that move's `finalize` fail and leave a moved
    ///   file with no record at all, so it is left alone and reported (M17).
    ///   The coordinator additionally refuses to clear while a move is running.
    /// - macOS's system SQLite is not built with `SECURE_DELETE`, so a plain
    ///   DELETE leaves the filenames and paths sitting in the file's free pages,
    ///   readable with `strings`. The connection runs `secure_delete=ON`, and
    ///   this then rewrites the file (`VACUUM`) and empties the write-ahead log
    ///   (`wal_checkpoint(TRUNCATE)`) so nothing survives in either (M9).
    ///
    /// - Returns: what actually happened. See `ClearOutcome` — the delete is the
    ///   commit point, and everything after it is hygiene that can fail on its
    ///   own without making the clear untrue.
    @discardableResult
    func clearAll() throws(StoreError) -> ClearOutcome {
        let db = try openHandle()
        let statement = try prepare(on: db, "DELETE FROM moves WHERE state <> ?")
        defer { sqlite3_finalize(statement) }
        guard bindText(statement, 1, MoveState.inProgress.rawValue) else {
            throw queryFailure("binding clear", on: db)
        }
        try step(statement, on: db, describing: "clear history")

        // ── THE COMMIT POINT ──────────────────────────────────────────────
        // The rows are gone from here on. Nothing below may throw out of this
        // method, because every one of those throws used to be reported as
        // "the history couldn't be cleared" while the history was, in fact,
        // already cleared — the user then sat looking at a list of rows that
        // no longer existed, every Undo on which failed (F5).

        // VACUUM rewrites the database file from the live rows only; the
        // checkpoint then folds the WAL into it and truncates the WAL to zero.
        // Neither can run inside a transaction, and neither touches anything
        // outside these three files.
        var compactionFailed = false
        do throws(StoreError) {
            // A test can arm a failure here to prove the delete really is the
            // commit point: everything from here on must be reported as
            // "cleared, not tidied", never as "nothing was cleared" (F5).
            try consumeInjectedFailure()
            try execute(on: db, "VACUUM")
        } catch {
            compactionFailed = true
            devLog("history cleared, but the file could not be compacted: \(error)")
        }
        // The one SQLite return this file used to discard. On SQLITE_BUSY the
        // WAL keeps page images of the rows just deleted, so "cleared" would be
        // overstating it until the next successful checkpoint (X3).
        if sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) != SQLITE_OK {
            compactionFailed = true
            devLog("history cleared, but the write-ahead log could not be truncated")
        }

        var rowsKept: Int?
        do throws(StoreError) {
            rowsKept = try inProgressRecords().count
        } catch {
            // We cannot say how many in-progress rows survived. nil says that,
            // rather than reporting a clean sweep we have not verified.
            rowsKept = nil
            devLog("history cleared, but the remaining rows could not be counted: \(error)")
        }
        return ClearOutcome(rowsKept: rowsKept, compactionFailed: compactionFailed)
    }

    // MARK: - Launch reconcile

    /// The rule that turns disk facts into an honest state for a stranded
    /// `inProgress` row. Pure, so every combination is directly testable.
    ///
    /// Only one combination is conclusive enough to offer undo for; everything
    /// else is `unknown`, which the menu shows honestly and offers **no** undo
    /// for — the app does not guess where a user's file went.
    static func reconciledState(for presence: DiskPresence) -> MoveState {
        switch (presence.sourceExists, presence.targetExists) {
        case (false, true):
            // The file left its old path and something is at the new one — but
            // "something" is not "ours". The row's final name is only the name
            // the mover *intended*; a collision or a byte-budget trim sends the
            // file somewhere else, and then the file at that name belongs to
            // someone else entirely. Undo would move a stranger's file (C2).
            presence.targetIsTheFileWeMoved ? .moved : .unknown
        case (true, false):
            // Still where it started: the move never happened.
            .failed
        default:
            // Both present: we cannot tell our move from an unrelated file that
            // happens to share the name. Neither present: the file went
            // somewhere we did not put it.
            .unknown
        }
    }

    /// Resolves every stranded `inProgress` row by probing disk through
    /// `presence`, and reports what it could and could not settle.
    ///
    /// A row is only stranded if nobody is still working on it, and two things
    /// decide that (F6):
    /// - `acceptedBefore` — normally the moment this instance launched. A row
    ///   accepted after that belongs to a move started since, which is running
    ///   right now and will settle itself.
    /// - `excluding` — file event ids with a live move in this instance.
    ///
    /// Without both, a second copy of the app settled the first copy's live row
    /// as `failed` ("the file stayed where it was") while the first copy was
    /// moving the file — and the permanent record then said a move that
    /// happened did not.
    func reconcileInProgress(
        acceptedBefore: Date,
        excluding: Set<UUID> = [],
        probing presence: @Sendable (MoveRecord) -> DiskPresence
    ) throws(StoreError) -> ReconcileReport {
        let settledAt = Date()
        var settled: [MoveRecord] = []
        var unresolved: [ReconcileReport.UnresolvedRow] = []

        // There is no `await` anywhere in this loop, and that is load-bearing:
        // the whole pass runs as one indivisible step of this actor, so no
        // other call can insert, settle, or delete a row while it is half
        // finished. Do not add one.
        for stranded in try inProgressRecords() {
            guard stranded.acceptedAt < acceptedBefore,
                  !excluding.contains(stranded.fileEventID) else { continue }
            do throws(StoreError) {
                let state = Self.reconciledState(for: presence(stranded))
                try settle(
                    id: stranded.id,
                    as: state,
                    detail: Self.reconcileDetail(for: state),
                    at: settledAt
                )
                guard let updated = try record(id: stranded.id) else {
                    throw StoreError.recordNotFound(id: stranded.id)
                }
                settled.append(updated)
            } catch {
                // One row that will not settle must not strand every row behind
                // it: this pass runs only at launch, so an abandoned row would
                // stay `inProgress` — and offer no undo — until the next one
                // (M12). Collected and reported instead of aborting the loop.
                unresolved.append(.init(id: stranded.id, detail: "\(error)"))
            }
        }
        return ReconcileReport(settled: settled, unresolved: unresolved)
    }

    /// The honest note stored on a row the launch reconcile settled. Explicit
    /// over every state, with no `default`, so a new `MoveState` fails to
    /// compile here instead of silently storing nothing (M32).
    private static func reconcileDetail(for state: MoveState) -> String? {
        switch state {
        case .failed:
            "The app stopped before the move happened, so the file stayed where it was."
        case .unknown:
            "The app stopped during this move and couldn't tell afterwards what happened."
        case .moved, .undone, .inProgress:
            // `moved` needs none — the row already says where the file is. The
            // other two are never produced by the reconcile rule.
            nil
        }
    }

    // MARK: - Lifecycle

    /// Closes the underlying handle. Idempotent; the store is unusable
    /// afterwards (every method then fails typed, which is also how tests
    /// simulate "the history database is unavailable").
    func close() {
        if let db {
            sqlite3_close_v2(db)
        }
        db = nil
    }

    // MARK: - Settling

    /// Moves one still-in-progress row to a settled state. `finalize` is
    /// separate because it also rewrites the final path.
    private func settle(
        id: Int64, as state: MoveState, detail: String?, at date: Date
    ) throws(StoreError) {
        try consumeInjectedFailure()
        let db = try openHandle()
        let statement = try prepare(
            on: db,
            """
            UPDATE moves
            SET state = ?, failure_detail = ?, settled_at = ?
            WHERE id = ? AND state = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        guard bindText(statement, 1, state.rawValue),
              bindOptionalText(statement, 2, detail),
              sqlite3_bind_double(statement, 3, date.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, id) == SQLITE_OK,
              bindText(statement, 5, MoveState.inProgress.rawValue) else {
            throw queryFailure("binding settle", on: db)
        }
        try step(statement, on: db, describing: "settle")
        guard sqlite3_changes(db) == 1 else {
            throw StoreError.queryFailed(
                detail: "row \(id) was no longer in progress, so it was not settled",
                code: SQLITE_OK
            )
        }
    }

    // MARK: - Opening

    /// The only two SQLite result codes that mean "this file is not a usable
    /// database". Everything else — a busy lock, a full disk, an I/O error — is
    /// transient or environmental, and moving the user's irreplaceable history
    /// aside for one of those would orphan it forever (M8).
    static func indicatesCorruption(_ error: StoreError) -> Bool {
        guard case .queryFailed(_, let code) = error else { return false }
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }

    /// Re-labels a failure that happened while opening. A `queryFailed` from
    /// the open path is an open failure to the caller, and it carries the
    /// SQLite code so "the disk is full" is not read as "your history is gone".
    private static func asOpenFailure(_ error: StoreError, path: String) -> StoreError {
        guard case .queryFailed(let detail, let code) = error else { return error }
        return .cannotOpen(path: path, detail: "\(detail) (sqlite code \(code))")
    }

    private static func createParentDirectoryIfNeeded(for databaseURL: URL) throws(StoreError) {
        let parent = databaseURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StoreError.cannotOpen(
                path: databaseURL.path,
                detail: "cannot create parent directory: \(error.localizedDescription)"
            )
        }
    }

    /// Pre-creates the DB file empty with 0o600 permissions, so SQLite never
    /// creates it with the default (wider) umask permissions. A zero-length
    /// file is a valid fresh database to SQLite.
    private static func createEmptyDatabaseFile(at databaseURL: URL) throws(StoreError) {
        let created = FileManager.default.createFile(
            atPath: databaseURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw StoreError.cannotOpen(
                path: databaseURL.path, detail: "cannot create history file"
            )
        }
    }

    /// Opens the connection, verifies the schema version, and (for a usable
    /// file) configures the connection and ensures the schema exists.
    /// Throws `queryFailed` carrying SQLite's own result code — which is what
    /// tells init apart a corrupt file from a busy one — and closes the handle
    /// on every failure path.
    private static func openAndPrepare(at path: String, isFresh: Bool) throws(StoreError) -> OpaquePointer {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        )
        guard openResult == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            throw StoreError.cannotOpen(path: path, detail: "sqlite open code \(openResult)")
        }

        do throws(StoreError) {
            guard sqlite3_busy_timeout(db, 5000) == SQLITE_OK else {
                throw StoreError.cannotOpen(path: path, detail: "cannot set busy timeout")
            }

            // Read the version BEFORE any write-configuring statement, so a
            // future-versioned or corrupt file is never modified at all.
            let foundVersion = try readUserVersion(on: db)
            guard foundVersion <= schemaVersion else {
                throw StoreError.unsupportedSchemaVersion(
                    found: foundVersion, supported: schemaVersion
                )
            }

            try executeStatic(on: db, "PRAGMA journal_mode=WAL")
            // Apple's SQLite is built with SQLITE_DEFAULT_WAL_SYNCHRONOUS=1, so
            // enabling WAL silently drops synchronous from FULL to NORMAL and
            // commits stop calling fsync. The intent row would then be
            // "committed" while the rename it protects survives a power cut and
            // the row does not — a moved file with no history (M10, risk #6).
            // One fsync per Accept is user-paced and free; `index.db` stays at
            // NORMAL because it can always be rebuilt.
            try executeStatic(on: db, "PRAGMA synchronous=FULL")
            // Deleted rows are overwritten instead of being left readable in the
            // file's free pages — "Clear history" has to mean cleared (M9).
            try executeStatic(on: db, "PRAGMA secure_delete=ON")

            if isFresh {
                try inTransaction(on: db) { () throws(StoreError) in
                    try executeStatic(on: db, createMovesTable)
                    try stampUserVersion(on: db, schemaVersion)
                }
            } else if foundVersion < schemaVersion {
                try migrate(on: db, from: foundVersion)
            }
            return db
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
    }

    /// Ordered, explicit migrations — one step per version, each wrapped with
    /// its own version stamp in a transaction, so a crash mid-migration can
    /// never leave a half-migrated database stamped as done.
    ///
    /// One `case` per version with a `default` that refuses, so a database
    /// stamped with a version this build does not know about is never opened
    /// and half-migrated — it is reported, and the file is left untouched.
    private static func migrate(on db: OpaquePointer, from foundVersion: Int32) throws(StoreError) {
        var version = foundVersion
        while version < schemaVersion {
            let next = version + 1
            try inTransaction(on: db) { () throws(StoreError) in
                switch next {
                case 1:
                    // A file that exists but holds no schema yet.
                    try executeStatic(on: db, createMovesTable)
                case 2:
                    // Additive and nullable: rows written before this step keep
                    // a nil identity, which the reconcile reads as "cannot
                    // prove" and never as "matches".
                    try addColumnIfMissing(on: db, "source_device")
                    try addColumnIfMissing(on: db, "source_inode")
                default:
                    throw StoreError.unsupportedSchemaVersion(
                        found: next, supported: schemaVersion
                    )
                }
                try stampUserVersion(on: db, next)
            }
            version = next
        }
    }

    /// Adds one nullable INTEGER column to `moves` if it is not there already.
    /// The column name is a compile-time constant from the call sites above —
    /// never runtime data — which is why it can be interpolated at all.
    private static func addColumnIfMissing(
        on db: OpaquePointer, _ column: String
    ) throws(StoreError) {
        guard try !columnNames(on: db, table: "moves").contains(column) else { return }
        try executeStatic(on: db, "ALTER TABLE moves ADD COLUMN \(column) INTEGER")
    }

    private static func columnNames(
        on db: OpaquePointer, table: String
    ) throws(StoreError) -> Set<String> {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            db, "PRAGMA table_info(\(table))", -1, &statement, nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw StoreError.queryFailed(
                detail: "cannot read the table's columns: \(String(cString: sqlite3_errmsg(db)))",
                code: prepareResult
            )
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw StoreError.queryFailed(
                    detail: "cannot list the table's columns: \(String(cString: sqlite3_errmsg(db)))",
                    code: stepResult
                )
            }
            // Column 1 of PRAGMA table_info is the column's name.
            if let cString = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: cString))
            }
        }
        return names
    }

    /// PRAGMA cannot take a bound parameter; the value is always one of this
    /// type's own compile-time constants, never runtime data.
    private static func stampUserVersion(on db: OpaquePointer, _ version: Int32) throws(StoreError) {
        try executeStatic(on: db, "PRAGMA user_version = \(version)")
    }

    private static func inTransaction(
        on db: OpaquePointer, _ body: () throws(StoreError) -> Void
    ) throws(StoreError) {
        try executeStatic(on: db, "BEGIN")
        do throws(StoreError) {
            try body()
        } catch {
            // Best effort: if the rollback itself fails the transaction is
            // already doomed, and the original failure is the honest one.
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        try executeStatic(on: db, "COMMIT")
    }

    private static func readUserVersion(on db: OpaquePointer) throws(StoreError) -> Int32 {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw StoreError.queryFailed(
                detail: "cannot read user_version: \(String(cString: sqlite3_errmsg(db)))",
                code: prepareResult
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw StoreError.queryFailed(
                detail: "cannot step user_version: \(String(cString: sqlite3_errmsg(db)))",
                code: stepResult
            )
        }
        return sqlite3_column_int(statement, 0)
    }

    /// Renames the unusable database file (plus any WAL/SHM journals) out of
    /// the way. Rename preserves the bytes exactly — the evidence rule.
    private static func moveCorruptDatabaseAside(at databaseURL: URL) throws(StoreError) -> URL {
        let suffix = ".corrupt-\(UUID().uuidString)"
        let movedTo = URL(fileURLWithPath: databaseURL.path + suffix)
        do {
            try FileManager.default.moveItem(at: databaseURL, to: movedTo)
        } catch {
            throw StoreError.cannotOpen(
                path: databaseURL.path,
                detail: "cannot move the unreadable history aside: \(error.localizedDescription)"
            )
        }
        // Journals of the dead database would poison a fresh one; keep them
        // next to the moved-aside file instead.
        for journal in ["-wal", "-shm"] {
            let journalPath = databaseURL.path + journal
            guard FileManager.default.fileExists(atPath: journalPath) else { continue }
            try? FileManager.default.moveItem(
                at: URL(fileURLWithPath: journalPath),
                to: URL(fileURLWithPath: journalPath + suffix)
            )
        }
        return movedTo
    }

    /// Static-context variant of `execute` for use during opening.
    private static func executeStatic(on db: OpaquePointer, _ sql: String) throws(StoreError) {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw StoreError.queryFailed(
                detail: "executing statement: \(String(cString: sqlite3_errmsg(db)))",
                code: code
            )
        }
    }

    // MARK: - Statement helpers

    /// The live handle, or a typed error once the store is closed. "Closed" is
    /// exactly the app-level condition "the undo history is unavailable", which
    /// founder decision 1 turns into "then do not move the file".
    private func openHandle() throws(StoreError) -> OpaquePointer {
        guard let db else {
            throw .queryFailed(detail: "the history database is closed", code: SQLITE_MISUSE)
        }
        return db
    }

    private func execute(on db: OpaquePointer, _ sql: String) throws(StoreError) {
        try Self.executeStatic(on: db, sql)
    }

    private func prepare(on db: OpaquePointer, _ sql: String) throws(StoreError) -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw StoreError.queryFailed(
                detail: "preparing statement: \(errorMessage(db))", code: code
            )
        }
        return statement
    }

    private func step(
        _ statement: OpaquePointer, on db: OpaquePointer, describing what: String
    ) throws(StoreError) {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw StoreError.queryFailed(detail: "\(what): \(errorMessage(db))", code: code)
        }
    }

    /// The typed failure for whatever just went wrong on `db`, carrying
    /// SQLite's own result code so the caller can tell corruption from a lock.
    private func queryFailure(_ what: String, on db: OpaquePointer) -> StoreError {
        .queryFailed(detail: "\(what): \(errorMessage(db))", code: sqlite3_errcode(db))
    }

    private func errorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    /// Binds a String. SQLite stores the UTF-8 bytes verbatim — no Unicode
    /// normalization — which is what lets a name stored in NFD come back in NFD
    /// and still match the bytes on disk.
    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ text: String) -> Bool {
        sqlite3_bind_text(statement, index, text, -1, Self.transientBytes) == SQLITE_OK
    }

    private func bindOptionalText(
        _ statement: OpaquePointer, _ index: Int32, _ text: String?
    ) -> Bool {
        guard let text else {
            return sqlite3_bind_null(statement, index) == SQLITE_OK
        }
        return bindText(statement, index, text)
    }

    private func bindOptionalInt64(
        _ statement: OpaquePointer, _ index: Int32, _ value: Int64?
    ) -> Bool {
        guard let value else {
            return sqlite3_bind_null(statement, index) == SQLITE_OK
        }
        return sqlite3_bind_int64(statement, index, value) == SQLITE_OK
    }

    // MARK: - Decoding

    private func readAll(
        _ statement: OpaquePointer, on db: OpaquePointer, describing what: String
    ) throws(StoreError) -> [MoveRecord] {
        var records: [MoveRecord] = []
        var skipped = 0
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw StoreError.queryFailed(
                    detail: "reading \(what): \(errorMessage(db))", code: stepResult
                )
            }
            // A row this build cannot decode — an unknown state or fallback
            // reason, most likely written by a newer version — is skipped, not
            // fatal. Throwing here took `recent()`, `record(id:)` AND the launch
            // reconcile down together, so one odd row meant no history, no undo,
            // and no reconcile at all (X5). Skipping is only acceptable because
            // the count is reported: `unreadableRowsInLastRead` is what stops
            // this being a shorter list nobody is told about.
            do throws(StoreError) {
                records.append(try decode(statement))
            } catch {
                skipped += 1
                devLog("skipped an unreadable row while reading \(what): \(error)")
            }
        }
        unreadableRowsInLastRead = skipped
        return records
    }

    // MARK: - Test seam

    #if DEBUG
    /// Armed by a test to make the NEXT write fail as SQLite would.
    private var injectedWriteFailure: StoreError?

    /// Makes the next `finalize` / `markFailed` / `markUndone` throw.
    ///
    /// The branches this reaches are the ones that matter most in this
    /// milestone: the file has ALREADY moved and only the row is left to write,
    /// so the app must report the truth about the user's disk and admit the
    /// record is wrong (F7/F8). They cannot be reached any other way — closing
    /// the store makes the *first* call fail instead, before anything moves.
    ///
    /// One-shot, and compiled out of release entirely: `swift build -c release`
    /// does not define DEBUG, so no shipped binary carries a way to make the
    /// history refuse a write.
    func failNextWrite(
        _ error: StoreError = .queryFailed(detail: "injected by a test", code: SQLITE_ERROR)
    ) {
        injectedWriteFailure = error
    }
    #endif

    /// Consumes a test-armed failure, if there is one. Compiles to nothing in
    /// release builds.
    private func consumeInjectedFailure() throws(StoreError) {
        #if DEBUG
        if let armed = injectedWriteFailure {
            injectedWriteFailure = nil
            throw armed
        }
        #endif
    }

    /// Dev-build diagnostics only, control-character-sanitized. Never file
    /// contents; a typed error description may carry a path, which is
    /// dev-build-only per docs/process/engineering-rules.md.
    private func devLog(_ message: String) {
        #if DEBUG
        print("MoveHistoryStore: \(LogSanitizer.sanitized(message))")
        #endif
    }

    /// Column indexes follow `selectColumns`, which every read shares.
    private func decode(_ statement: OpaquePointer) throws(StoreError) -> MoveRecord {
        guard let fileEventID = UUID(uuidString: columnText(statement, 1)) else {
            throw .queryFailed(detail: "history row has an unreadable file id", code: SQLITE_OK)
        }
        guard let state = MoveState(rawValue: columnText(statement, 7)) else {
            throw .queryFailed(detail: "history row has an unknown state", code: SQLITE_OK)
        }
        let fallbackReason: MoveFallbackReason?
        if let raw = columnOptionalText(statement, 8) {
            guard let reason = MoveFallbackReason(rawValue: raw) else {
                throw .queryFailed(
                    detail: "history row has an unknown fallback reason", code: SQLITE_OK
                )
            }
            fallbackReason = reason
        } else {
            fallbackReason = nil
        }

        return MoveRecord(
            id: sqlite3_column_int64(statement, 0),
            fileEventID: fileEventID,
            originalDirectory: directoryURL(columnText(statement, 2)),
            originalName: columnText(statement, 3),
            finalDirectory: directoryURL(columnText(statement, 4)),
            finalName: columnText(statement, 5),
            destinationFolderName: columnOptionalText(statement, 6),
            state: state,
            fallbackReason: fallbackReason,
            failureDetail: columnOptionalText(statement, 9),
            sourceIdentity: identity(statement, deviceIndex: 12, inodeIndex: 13),
            acceptedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            settledAt: columnOptionalDate(statement, 11)
        )
    }

    /// Both halves or neither: half an identity proves nothing, and the
    /// reconcile treats nil as "cannot prove".
    private func identity(
        _ statement: OpaquePointer, deviceIndex: Int32, inodeIndex: Int32
    ) -> FileIdentity? {
        guard sqlite3_column_type(statement, deviceIndex) != SQLITE_NULL,
              sqlite3_column_type(statement, inodeIndex) != SQLITE_NULL else {
            return nil
        }
        return FileIdentity(
            deviceID: sqlite3_column_int64(statement, deviceIndex),
            inode: sqlite3_column_int64(statement, inodeIndex)
        )
    }

    /// `isDirectory: true` so the URL is built from the stored path alone,
    /// without a filesystem probe — the folder may well be gone, and that is
    /// precisely a case undo has to report honestly rather than misread.
    private func directoryURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, index)
    }

    private func columnOptionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }
}
