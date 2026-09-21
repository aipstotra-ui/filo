import Foundation
import SQLite3
import Testing
@testable import FileOrganizer

/// Raw SQLite access for black-box verification — these tests inspect the
/// history file with the same C API the store uses, never through the store.
private enum HistoryRawSQLite {
    struct Failure: Error { let message: String }

    static func queryInt64s(_ sql: String, at url: URL) throws -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw Failure(message: "cannot open \(url.path)")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(message: "cannot prepare: \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(sqlite3_column_int64(statement, 0))
        }
        return rows
    }

    static func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw Failure(message: "cannot open \(url.path)")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure(message: "cannot execute: \(sql)")
        }
    }
}

/// Contract tests for `MoveHistoryStore` — the only record of what this app did
/// to the user's files, so its failure modes matter as much as its happy path.
/// A class suite so each test gets a fresh temp directory, removed in deinit.
@Suite("MoveHistoryStore")
final class MoveHistoryStoreTests {

    private let tempDir: URL
    /// Inside a store-owned subdirectory that must NOT pre-exist: the store
    /// creates it (with tight permissions) on first open. Never the real
    /// Application Support directory.
    private let databaseURL: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoveHistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir
            .appendingPathComponent("container")
            .appendingPathComponent("history.db")
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    private var downloads: URL { tempDir.appendingPathComponent("Downloads") }
    private var invoices: URL { tempDir.appendingPathComponent("Invoices") }

    private func intent(
        name: String = "Scan 2026-07-20 14.33.pdf",
        intendedName: String = "Chase Statement June 2026.pdf",
        intendedDirectory: URL? = nil,
        folderName: String? = "Invoices",
        fallback: MoveFallbackReason? = nil,
        fileEventID: UUID = UUID(),
        sourceIdentity: FileIdentity? = FileIdentity(deviceID: 16_777_232, inode: 4_242_424),
        acceptedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> MoveIntent {
        MoveIntent(
            fileEventID: fileEventID,
            originalDirectory: downloads,
            originalName: name,
            intendedDirectory: intendedDirectory ?? invoices,
            intendedName: intendedName,
            destinationFolderName: folderName,
            fallbackReason: fallback,
            sourceIdentity: sourceIdentity,
            acceptedAt: acceptedAt
        )
    }

    private func posixPermissions(atPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - 1. Opening

    @Test("First open creates the schema and stamps PRAGMA user_version")
    func firstOpenCreatesSchemaAndVersion() async throws {
        #expect(MoveHistoryStore.schemaVersion >= 1)

        let store = try MoveHistoryStore(databaseURL: databaseURL)
        #expect(store.openOutcome == .createdFresh)
        await store.close()

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        let version = try HistoryRawSQLite.queryInt64s("PRAGMA user_version", at: databaseURL)
        #expect(version == [Int64(MoveHistoryStore.schemaVersion)])

        let reopened = try MoveHistoryStore(databaseURL: databaseURL)
        #expect(reopened.openOutcome == .openedExisting)
        await reopened.close()
    }

    @Test("The history DB is created 0o600 inside a 0o700 store-owned directory")
    func filePermissionsAreTight() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        await store.close()

        #expect(try posixPermissions(atPath: databaseURL.path) == 0o600)
        #expect(try posixPermissions(atPath: databaseURL.deletingLastPathComponent().path) == 0o700)
    }

    // MARK: - 2. Two-phase write

    @Test("recordIntent writes an inProgress row carrying the INTENDED destination")
    func intentRowIsWrittenFirst() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let planned = intent()

        let id = try await store.recordIntent(planned)
        let row = try #require(try await store.record(id: id))

        #expect(row.state == .inProgress)
        #expect(row.fileEventID == planned.fileEventID)
        #expect(row.originalDirectory.path == downloads.path)
        #expect(row.originalName == planned.originalName)
        // The intended target is persisted BEFORE the move, which is the only
        // thing that makes the launch reconcile possible.
        #expect(row.finalDirectory.path == invoices.path)
        #expect(row.finalName == planned.intendedName)
        #expect(row.destinationFolderName == "Invoices")
        #expect(row.fallbackReason == nil)
        #expect(row.failureDetail == nil)
        #expect(row.settledAt == nil, "an in-progress row has not settled")
        #expect(abs(row.acceptedAt.timeIntervalSince(planned.acceptedAt)) < 0.001)
        #expect(row.isUndoable == false, "an in-progress row must never offer undo")

        let pending = try await store.inProgressRecords()
        #expect(pending.map(\.id) == [id])
        await store.close()
    }

    @Test("finalize records the name the file ACTUALLY got, not the one we asked for")
    func finalizeRecordsTheResolvedPath() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let id = try await store.recordIntent(intent())
        let settled = Date(timeIntervalSince1970: 1_800_000_060)

        // The mover had to dedup: the row must say where the file really is,
        // or undo would look in the wrong place.
        try await store.finalize(
            id: id, finalDirectory: invoices, finalName: "Chase Statement June 2026 2.pdf",
            at: settled
        )
        let row = try #require(try await store.record(id: id))

        #expect(row.state == .moved)
        #expect(row.finalName == "Chase Statement June 2026 2.pdf")
        #expect(row.finalDirectory.path == invoices.path)
        #expect(row.isUndoable)
        #expect(row.failureDetail == nil)
        #expect(abs((row.settledAt ?? .distantPast).timeIntervalSince(settled)) < 0.001)
        #expect(try await store.inProgressRecords().isEmpty)
        await store.close()
    }

    @Test("markFailed settles the row as failed with an honest reason, and offers no undo")
    func markFailedSettlesHonestly() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let id = try await store.recordIntent(intent())

        try await store.markFailed(
            id: id, detail: "destination not writable", at: Date(timeIntervalSince1970: 1)
        )
        let row = try #require(try await store.record(id: id))

        #expect(row.state == .failed)
        #expect(row.failureDetail == "destination not writable")
        #expect(row.isUndoable == false)
        #expect(row.settledAt != nil)
        #expect(try await store.inProgressRecords().isEmpty)
        await store.close()
    }

    @Test("A fallback reason survives the round trip, so the menu can say why")
    func fallbackReasonRoundTrips() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let id = try await store.recordIntent(intent(
            intendedDirectory: downloads, folderName: nil, fallback: .folderMissing
        ))

        let row = try #require(try await store.record(id: id))
        #expect(row.fallbackReason == .folderMissing)
        #expect(row.destinationFolderName == nil)
        #expect(row.finalDirectory.path == downloads.path, "a fallback renames in place")
        await store.close()
    }

    @Test("Non-ASCII names and paths round-trip byte-identically")
    func unicodeRoundTrips() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let eventID = UUID()
        let id = try await store.recordIntent(intent(
            name: "発注書 🧾.pdf",
            // NFD: the exact byte sequence APFS was given. Storing the NFC form
            // instead would leave undo looking for a name that is equal to a
            // human but not to a byte comparison.
            intendedName: "facture caf\u{65}\u{301} juin.pdf",
            folderName: "فواتير",
            fileEventID: eventID
        ))

        let row = try #require(try await store.record(id: id))
        #expect(row.originalName == "発注書 🧾.pdf")
        #expect(row.finalName.unicodeScalars.elementsEqual("facture caf\u{65}\u{301} juin.pdf".unicodeScalars),
                "the stored name must match the disk byte-for-byte, or undo can't find the file")
        #expect(row.destinationFolderName == "فواتير")
        #expect(row.fileEventID == eventID)
        await store.close()
    }

    // MARK: - 3. State-guarded undo

    @Test("markUndone flips a moved row exactly once — a second undo cannot win")
    func markUndoneIsStateGuarded() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let id = try await store.recordIntent(intent())
        try await store.finalize(id: id, finalDirectory: invoices, finalName: "final.pdf", at: Date())

        let first = try await store.markUndone(
            id: id, restoredDirectory: downloads, restoredName: "original.pdf", at: Date()
        )
        let second = try await store.markUndone(
            id: id, restoredDirectory: downloads, restoredName: "SHOULD NOT WIN.pdf", at: Date()
        )

        #expect(first, "the first undo flips the row")
        #expect(second == false, "the second must lose — the guard is inside the UPDATE")
        let row = try #require(try await store.record(id: id))
        #expect(row.state == .undone)
        #expect(row.finalName == "original.pdf",
                "the losing undo must not have rewritten the row")
        #expect(row.isUndoable == false)
        await store.close()
    }

    // A "two concurrent undos" test used to sit here. It was removed rather than
    // repaired because it could not fail: both `async let` calls entered the same
    // actor and `markUndone` contains no suspension point, so they ran strictly
    // one after the other and the test was a silent duplicate of
    // `markUndoneIsStateGuarded` above. A test that cannot observe the thing it
    // names is worse than no test — it reads like coverage of the double-undo
    // race while providing none. The actual guarantee lives in the statement
    // (`UPDATE ... WHERE state = 'moved'`), which `markUndoneIsStateGuarded` and
    // `markUndoneRefusesOtherStates` do pin.

    @Test("markUndone refuses any state that is not `moved`",
          arguments: [MoveState.inProgress, .failed, .unknown])
    func markUndoneRefusesOtherStates(state: MoveState) async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let id = try await store.recordIntent(intent())
        switch state {
        case .failed:
            try await store.markFailed(id: id, detail: "nope", at: Date())
        case .unknown:
            _ = try await store.reconcileInProgress(acceptedBefore: .distantFuture) { _ in
                DiskPresence(
                    sourceExists: false, targetExists: false, targetIsTheFileWeMoved: false
                )
            }
        default:
            break   // left in progress
        }

        let flipped = try await store.markUndone(
            id: id, restoredDirectory: downloads, restoredName: "x.pdf", at: Date()
        )

        #expect(flipped == false)
        let row = try #require(try await store.record(id: id))
        #expect(row.state == state)
        await store.close()
    }

    // MARK: - 4. Reading and retention

    @Test("recent(limit:) returns the newest rows first")
    func recentIsNewestFirst() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        var ids: [Int64] = []
        for index in 1...7 {
            ids.append(try await store.recordIntent(intent(name: "file-\(index).pdf")))
        }

        let newestThree = try await store.recent(limit: 3)

        #expect(newestThree.map(\.id) == ids.suffix(3).reversed())
        #expect(newestThree.first?.originalName == "file-7.pdf")
        #expect(try await store.recent(limit: 100).count == 7,
                "asking for more than exists returns everything, not an error")
        #expect(try await store.recent(limit: 0).isEmpty)
        await store.close()
    }

    @Test("pruneBeyond keeps the newest N rows and deletes the rest")
    func pruningKeepsTheNewest() async throws {
        #expect(MoveHistoryStore.retentionLimit == 200, "founder decision 3: keep the last 200")

        let store = try MoveHistoryStore(databaseURL: databaseURL)
        var ids: [Int64] = []
        for index in 1...12 {
            let id = try await store.recordIntent(intent(name: "file-\(index).pdf"))
            // Settled deliberately: retention only ever reaches rows whose move
            // has finished. `pruneBeyondSparesInFlightRows` covers the other case.
            try await store.finalize(
                id: id, finalDirectory: invoices, finalName: "file-\(index).pdf", at: Date()
            )
            ids.append(id)
        }

        let deleted = try await store.pruneBeyond(5)

        #expect(deleted == 7)
        let remaining = try await store.recent(limit: 100)
        #expect(remaining.count == 5)
        #expect(Set(remaining.map(\.id)) == Set(ids.suffix(5)))
        #expect(try await store.pruneBeyond(5) == 0, "pruning again deletes nothing")
        await store.close()
    }

    @Test("clearAll empties the history and leaves the store usable")
    func clearAllEmptiesTheHistory() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        for index in 1...3 {
            let id = try await store.recordIntent(intent(name: "file-\(index).pdf"))
            try await store.finalize(
                id: id, finalDirectory: invoices, finalName: "file-\(index).pdf", at: Date()
            )
        }

        let outcome = try await store.clearAll()

        #expect(outcome.rowsKept == 0, "nothing was in flight, so nothing may be left behind")
        #expect(outcome.wasComplete, "and the clear is reported as complete")
        #expect(try await store.recent(limit: 100).isEmpty)
        let freshID = try await store.recordIntent(intent(name: "after.pdf"))
        #expect(try await store.record(id: freshID)?.originalName == "after.pdf")
        await store.close()
    }

    @Test("M17: clearAll leaves a move that is happening right now alone, and says so")
    func clearAllSpareInFlightRows() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let settledID = try await store.recordIntent(intent(name: "done.pdf"))
        try await store.finalize(
            id: settledID, finalDirectory: invoices, finalName: "done.pdf", at: Date()
        )
        // Never finalized: this row belongs to a move still in flight.
        let inFlightID = try await store.recordIntent(intent(name: "moving-right-now.pdf"))

        let outcome = try await store.clearAll()

        #expect(outcome.rowsKept == 1, "clearAll must report what it could not clear")
        #expect(try await store.record(id: settledID) == nil, "the settled row is gone")
        let survivor = try #require(try await store.record(id: inFlightID))
        #expect(survivor.state == .inProgress)
        // The point of sparing it: the move's own finalize must still land.
        // Deleting the row would make finalize fail and leave a moved file with
        // no record at all.
        try await store.finalize(
            id: inFlightID, finalDirectory: invoices, finalName: "moving-right-now.pdf", at: Date()
        )
        #expect(try await store.record(id: inFlightID)?.state == .moved)
        await store.close()
    }

    @Test("M9: clearAll leaves no readable trace of the filenames in the file itself")
    func clearAllScrubsTheRawBytes() async throws {
        // macOS's system SQLite is not built with SECURE_DELETE, so a plain
        // DELETE leaves every filename and path sitting in the file's free
        // pages, recoverable with `strings`. Founder decision 3 promises this
        // button clears the history, so this asserts on the raw bytes rather
        // than trusting a SELECT to come back empty.
        let secret = "SECRETDOC-2026-divorce-settlement.pdf"
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        for index in 1...40 {
            let id = try await store.recordIntent(
                intent(name: "\(index)-\(secret)", intendedName: "\(index)-\(secret)")
            )
            try await store.finalize(
                id: id, finalDirectory: invoices, finalName: "\(index)-\(secret)", at: Date()
            )
        }
        #expect(try rawOccurrences(of: secret) > 0, "guard: the data must be there to begin with")

        try await store.clearAll()
        await store.close()

        #expect(try rawOccurrences(of: secret) == 0,
                "cleared history must not be recoverable from the database, WAL, or shm")
    }

    /// Counts occurrences of `needle` across the raw bytes of the database and
    /// its sidecar files — the same thing `strings` would find.
    private func rawOccurrences(of needle: String) throws -> Int {
        let pattern = Data(needle.utf8)
        var total = 0
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard let bytes = try? Data(contentsOf: url), !bytes.isEmpty else { continue }
            var searchFrom = bytes.startIndex
            while let found = bytes[searchFrom...].firstRange(of: pattern) {
                total += 1
                searchFrom = found.lowerBound + 1
                if searchFrom >= bytes.endIndex { break }
            }
        }
        return total
    }

    @Test("Rows survive closing and reopening the store")
    func rowsSurviveCloseAndReopen() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let id = try await store.recordIntent(intent(name: "persisted.pdf"))
        try await store.finalize(
            id: id, finalDirectory: invoices, finalName: "renamed.pdf", at: Date()
        )
        await store.close()

        let reopened = try MoveHistoryStore(databaseURL: databaseURL)
        #expect(reopened.openOutcome == .openedExisting)
        let row = try #require(try await reopened.record(id: id))
        #expect(row.originalName == "persisted.pdf")
        #expect(row.finalName == "renamed.pdf")
        #expect(row.state == .moved)
        #expect(row.isUndoable, "undo must still be offered after a relaunch")
        await reopened.close()
    }

    @Test("finalize refuses a row that has already settled")
    func finalizeRefusesAnAlreadySettledRow() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let id = try await store.recordIntent(intent())
        try await store.finalize(id: id, finalDirectory: invoices, finalName: "one.pdf", at: Date())

        await #expect(throws: MoveHistoryStore.StoreError.self, "a second finalize must not rewrite a settled row") {
            try await store.finalize(
                id: id, finalDirectory: invoices, finalName: "two.pdf", at: Date()
            )
        }
        #expect(try await store.record(id: id)?.finalName == "one.pdf")
        await store.close()
    }

    @Test("M16: pruneBeyond refuses a limit that would wipe the whole table",
          arguments: [0, -1, -200])
    func pruneBeyondRefusesNonPositiveLimits(keeping: Int) async throws {
        // `LIMIT 0` makes the subquery empty, and `NOT IN (empty)` is TRUE for
        // every row — so an unguarded pruneBeyond(0) silently deletes an
        // irreplaceable table.
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        for index in 1...4 {
            _ = try await store.recordIntent(intent(name: "keep-\(index).pdf"))
        }

        await #expect(throws: MoveHistoryStore.StoreError.self) {
            _ = try await store.pruneBeyond(keeping)
        }
        #expect(try await store.recent(limit: 100).count == 4, "no row may have been deleted")
        await store.close()
    }

    @Test("M16: pruning never deletes a move that is still in flight")
    func pruneBeyondSparesInFlightRows() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        // The oldest row is still in progress, so retention would otherwise
        // reach it first and destroy the only record of a running move.
        let inFlightID = try await store.recordIntent(intent(name: "oldest-still-moving.pdf"))
        for index in 1...6 {
            let id = try await store.recordIntent(intent(name: "settled-\(index).pdf"))
            try await store.finalize(
                id: id, finalDirectory: invoices, finalName: "settled-\(index).pdf", at: Date()
            )
        }

        _ = try await store.pruneBeyond(2)

        #expect(try await store.record(id: inFlightID)?.state == .inProgress,
                "an inProgress row must survive retention pruning")
        await store.close()
    }

    @Test("An unknown record id reads back as nil, not as a crash or a fake row")
    func unknownRecordIsNil() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        #expect(try await store.record(id: 987_654) == nil)
        await store.close()
    }

    // MARK: - 5. Launch reconcile

    @Test("The reconcile rule is honest: only one disk combination is conclusive enough to undo")
    func reconcileRuleIsHonest() {
        // Source gone, target present, and the file there is provably ours.
        #expect(MoveHistoryStore.reconciledState(
            for: DiskPresence(sourceExists: false, targetExists: true, targetIsTheFileWeMoved: true)
        ) == .moved)
        #expect(MoveHistoryStore.reconciledState(
            for: DiskPresence(sourceExists: true, targetExists: false, targetIsTheFileWeMoved: false)
        ) == .failed)
        // Both present: we cannot tell our move from an unrelated file that
        // happens to share the name. Neither present: the file went somewhere
        // we did not put it. Guessing either way could lose a file.
        #expect(MoveHistoryStore.reconciledState(
            for: DiskPresence(sourceExists: true, targetExists: true, targetIsTheFileWeMoved: false)
        ) == .unknown)
        #expect(MoveHistoryStore.reconciledState(
            for: DiskPresence(sourceExists: false, targetExists: false, targetIsTheFileWeMoved: false)
        ) == .unknown)
    }

    @Test("C2: a stranger's file at the intended name is never adopted as ours")
    func reconcileRefusesToAdoptAStrangersFile() {
        // The exact C2 shape: the row's source is gone and *a* file sits at the
        // intended final path — but it is not the one we moved, because a
        // collision sent ours to "report 2.pdf". Name alone would say `.moved`
        // and offer an Undo that relocates a file this app never touched.
        let strangerAtTheTargetName = DiskPresence(
            sourceExists: false, targetExists: true, targetIsTheFileWeMoved: false
        )

        #expect(MoveHistoryStore.reconciledState(for: strangerAtTheTargetName) == .unknown,
                "identity must decide this, not the filename")
        // Undo is offered on `.moved` alone (`MoveRecord.isUndoable`), so landing
        // on `.unknown` is exactly what withholds it. `reconcileResolvesEveryStrandedRow`
        // pins that end-to-end on a real row.
        #expect(MoveHistoryStore.reconciledState(for: strangerAtTheTargetName) != .moved)
    }

    @Test("Stranded inProgress rows reconcile across all four disk combinations")
    func reconcileResolvesEveryStrandedRow() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let movedID = try await store.recordIntent(intent(name: "moved.pdf"))
        let failedID = try await store.recordIntent(intent(name: "failed.pdf"))
        let bothID = try await store.recordIntent(intent(name: "both.pdf"))
        let neitherID = try await store.recordIntent(intent(name: "neither.pdf"))
        // A settled row must not be touched by the reconcile pass.
        let settledID = try await store.recordIntent(intent(name: "settled.pdf"))
        try await store.finalize(
            id: settledID, finalDirectory: invoices, finalName: "settled.pdf", at: Date()
        )

        let presences: [String: DiskPresence] = [
            "moved.pdf": DiskPresence(
                sourceExists: false, targetExists: true, targetIsTheFileWeMoved: true
            ),
            "failed.pdf": DiskPresence(
                sourceExists: true, targetExists: false, targetIsTheFileWeMoved: false
            ),
            "both.pdf": DiskPresence(
                sourceExists: true, targetExists: true, targetIsTheFileWeMoved: false
            ),
            "neither.pdf": DiskPresence(
                sourceExists: false, targetExists: false, targetIsTheFileWeMoved: false
            ),
        ]
        let reconciled = try await store.reconcileInProgress(acceptedBefore: .distantFuture) { record in
            presences[record.originalName] ?? DiskPresence(
                sourceExists: true, targetExists: true, targetIsTheFileWeMoved: false
            )
        }

        #expect(reconciled.settled.count == 4, "only the stranded rows are reconciled")
        #expect(reconciled.unresolved.isEmpty, "no row should have failed to settle here")
        var states: [Int64: MoveState] = [:]
        for record in reconciled.settled { states[record.id] = record.state }
        #expect(states[movedID] == .moved)
        #expect(states[failedID] == .failed)
        #expect(states[bothID] == .unknown)
        #expect(states[neitherID] == .unknown)

        #expect(try await store.inProgressRecords().isEmpty, "nothing may stay stranded")
        #expect(try await store.record(id: movedID)?.isUndoable == true)
        #expect(try await store.record(id: bothID)?.isUndoable == false,
                "an unknown row must NEVER offer undo — we do not guess where a file went")
        #expect(try await store.record(id: settledID)?.state == .moved)
        #expect(try await store.record(id: neitherID)?.settledAt != nil)
        await store.close()
    }

    // MARK: - 6. Failure modes

    @Test("A corrupt history file is moved aside INTACT and surfaced, never silently reset")
    func corruptHistoryIsPreservedAndSurfaced() async throws {
        let original = try MoveHistoryStore(databaseURL: databaseURL)
        _ = try await original.recordIntent(intent())
        await original.close()

        let garbage = Data(repeating: 0x5A, count: 1024)   // not a SQLite header
        try garbage.write(to: databaseURL)

        let recovered = try MoveHistoryStore(databaseURL: databaseURL)
        guard case .recoveredFromCorruption(let movedTo) = recovered.openOutcome else {
            Issue.record("expected .recoveredFromCorruption, got \(recovered.openOutcome)")
            return
        }
        #expect(movedTo != databaseURL)
        #expect(
            try Data(contentsOf: movedTo) == garbage,
            "history is irreplaceable: the unreadable file is evidence and must survive intact"
        )
        // And the fresh store works, so the app is usable again.
        let id = try await recovered.recordIntent(intent())
        #expect(try await recovered.record(id: id) != nil)
        await recovered.close()
    }

    @Test("An unknown FUTURE user_version is refused typed, with the file left untouched")
    func futureSchemaVersionRefusedTyped() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        await store.close()
        try HistoryRawSQLite.execute("PRAGMA user_version = 9999", at: databaseURL)

        #expect(throws: MoveHistoryStore.StoreError.unsupportedSchemaVersion(
            found: 9999, supported: MoveHistoryStore.schemaVersion
        )) {
            _ = try MoveHistoryStore(databaseURL: self.databaseURL)
        }

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        let version = try HistoryRawSQLite.queryInt64s("PRAGMA user_version", at: databaseURL)
        #expect(version == [9999], "no half-migration, no move-aside")
    }

    @Test("A closed store fails every write typed — this is 'the history is unavailable'")
    func closedStoreFailsTyped() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        await store.close()

        await #expect(throws: MoveHistoryStore.StoreError.self) {
            _ = try await store.recordIntent(self.intent())
        }
        await #expect(throws: MoveHistoryStore.StoreError.self) {
            _ = try await store.recent(limit: 5)
        }
    }

    // MARK: - F5: the delete is the commit point

    @Test("F5: a clear whose tidy-up fails still reports the history as CLEARED")
    func clearThatCannotCompactStillCleared() async throws {
        // The rows are deleted in autocommit, and the VACUUM that follows runs
        // outside any transaction. When it threw — a full disk, a lock — the
        // whole call reported `.historyUnavailable`, so the user was told
        // "the history couldn't be cleared" while the rows were already gone.
        // They then sat looking at a list that no longer existed, every Undo on
        // which failed.
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let id = try await store.recordIntent(intent())
        try await store.finalize(
            id: id, finalDirectory: invoices, finalName: "x.pdf", at: Date()
        )

        await store.failNextWrite()
        let outcome = try await store.clearAll()

        #expect(outcome.compactionFailed, "guard: the tidy-up really did fail")
        #expect(outcome.rowsKept == 0)
        #expect(!outcome.wasComplete, "the user is told about the tidy-up…")
        #expect(try await store.recent(limit: 10).isEmpty,
                "…but the rows really are gone, which is what 'cleared' means")
        await store.close()
    }

    // MARK: - F6: the launch reconcile must not settle a LIVE move's row

    @Test("F6: a row accepted after the launch cutoff is left alone")
    func reconcileSkipsRowsAcceptedAfterTheCutoff() async throws {
        // Nothing stops a second copy of the app running — no bundle, no
        // LSMultipleInstancesProhibited, and the founder is told to run the
        // binary from a terminal. Instance B's reconcile used to settle instance
        // A's live row as `failed` ("the file stayed where it was") while A was
        // moving the file. Net: the file moved, and the permanent record said it
        // did not.
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let accepted = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try await store.recordIntent(intent(acceptedAt: accepted))

        let report = try await store.reconcileInProgress(
            acceptedBefore: accepted.addingTimeInterval(-1)
        ) { _ in
            DiskPresence(sourceExists: true, targetExists: false, targetIsTheFileWeMoved: false)
        }

        #expect(report.settled.isEmpty, "a move started since launch settles itself")
        let row = try #require(try await store.record(id: id))
        #expect(row.state == .inProgress, "and its row is untouched")
        await store.close()
    }

    @Test("F6: a row whose move is in flight in THIS instance is left alone")
    func reconcileSkipsInFlightRows() async throws {
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let eventID = UUID()
        let id = try await store.recordIntent(intent(fileEventID: eventID))

        let report = try await store.reconcileInProgress(
            acceptedBefore: .distantFuture, excluding: [eventID]
        ) { _ in
            DiskPresence(sourceExists: true, targetExists: false, targetIsTheFileWeMoved: false)
        }

        #expect(report.settled.isEmpty)
        #expect(try await store.record(id: id)?.state == .inProgress)
        await store.close()
    }

    @Test("F6: a genuinely stranded row is still reconciled")
    func reconcileStillSettlesStrandedRows() async throws {
        // The other half: over-skipping would leave every interrupted move
        // stuck at `inProgress` forever, offering no undo and no explanation.
        let store = try MoveHistoryStore(databaseURL: databaseURL)
        let accepted = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try await store.recordIntent(intent(acceptedAt: accepted))

        let report = try await store.reconcileInProgress(
            acceptedBefore: accepted.addingTimeInterval(60)
        ) { _ in
            DiskPresence(sourceExists: true, targetExists: false, targetIsTheFileWeMoved: false)
        }

        #expect(report.settled.count == 1)
        #expect(try await store.record(id: id)?.state == .failed)
        await store.close()
    }
}
