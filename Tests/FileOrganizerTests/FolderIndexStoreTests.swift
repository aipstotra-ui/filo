import Foundation
import SQLite3
import Testing
@testable import FileOrganizer

/// Raw SQLite access for black-box verification — the tests inspect the DB
/// file with the same C API the store uses, never through the store itself.
private enum RawSQLite {
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

/// Contract tests for FolderIndexStore — the SQLite persistence actor.
/// A class suite so each test gets a fresh temp directory, removed in deinit.
@Suite("FolderIndexStore")
final class FolderIndexStoreTests {

    private let tempDir: URL
    /// Inside a store-owned subdirectory that must NOT pre-exist: the store
    /// creates it (with tight permissions) on first open.
    private let databaseURL: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderIndexStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir
            .appendingPathComponent("container")
            .appendingPathComponent("index.db")
    }

    deinit {
        // Best-effort cleanup of test scratch only; nothing here guards data.
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    private func sampleProfile(
        path: String = "/Users/someone/Documents/Invoices",
        name: String = "Invoices",
        vectors: [FolderVector] = [
            FolderVector(kind: .name, values: [0.6, 0.8]),
            FolderVector(kind: .filenames, values: [0.1, -0.25, Float.pi, 1e-7]),
            FolderVector(kind: .content, values: [0.3, 0.3, -0.9, 0.1]),
        ],
        totalFileCount: Int = 34
    ) -> FolderProfile {
        FolderProfile(
            canonicalPath: path,
            displayName: name,
            vectors: vectors,
            sampledFileNames: [],
            totalFileCount: totalFileCount,
            contentSampleFailures: []
        )
    }

    private func posixPermissions(atPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: Schema creation

    @Test("First open creates the schema and stamps PRAGMA user_version")
    func firstOpenCreatesSchemaAndVersion() async throws {
        #expect(FolderIndexStore.schemaVersion >= 1)

        let store = try FolderIndexStore(databaseURL: databaseURL)
        #expect(store.openOutcome == .createdFresh)
        await store.close()

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        let version = try RawSQLite.queryInt64s("PRAGMA user_version", at: databaseURL)
        #expect(version == [Int64(FolderIndexStore.schemaVersion)])

        let reopened = try FolderIndexStore(databaseURL: databaseURL)
        #expect(reopened.openOutcome == .openedExisting)
        await reopened.close()
    }

    // MARK: Round trip

    @Test("Profiles and Float32 embedding BLOBs round-trip byte-identical, in insertion order")
    func profilesRoundTripByteIdentical() async throws {
        let store = try FolderIndexStore(databaseURL: databaseURL)
        let first = sampleProfile()
        let second = sampleProfile(path: "/Users/someone/Documents/Taxes", name: "Taxes")

        let firstID = try await store.insertProfile(first)
        let secondID = try await store.insertProfile(second)
        #expect(firstID != secondID)

        let stored = try await store.allProfiles()
        try #require(stored.count == 2)
        #expect(stored[0].id == firstID, "allProfiles must return insertion order, earliest first")
        #expect(stored[1].id == secondID)
        #expect(stored[0].canonicalPath == first.canonicalPath)
        #expect(stored[0].displayName == first.displayName)
        #expect(stored[0].vectors == first.vectors, "values, kinds, and order all preserved")
        #expect(stored[1].vectors == second.vectors)
        #expect(
            stored[0].totalFileCount == first.totalFileCount,
            "the 'N files' half of the status line must survive the round trip"
        )
        #expect(
            stored[0].contentReadCount == first.contentReadCount,
            "the 'N read' half is derived from the persisted .content vectors"
        )

        // Byte-level check on one vector: what went in is bit-for-bit what
        // comes out (no lossy Float→Double→Float or truncated BLOB).
        let sentBytes = first.vectors[1].values.withUnsafeBufferPointer { Data(buffer: $0) }
        let returnedBytes = stored[0].vectors[1].values.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(sentBytes == returnedBytes)

        await store.close()

        // Dimension is recorded in the schema next to each BLOB.
        let dimensions = try RawSQLite.queryInt64s(
            "SELECT dimension FROM folder_vectors ORDER BY dimension", at: databaseURL
        )
        #expect(dimensions == [2, 2, 4, 4, 4, 4])
    }

    // MARK: Unique canonical path

    @Test("Inserting the same canonical path twice fails typed, store stays usable")
    func duplicateCanonicalPathFailsTyped() async throws {
        let store = try FolderIndexStore(databaseURL: databaseURL)
        let profile = sampleProfile()
        _ = try await store.insertProfile(profile)

        let duplicate = sampleProfile(name: "Different Display Name")
        await #expect(throws: FolderIndexStore.StoreError.duplicateFolderPath(
            canonicalPath: profile.canonicalPath
        )) {
            _ = try await store.insertProfile(duplicate)
        }

        let stored = try await store.allProfiles()
        #expect(stored.count == 1, "the failed insert must not corrupt or duplicate anything")
        await store.close()
    }

    // MARK: Permissions

    @Test("DB file is created 0o600 inside a 0o700 store-owned directory")
    func filePermissionsAreTight() async throws {
        let store = try FolderIndexStore(databaseURL: databaseURL)
        await store.close()

        #expect(try posixPermissions(atPath: databaseURL.path) == 0o600)
        let parent = databaseURL.deletingLastPathComponent()
        #expect(try posixPermissions(atPath: parent.path) == 0o700)
    }

    // MARK: Corruption recovery

    @Test("A corrupt DB file is moved aside intact and a fresh store starts")
    func corruptDatabaseRecoversWithEvidence() async throws {
        let original = try FolderIndexStore(databaseURL: databaseURL)
        _ = try await original.insertProfile(sampleProfile())
        await original.close()

        let garbage = Data(repeating: 0x5A, count: 1024) // not a SQLite header
        try garbage.write(to: databaseURL)

        let recovered = try FolderIndexStore(databaseURL: databaseURL)
        guard case .recoveredFromCorruption(let movedTo) = recovered.openOutcome else {
            Issue.record("expected .recoveredFromCorruption, got \(recovered.openOutcome)")
            return
        }
        #expect(movedTo != databaseURL)
        #expect(FileManager.default.fileExists(atPath: movedTo.path))
        #expect(
            try Data(contentsOf: movedTo) == garbage,
            "the corrupt file is evidence — it must be preserved byte-for-byte, not deleted"
        )

        // The fresh store must be fully functional.
        _ = try await recovered.insertProfile(sampleProfile())
        let stored = try await recovered.allProfiles()
        #expect(stored.count == 1)
        await recovered.close()

        let version = try RawSQLite.queryInt64s("PRAGMA user_version", at: databaseURL)
        #expect(version == [Int64(FolderIndexStore.schemaVersion)])
    }

    // MARK: Future schema version

    @Test("An unknown future user_version is refused typed, file left untouched")
    func futureSchemaVersionRefusedTyped() async throws {
        let store = try FolderIndexStore(databaseURL: databaseURL)
        await store.close()
        try RawSQLite.execute("PRAGMA user_version = 9999", at: databaseURL)

        #expect(throws: FolderIndexStore.StoreError.unsupportedSchemaVersion(
            found: 9999, supported: FolderIndexStore.schemaVersion
        )) {
            _ = try FolderIndexStore(databaseURL: self.databaseURL)
        }

        // No half-migration, no move-aside: the newer app's data is intact.
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        let version = try RawSQLite.queryInt64s("PRAGMA user_version", at: databaseURL)
        #expect(version == [9999])
    }
}
