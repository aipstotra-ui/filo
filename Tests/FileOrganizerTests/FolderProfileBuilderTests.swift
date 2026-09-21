import Foundation
import Testing
@testable import FileOrganizer

// MARK: - Mocks (test target only)

/// Deterministic embedder: records every text it is asked to embed and
/// returns a unit 2-vector derived from the text, so identical inputs yield
/// identical vectors and the "no AI, template text only" contract is
/// observable through `requestedTexts`.
private final class MockEmbeddingProvider: EmbeddingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var requestedTexts: [String] {
        lock.withLock { recorded }
    }

    func embedding(for text: String) -> [Float]? {
        lock.withLock { recorded.append(text) }
        let seed = text.unicodeScalars.reduce(UInt32(0)) { ($0 &+ $1.value) % 997 }
        let x = 0.5 + Float(seed) / 2000 // in [0.5, 1)
        let y = max(0, 1 - x * x).squareRoot()
        return [x, y]
    }
}

/// Records which files the builder hands to the extraction seam; succeeds
/// with deterministic text unless the file name is listed in `failures`,
/// in which case it reports a typed metadata-only fallback (the seam's
/// honest failure shape).
private final class MockContentExtractor: ContentExtracting {
    private let lock = NSLock()
    private var recorded: [FileEvent] = []

    /// File names that should fail extraction, with the typed reason.
    var failures: [String: FallbackReason] = [:]

    var requestedFileNames: [String] {
        lock.withLock { recorded.map { $0.url.lastPathComponent } }
    }

    func extract(from event: FileEvent, completion: @escaping (ExtractedContent) -> Void) {
        lock.withLock { recorded.append(event) }
        let name = event.url.lastPathComponent
        if let reason = failures[name] {
            completion(ExtractedContent(
                event: event, snippet: "\(name) metadata",
                method: .metadataOnly(reason), wordCount: 0
            ))
        } else {
            completion(ExtractedContent(
                event: event, snippet: "sample text from \(name)",
                method: .plainText, wordCount: 4
            ))
        }
    }
}

// MARK: - Tests

/// Contract tests for FolderProfileBuilder — the read-only folder scan.
/// A class suite so each test gets a fresh instance with its own temp
/// directory, removed again in deinit (never touches real user folders).
@Suite("FolderProfileBuilder")
final class FolderProfileBuilderTests {

    private let tempDir: URL
    private let embedder = MockEmbeddingProvider()
    private let extractor = MockContentExtractor()

    private var builder: FolderProfileBuilder {
        FolderProfileBuilder(embedder: embedder, extractor: extractor)
    }

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderProfileBuilderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        // Best-effort cleanup of test scratch only; nothing here guards data.
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    /// Creates `tempDir/<name>` containing the given files. Modification
    /// dates are staggered deterministically: later entries are more recent.
    private func makeFolder(named name: String, files: [String]) throws -> URL {
        let folder = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, fileName) in files.enumerated() {
            let url = folder.appendingPathComponent(fileName)
            try Data("contents of \(fileName)".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(index))],
                ofItemAtPath: url.path
            )
        }
        return folder
    }

    /// (path → modification date + size) for the folder and everything in it,
    /// recursively — the read-only-scan detector.
    private func snapshot(of folder: URL) throws -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]
        var paths = [folder.path]
        if let enumerator = fm.enumerator(atPath: folder.path) {
            while let relative = enumerator.nextObject() as? String {
                paths.append((folder.path as NSString).appendingPathComponent(relative))
            }
        }
        for path in paths {
            let attributes = try fm.attributesOfItem(atPath: path)
            let modified = attributes[.modificationDate] as? Date
            let size = attributes[.size] as? Int64
            result[path] = "\(modified?.timeIntervalSince1970 ?? -1)|\(size ?? -1)"
        }
        return result
    }

    private func vectors(ofKind kind: FolderVectorKind, in profile: FolderProfile) -> [FolderVector] {
        profile.vectors.filter { $0.kind == kind }
    }

    // MARK: Deterministic template text

    @Test("Profile texts are deterministic template text built from the folder and file names")
    func profileTextsAreDeterministic() async throws {
        let folder = try makeFolder(named: "Invoices", files: ["acme-march.pdf", "acme-april.pdf"])

        let firstEmbedder = MockEmbeddingProvider()
        let firstProfile = try await FolderProfileBuilder(
            embedder: firstEmbedder, extractor: MockContentExtractor()
        ).buildProfile(for: folder)

        let secondEmbedder = MockEmbeddingProvider()
        let secondProfile = try await FolderProfileBuilder(
            embedder: secondEmbedder, extractor: MockContentExtractor()
        ).buildProfile(for: folder)

        #expect(
            firstEmbedder.requestedTexts == secondEmbedder.requestedTexts,
            "same folder must produce the exact same embedded texts, in the same order"
        )
        #expect(firstProfile == secondProfile)
        #expect(firstEmbedder.requestedTexts.contains { $0.contains("Invoices") })
        #expect(firstEmbedder.requestedTexts.contains { $0.contains("acme-march.pdf") })
        #expect(firstEmbedder.requestedTexts.contains { $0.contains("acme-april.pdf") })
        #expect(firstProfile.displayName == "Invoices")
        #expect(firstProfile.canonicalPath == folder.resolvingSymlinksInPath().path)
    }

    // MARK: Hidden files and subdirectories

    @Test("Hidden files are skipped and subdirectories are not recursed into")
    func skipsHiddenFilesAndSubdirectories() async throws {
        let folder = try makeFolder(
            named: "Mixed",
            files: ["visible.txt", "also.pdf", ".DS_Store", ".hidden"]
        )
        let sub = folder.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: sub.appendingPathComponent("inner.txt"))

        let profile = try await builder.buildProfile(for: folder)

        #expect(Set(profile.sampledFileNames) == ["visible.txt", "also.pdf"])
        #expect(!profile.sampledFileNames.contains(".DS_Store"))
        #expect(!profile.sampledFileNames.contains(".hidden"))
        #expect(!profile.sampledFileNames.contains("inner.txt"))
        #expect(!profile.sampledFileNames.contains("Sub"))
        #expect(
            Set(extractor.requestedFileNames).isSubset(of: ["visible.txt", "also.pdf"]),
            "content sampling must never reach into hidden files or subfolders"
        )
        #expect(
            profile.totalFileCount == 2,
            "the 'N files' status count also skips hidden files and subdirectories"
        )
    }

    // MARK: Filename sample cap

    @Test("Filename sample is capped at 100, preferring the most recent files")
    func filenameSampleCappedAtOneHundredMostRecent() async throws {
        #expect(FolderProfileBuilder.filenameSampleLimit == 100)

        let names = (0..<120).map { String(format: "file%03d.txt", $0) }
        // makeFolder staggers modification dates: higher index = more recent.
        let folder = try makeFolder(named: "Big", files: names)

        let profile = try await builder.buildProfile(for: folder)

        #expect(profile.sampledFileNames.count == 100)
        #expect(profile.sampledFileNames.first == "file119.txt", "most recent first")
        let oldestTwenty = Set(names.prefix(20))
        #expect(
            Set(profile.sampledFileNames).isDisjoint(with: oldestTwenty),
            "the 20 oldest files must be the ones dropped"
        )
        #expect(
            profile.totalFileCount == 120,
            "the 'N files' status count covers the whole folder, not just the 100 sampled names"
        )
    }

    // MARK: Content sampling

    @Test("At most 3 files are handed to the extraction seam, most recent preferred")
    func contentSamplingCappedAtThree() async throws {
        #expect(FolderProfileBuilder.contentSampleLimit == 3)

        let folder = try makeFolder(
            named: "Docs",
            files: ["f1.txt", "f2.txt", "f3.txt", "f4.txt", "f5.txt"]
        )
        let profile = try await builder.buildProfile(for: folder)

        #expect(extractor.requestedFileNames.count == 3)
        #expect(Set(extractor.requestedFileNames) == ["f3.txt", "f4.txt", "f5.txt"])
        #expect(vectors(ofKind: .content, in: profile).count == 3)
        #expect(vectors(ofKind: .name, in: profile).count == 1)
        #expect(vectors(ofKind: .filenames, in: profile).count == 1)
        #expect(profile.contentSampleFailures.isEmpty)
        #expect(profile.totalFileCount == 5)
        #expect(profile.contentReadCount == 3, "status line would read 'Indexed · 5 files, 3 read'")
    }

    @Test("An extraction failure on one sample is recorded typed; the profile still succeeds")
    func extractionFailureOnSampleIsTypedNotFatal() async throws {
        let folder = try makeFolder(
            named: "Docs",
            files: ["f1.txt", "f2.txt", "f3.txt", "f4.txt", "f5.txt"]
        )
        extractor.failures["f4.txt"] = .passwordProtected

        let profile = try await builder.buildProfile(for: folder)

        #expect(
            vectors(ofKind: .content, in: profile).count == 2,
            "a failed sample must never become a fake content vector"
        )
        #expect(profile.contentSampleFailures == [
            ContentSampleFailure(fileName: "f4.txt", reason: .passwordProtected)
        ])
        #expect(vectors(ofKind: .name, in: profile).count == 1)
        #expect(vectors(ofKind: .filenames, in: profile).count == 1)
        #expect(profile.contentReadCount == 2, "a failed sample must not be counted as read")
    }

    // MARK: Empty folder

    @Test("An empty folder yields a valid profile with the name vector only")
    func emptyFolderYieldsNameOnlyProfile() async throws {
        let folder = try makeFolder(named: "Fresh", files: [])

        let profile = try await builder.buildProfile(for: folder)

        #expect(profile.vectors.map(\.kind) == [.name])
        #expect(profile.sampledFileNames.isEmpty)
        #expect(profile.contentSampleFailures.isEmpty)
        #expect(extractor.requestedFileNames.isEmpty)
        #expect(profile.totalFileCount == 0)
        #expect(profile.contentReadCount == 0)
    }

    // MARK: Unreadable directory

    @Test("An unreadable directory throws a typed error, never an empty profile")
    func unreadableDirectoryThrowsTyped() async throws {
        let folder = try makeFolder(named: "Locked", files: ["secret.txt"])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: folder.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: folder.path
            )
        }

        do {
            _ = try await builder.buildProfile(for: folder)
            Issue.record("an unreadable folder must throw, not pretend to be empty")
        } catch let error as FolderProfileError {
            guard case .folderUnreadable(let path) = error else {
                Issue.record("expected .folderUnreadable, got \(error)")
                return
            }
            #expect(path.hasSuffix("Locked"))
        } catch {
            Issue.record("expected FolderProfileError.folderUnreadable, got \(error)")
        }
    }

    // MARK: Read-only guarantee

    @Test("Profiling never writes: folder contents identical before and after")
    func scanIsStrictlyReadOnly() async throws {
        let folder = try makeFolder(named: "Watched", files: ["a.txt", "b.pdf", ".hidden"])
        let sub = folder.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: sub.appendingPathComponent("inner.txt"))

        let before = try snapshot(of: folder)
        _ = try await builder.buildProfile(for: folder)
        let after = try snapshot(of: folder)

        #expect(before == after, "M4 must never create, modify, or move anything in a target folder")
    }
}
