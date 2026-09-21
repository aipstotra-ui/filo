import Foundation
import SQLite3

/// SQLite's SQLITE_TRANSIENT destructor constant, unavailable directly from
/// Swift because it is a C macro casting -1 to a function pointer. Tells
/// SQLite to copy bound bytes immediately, so Swift-managed buffers may be
/// freed as soon as the bind call returns.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A folder profile as read back from the store: the SQLite row ID plus the
/// persisted fields. Ephemeral diagnostics (`contentSampleFailures`,
/// `sampledFileNames`) are deliberately NOT persisted.
struct StoredFolderProfile: Sendable, Equatable {
    let id: Int64
    let canonicalPath: String
    let displayName: String
    /// Every non-hidden, non-directory file seen at profiling time — the
    /// "34 files" half of the "Indexed · 34 files, 3 read" status line.
    let totalFileCount: Int
    /// Byte-identical round trip of the inserted vectors, same order,
    /// kinds preserved.
    let vectors: [FolderVector]
    /// Ordinary (unsandboxed) URL bookmark data, so a folder that is renamed
    /// or moved is found again on relaunch. nil for rows inserted without one.
    let bookmark: Data?
    /// FolderStatus.rawValue at last persist. The registry re-derives live
    /// status on load; this is the last honest on-disk record.
    let statusRaw: String
    /// When the folder was last successfully scanned; nil if never.
    let lastScannedAt: Date?

    /// The "3 read" half of the status line, derived from the persisted
    /// `.content` vectors exactly as `FolderProfile.contentReadCount` is.
    var contentReadCount: Int {
        vectors.filter { $0.kind == .content }.count
    }
}

/// SQLite-backed persistence for folder profiles, via the raw built-in C API
/// (`import SQLite3`) — no third-party packages. An actor: the sqlite3 handle
/// is mutable state confined here.
///
/// Schema contract pinned by FolderIndexStoreTests (the store is the only
/// schema owner):
/// - `PRAGMA user_version` == `FolderIndexStore.schemaVersion` after open
/// - vectors live in table `folder_vectors` with a `dimension` column
///   recording each vector's element count next to its `embedding` BLOB
/// - `canonical_path` is UNIQUE — a second insert of the same path throws
///   `StoreError.duplicateFolderPath`
/// - on-disk permissions: DB file 0o600; the store creates its parent
///   directory (if missing) with 0o700
/// - a corrupt DB file is moved aside intact (evidence preserved) and a fresh
///   store is started, reported via `OpenOutcome.recoveredFromCorruption` —
///   never a crash, never a silent reset
/// - an unknown FUTURE user_version is a typed refusal
///   (`StoreError.unsupportedSchemaVersion`), file left untouched — no
///   half-migration
actor FolderIndexStore {

    /// Bump only with a real migration path.
    static let schemaVersion: Int32 = 1

    /// How opening went. Sendable + Equatable so tests and the UI can inspect it.
    enum OpenOutcome: Sendable, Equatable {
        /// No DB existed; schema was created fresh.
        case createdFresh
        /// A healthy existing DB was opened.
        case openedExisting
        /// The existing file was not a usable database; it was moved aside
        /// (byte-for-byte intact, at the associated URL) and a fresh DB was
        /// created in its place.
        case recoveredFromCorruption(corruptFileMovedTo: URL)
    }

    /// Typed store failures.
    enum StoreError: Error, Equatable {
        /// The database could not be opened or its parent dir created.
        case cannotOpen(path: String, detail: String)
        /// A profile with this canonical path is already stored.
        case duplicateFolderPath(canonicalPath: String)
        /// The DB was written by a newer app version; refusing to touch it.
        case unsupportedSchemaVersion(found: Int32, supported: Int32)
        /// A statement failed mid-flight (insert/read).
        case queryFailed(detail: String)
    }

    /// How opening the database at `databaseURL` went; set once by init.
    /// `nonisolated` — an immutable Sendable value, safe to read synchronously.
    nonisolated let openOutcome: OpenOutcome

    /// The single connection this actor owns. nil once `close()` has run.
    private var db: OpaquePointer?

    // Schema DDL. Table and column names are compile-time constants; every
    // value that ever varies at runtime is bound, never interpolated.
    private static let createFoldersTable = """
        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            canonical_path TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            total_file_count INTEGER NOT NULL,
            bookmark BLOB,
            status TEXT NOT NULL DEFAULT 'indexed',
            last_scanned_at REAL
        )
        """
    private static let createVectorsTable = """
        CREATE TABLE IF NOT EXISTS folder_vectors (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            kind TEXT NOT NULL,
            dimension INTEGER NOT NULL,
            embedding BLOB NOT NULL
        )
        """

    /// Opens (creating parent directory, file, and schema as needed).
    /// Never returns a half-open store: any failure throws `StoreError`.
    init(databaseURL: URL) throws {
        let path = databaseURL.path
        try Self.createParentDirectoryIfNeeded(for: databaseURL)

        let existed = FileManager.default.fileExists(atPath: path)
        if !existed {
            try Self.createEmptyDatabaseFile(at: databaseURL)
        }

        do {
            self.db = try Self.openAndPrepare(at: path, isFresh: !existed)
            self.openOutcome = existed ? .openedExisting : .createdFresh
        } catch StoreError.queryFailed where existed {
            // The existing file is not a usable database. Move it aside
            // byte-for-byte (evidence, never deleted) and start fresh.
            let movedTo = try Self.moveCorruptDatabaseAside(at: databaseURL)
            try Self.createEmptyDatabaseFile(at: databaseURL)
            self.db = try Self.openAndPrepare(at: path, isFresh: true)
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

    /// Persists canonicalPath, displayName, totalFileCount, and vectors (as
    /// Float32 BLOBs with their dimension recorded). Returns the new row ID.
    /// Convenience for profile-only callers: no bookmark, status "indexed".
    func insertProfile(_ profile: FolderProfile) throws -> Int64 {
        try insertProfile(profile, bookmark: nil, statusRaw: "indexed", lastScannedAt: nil)
    }

    /// Full insert: profile plus the registry's bookkeeping columns.
    func insertProfile(
        _ profile: FolderProfile,
        bookmark: Data?,
        statusRaw: String,
        lastScannedAt: Date?
    ) throws -> Int64 {
        let db = try openHandle()
        try execute(on: db, "BEGIN IMMEDIATE")
        do {
            let folderID = try insertFolderRow(
                on: db, profile,
                bookmark: bookmark, statusRaw: statusRaw, lastScannedAt: lastScannedAt
            )
            for (position, vector) in profile.vectors.enumerated() {
                try insertVectorRow(on: db, folderID: folderID, position: position, vector: vector)
            }
            try execute(on: db, "COMMIT")
            return folderID
        } catch {
            // Roll back so a failed insert leaves no partial rows. If the
            // rollback itself fails the original error still surfaces.
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Replaces a stored folder's profile after a rescan: display name,
    /// canonical path (a bookmark may have followed a rename), counts,
    /// status, scan time, bookmark, and ALL vectors — atomically.
    func updateProfile(
        id: Int64,
        with profile: FolderProfile,
        bookmark: Data?,
        statusRaw: String,
        lastScannedAt: Date?
    ) throws {
        let db = try openHandle()
        try execute(on: db, "BEGIN IMMEDIATE")
        do {
            try updateFolderRow(
                on: db, id: id, profile: profile,
                bookmark: bookmark, statusRaw: statusRaw, lastScannedAt: lastScannedAt
            )
            try deleteVectorRows(on: db, folderID: id)
            for (position, vector) in profile.vectors.enumerated() {
                try insertVectorRow(on: db, folderID: id, position: position, vector: vector)
            }
            try execute(on: db, "COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Removes a folder row; its vectors go with it (ON DELETE CASCADE).
    /// Deletes only this app's own index row — never anything on disk.
    func removeProfile(id: Int64) throws {
        let db = try openHandle()
        let statement = try prepare(on: db, "DELETE FROM folders WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, id) == SQLITE_OK else {
            throw StoreError.queryFailed(detail: "binding folder delete: \(errorMessage(db))")
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.queryFailed(detail: "deleting folder row: \(errorMessage(db))")
        }
    }

    /// All stored profiles in insertion order (earliest added first) — the
    /// order FolderMatcher's tie-breaking relies on.
    func allProfiles() throws -> [StoredFolderProfile] {
        let db = try openHandle()
        let statement = try prepare(
            on: db,
            """
            SELECT id, canonical_path, display_name, total_file_count,
                   bookmark, status, last_scanned_at
            FROM folders ORDER BY id
            """
        )
        defer { sqlite3_finalize(statement) }

        var profiles: [StoredFolderProfile] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw StoreError.queryFailed(detail: "reading folders: \(errorMessage(db))")
            }
            let id = sqlite3_column_int64(statement, 0)
            let lastScanned: Date?
            if sqlite3_column_type(statement, 6) == SQLITE_NULL {
                lastScanned = nil
            } else {
                lastScanned = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            }
            profiles.append(StoredFolderProfile(
                id: id,
                canonicalPath: columnText(statement, 1),
                displayName: columnText(statement, 2),
                totalFileCount: Int(sqlite3_column_int64(statement, 3)),
                vectors: try vectors(on: db, forFolderID: id),
                bookmark: columnBlob(statement, 4),
                statusRaw: columnText(statement, 5),
                lastScannedAt: lastScanned
            ))
        }
        return profiles
    }

    /// Closes the underlying database handle. Idempotent; the store is
    /// unusable afterwards. Lets tests (and app quit) release the file
    /// deterministically instead of relying on deinit timing.
    func close() {
        if let db {
            sqlite3_close_v2(db)
        }
        db = nil
    }

    // MARK: - Opening

    private static func createParentDirectoryIfNeeded(for databaseURL: URL) throws {
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
    private static func createEmptyDatabaseFile(at databaseURL: URL) throws {
        let created = FileManager.default.createFile(
            atPath: databaseURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw StoreError.cannotOpen(
                path: databaseURL.path, detail: "cannot create database file"
            )
        }
    }

    /// Opens the connection, verifies the schema version, and (for a usable
    /// file) configures the connection and ensures the schema exists.
    /// Throws `queryFailed` when the file is not a database — the corruption
    /// signal init reacts to — and closes the handle on every failure path.
    private static func openAndPrepare(at path: String, isFresh: Bool) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        )
        guard openResult == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            throw StoreError.cannotOpen(path: path, detail: "sqlite open code \(openResult)")
        }

        do {
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
            try executeStatic(on: db, "PRAGMA foreign_keys=ON")
            // macOS's system SQLite is not built with SECURE_DELETE, so deleted
            // rows are left readable in the file's free pages. This database
            // holds folder names, file names, and embeddings derived from the
            // user's file contents — removing a folder from Settings has to
            // actually remove it (M9). Kept in step with `history.db`.
            try executeStatic(on: db, "PRAGMA secure_delete=ON")
            if isFresh || foundVersion < schemaVersion {
                try executeStatic(on: db, createFoldersTable)
                try executeStatic(on: db, createVectorsTable)
                // PRAGMA cannot take a bound parameter; the value is a
                // compile-time constant, not runtime data.
                try executeStatic(on: db, "PRAGMA user_version = \(schemaVersion)")
            }
            return db
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
    }

    private static func readUserVersion(on db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw StoreError.queryFailed(
                detail: "cannot read user_version: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.queryFailed(
                detail: "cannot step user_version: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        return sqlite3_column_int(statement, 0)
    }

    /// Renames the unusable database file (plus any WAL/SHM journals) out of
    /// the way. Rename preserves the bytes exactly — the evidence rule.
    private static func moveCorruptDatabaseAside(at databaseURL: URL) throws -> URL {
        let suffix = ".corrupt-\(UUID().uuidString)"
        let movedTo = URL(fileURLWithPath: databaseURL.path + suffix)
        do {
            try FileManager.default.moveItem(at: databaseURL, to: movedTo)
        } catch {
            throw StoreError.cannotOpen(
                path: databaseURL.path,
                detail: "cannot move corrupt database aside: \(error.localizedDescription)"
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
    private static func executeStatic(on db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(
                detail: "executing statement: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    // MARK: - Statement helpers

    /// The live handle, or a typed error once the store is closed.
    private func openHandle() throws -> OpaquePointer {
        guard let db else {
            throw StoreError.queryFailed(detail: "store is closed")
        }
        return db
    }

    private func execute(on db: OpaquePointer, _ sql: String) throws {
        try Self.executeStatic(on: db, sql)
    }

    private func prepare(on db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw StoreError.queryFailed(detail: "preparing statement: \(errorMessage(db))")
        }
        return statement
    }

    private func errorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, let blob = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: blob, count: byteCount)
    }

    /// Binds a nullable Data value: NULL when nil, a real (possibly empty)
    /// BLOB otherwise. bind_blob with a nil pointer would bind NULL, so an
    /// empty Data goes through bind_zeroblob instead.
    private func bindOptionalBlob(
        _ statement: OpaquePointer, _ index: Int32, _ data: Data?
    ) -> Bool {
        guard let data else {
            return sqlite3_bind_null(statement, index) == SQLITE_OK
        }
        guard !data.isEmpty else {
            return sqlite3_bind_zeroblob(statement, index, 0) == SQLITE_OK
        }
        return data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient
            ) == SQLITE_OK
        }
    }

    /// Binds a nullable Date as seconds since 1970 (REAL), NULL when nil.
    private func bindOptionalDate(
        _ statement: OpaquePointer, _ index: Int32, _ date: Date?
    ) -> Bool {
        guard let date else {
            return sqlite3_bind_null(statement, index) == SQLITE_OK
        }
        return sqlite3_bind_double(statement, index, date.timeIntervalSince1970) == SQLITE_OK
    }

    // MARK: - Insert

    private func insertFolderRow(
        on db: OpaquePointer,
        _ profile: FolderProfile,
        bookmark: Data?,
        statusRaw: String,
        lastScannedAt: Date?
    ) throws -> Int64 {
        let statement = try prepare(
            on: db,
            """
            INSERT INTO folders
                (canonical_path, display_name, total_file_count, bookmark, status, last_scanned_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_text(statement, 1, profile.canonicalPath, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, profile.displayName, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, Int64(profile.totalFileCount)) == SQLITE_OK,
              bindOptionalBlob(statement, 4, bookmark),
              sqlite3_bind_text(statement, 5, statusRaw, -1, sqliteTransient) == SQLITE_OK,
              bindOptionalDate(statement, 6, lastScannedAt) else {
            throw StoreError.queryFailed(detail: "binding folder row: \(errorMessage(db))")
        }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE else {
            if stepResult == SQLITE_CONSTRAINT {
                throw StoreError.duplicateFolderPath(canonicalPath: profile.canonicalPath)
            }
            throw StoreError.queryFailed(detail: "inserting folder row: \(errorMessage(db))")
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func updateFolderRow(
        on db: OpaquePointer,
        id: Int64,
        profile: FolderProfile,
        bookmark: Data?,
        statusRaw: String,
        lastScannedAt: Date?
    ) throws {
        let statement = try prepare(
            on: db,
            """
            UPDATE folders
            SET canonical_path = ?, display_name = ?, total_file_count = ?,
                bookmark = ?, status = ?, last_scanned_at = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_text(statement, 1, profile.canonicalPath, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, profile.displayName, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, Int64(profile.totalFileCount)) == SQLITE_OK,
              bindOptionalBlob(statement, 4, bookmark),
              sqlite3_bind_text(statement, 5, statusRaw, -1, sqliteTransient) == SQLITE_OK,
              bindOptionalDate(statement, 6, lastScannedAt),
              sqlite3_bind_int64(statement, 7, id) == SQLITE_OK else {
            throw StoreError.queryFailed(detail: "binding folder update: \(errorMessage(db))")
        }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE else {
            if stepResult == SQLITE_CONSTRAINT {
                throw StoreError.duplicateFolderPath(canonicalPath: profile.canonicalPath)
            }
            throw StoreError.queryFailed(detail: "updating folder row: \(errorMessage(db))")
        }
    }

    private func deleteVectorRows(on db: OpaquePointer, folderID: Int64) throws {
        let statement = try prepare(on: db, "DELETE FROM folder_vectors WHERE folder_id = ?")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, folderID) == SQLITE_OK else {
            throw StoreError.queryFailed(detail: "binding vector delete: \(errorMessage(db))")
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.queryFailed(detail: "deleting vector rows: \(errorMessage(db))")
        }
    }

    private func insertVectorRow(
        on db: OpaquePointer, folderID: Int64, position: Int, vector: FolderVector
    ) throws {
        let statement = try prepare(
            on: db,
            """
            INSERT INTO folder_vectors (folder_id, position, kind, dimension, embedding)
            VALUES (?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        let bindsSucceeded = vector.values.withUnsafeBufferPointer { buffer -> Bool in
            let blobBound: Bool
            if let baseAddress = buffer.baseAddress {
                blobBound = sqlite3_bind_blob(
                    statement, 5, baseAddress,
                    Int32(buffer.count * MemoryLayout<Float>.stride), sqliteTransient
                ) == SQLITE_OK
            } else {
                // An empty vector still stores an honest zero-length BLOB
                // (bind_blob with a nil pointer would bind NULL instead).
                blobBound = sqlite3_bind_zeroblob(statement, 5, 0) == SQLITE_OK
            }
            return sqlite3_bind_int64(statement, 1, folderID) == SQLITE_OK
                && sqlite3_bind_int64(statement, 2, Int64(position)) == SQLITE_OK
                && sqlite3_bind_text(statement, 3, vector.kind.rawValue, -1, sqliteTransient) == SQLITE_OK
                && sqlite3_bind_int64(statement, 4, Int64(vector.values.count)) == SQLITE_OK
                && blobBound
        }
        guard bindsSucceeded else {
            throw StoreError.queryFailed(detail: "binding vector row: \(errorMessage(db))")
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.queryFailed(detail: "inserting vector row: \(errorMessage(db))")
        }
    }

    // MARK: - Read

    private func vectors(on db: OpaquePointer, forFolderID folderID: Int64) throws -> [FolderVector] {
        let statement = try prepare(
            on: db,
            "SELECT kind, dimension, embedding FROM folder_vectors WHERE folder_id = ? ORDER BY position"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, folderID) == SQLITE_OK else {
            throw StoreError.queryFailed(detail: "binding vector query: \(errorMessage(db))")
        }

        var result: [FolderVector] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw StoreError.queryFailed(detail: "reading vectors: \(errorMessage(db))")
            }
            guard let kind = FolderVectorKind(rawValue: columnText(statement, 0)) else {
                throw StoreError.queryFailed(detail: "unknown vector kind in folder_vectors")
            }
            let dimension = Int(sqlite3_column_int64(statement, 1))
            // A corrupt row could carry a negative or absurd dimension; reject
            // it before it drives the multiply below or a huge allocation.
            // NLEmbedding is 512-d; 100_000 is generous headroom for any future
            // model, and keeps the store's "never crash, typed error" contract.
            guard dimension >= 0, dimension <= 100_000 else {
                throw StoreError.queryFailed(detail: "vector dimension out of range")
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 2))
            guard byteCount == dimension * MemoryLayout<Float>.stride else {
                throw StoreError.queryFailed(
                    detail: "embedding BLOB size does not match its recorded dimension"
                )
            }
            var values = [Float](repeating: 0, count: dimension)
            if byteCount > 0 {
                guard let blob = sqlite3_column_blob(statement, 2) else {
                    throw StoreError.queryFailed(detail: "missing embedding BLOB")
                }
                values.withUnsafeMutableBytes { destination in
                    destination.copyMemory(
                        from: UnsafeRawBufferPointer(start: blob, count: byteCount)
                    )
                }
            }
            result.append(FolderVector(kind: kind, values: values))
        }
        return result
    }
}
