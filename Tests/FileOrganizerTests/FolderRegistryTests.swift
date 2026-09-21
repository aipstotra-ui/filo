import Foundation
import Testing
@testable import FileOrganizer

/// Tests for FolderRegistry's pure validation logic — the gate between the
/// folder picker and the registry. Pure functions, no registry instance and
/// no real folders needed.
@Suite("FolderRegistry validation")
struct FolderRegistryValidationTests {

    private let downloads = URL(fileURLWithPath: "/Users/someone/Downloads")

    @Test("A fresh folder passes and comes back with its canonical path")
    func freshFolderPasses() {
        let result = FolderRegistry.validateCandidate(
            URL(fileURLWithPath: "/Users/someone/Documents/Invoices"),
            existingCanonicalPaths: [],
            downloadsURL: downloads
        )
        #expect(result == .success("/Users/someone/Documents/Invoices"))
    }

    @Test("~/Downloads itself is rejected — the watched source is never a destination")
    func downloadsItselfIsRejected() {
        let result = FolderRegistry.validateCandidate(
            downloads,
            existingCanonicalPaths: [],
            downloadsURL: downloads
        )
        #expect(result == .failure(.isDownloads))
    }

    @Test("An exact duplicate is rejected with its canonical path")
    func duplicateIsRejected() {
        let result = FolderRegistry.validateCandidate(
            URL(fileURLWithPath: "/Users/someone/Documents/Invoices"),
            existingCanonicalPaths: ["/Users/someone/Documents/Invoices"],
            downloadsURL: downloads
        )
        #expect(result == .failure(.duplicate(canonicalPath: "/Users/someone/Documents/Invoices")))
    }

    @Test("A symlink to an already-added folder counts as a duplicate")
    func symlinkedDuplicateIsRejected() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let real = tempDir.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tempDir.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let canonical = FolderRegistry.canonicalPath(for: real)
        let result = FolderRegistry.validateCandidate(
            link,
            existingCanonicalPaths: [canonical],
            downloadsURL: downloads
        )
        #expect(result == .failure(.duplicate(canonicalPath: canonical)))
    }

    @Test("Nested folders are allowed — a subfolder of an added folder is valid")
    func nestedFolderIsAllowed() {
        let result = FolderRegistry.validateCandidate(
            URL(fileURLWithPath: "/Users/someone/Documents/Invoices/2026"),
            existingCanonicalPaths: ["/Users/someone/Documents/Invoices"],
            downloadsURL: downloads
        )
        #expect(result == .success("/Users/someone/Documents/Invoices/2026"))
    }

    @Test("A folder inside Downloads is allowed — only Downloads itself is the source")
    func folderInsideDownloadsIsAllowed() {
        let result = FolderRegistry.validateCandidate(
            URL(fileURLWithPath: "/Users/someone/Downloads/Keep"),
            existingCanonicalPaths: [],
            downloadsURL: downloads
        )
        #expect(result == .success("/Users/someone/Downloads/Keep"))
    }

    @Test("A scan failure maps to missing when the folder is gone, cantAccess when present")
    func scanErrorMapsToHonestStatus() {
        struct AnyError: Error {}
        #expect(
            FolderRegistry.status(forScanError: AnyError(), folderExists: false) == .missing
        )
        #expect(
            FolderRegistry.status(forScanError: AnyError(), folderExists: true) == .cantAccess
        )
    }
}
