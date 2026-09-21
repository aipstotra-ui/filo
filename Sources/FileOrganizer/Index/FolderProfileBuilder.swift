import Foundation

/// Typed failures when profiling a folder. Never masked as an empty profile:
/// an unreadable folder throws, it does not pretend to be empty (pinned in
/// FolderProfileBuilderTests).
enum FolderProfileError: Error, Equatable {
    /// The directory could not be listed (missing permission, vanished, …).
    case folderUnreadable(path: String)
    /// The URL exists but is not a directory.
    case notADirectory(path: String)
    /// The on-device embedding model produced no vector for the folder's
    /// name text, so no usable profile can exist for it.
    case embeddingUnavailable(path: String)
}

/// Builds a FolderProfile from a real directory: folder name + sampled file
/// names + content extracted from up to `contentSampleLimit` sample files via
/// the existing extraction seam. Strictly read-only on the target folder —
/// M4 never moves or writes anything (founder decision, pinned in tests).
/// All template texts are deterministic; no generative AI call is involved
/// (the API deliberately takes no AIProviding).
struct FolderProfileBuilder {

    /// At most this many file names go into the filenames sample
    /// (most recent first). Founder-pinned at 100.
    static let filenameSampleLimit = 100

    /// At most this many files are handed to the extraction seam for content
    /// sampling. Founder-pinned at 3.
    static let contentSampleLimit = 3

    let embedder: EmbeddingProviding
    let extractor: ContentExtracting
    let fileManager: FileManager

    init(
        embedder: EmbeddingProviding = SentenceEmbeddingProvider(),
        extractor: ContentExtracting = ExtractionEngine(),
        fileManager: FileManager = .default
    ) {
        self.embedder = embedder
        self.extractor = extractor
        self.fileManager = fileManager
    }

    /// One listed file, with the metadata the sampler sorts and reads by.
    private struct ScannedFile {
        let url: URL
        let name: String
        let modified: Date
        let size: Int64
    }

    /// Scans `folderURL` (top level only; hidden files skipped, subdirectories
    /// not recursed into) and returns its profile.
    ///
    /// Contract pinned by FolderProfileBuilderTests:
    /// - `canonicalPath` == `folderURL.resolvingSymlinksInPath().path`
    /// - empty folder → valid profile with the `.name` vector only
    /// - an extraction failure on a sample file records a typed
    ///   `ContentSampleFailure` and continues — never a fake content vector,
    ///   never a thrown-away folder
    /// - unreadable directory → throws `FolderProfileError`, never an empty
    ///   profile pretending success
    /// - the scan never mutates the folder (names + modification dates
    ///   identical before/after)
    func buildProfile(for folderURL: URL) async throws -> FolderProfile {
        let canonicalPath = folderURL.resolvingSymlinksInPath().path
        let displayName = folderURL.lastPathComponent

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalPath, isDirectory: &isDirectory) else {
            throw FolderProfileError.folderUnreadable(path: canonicalPath)
        }
        guard isDirectory.boolValue else {
            throw FolderProfileError.notADirectory(path: canonicalPath)
        }

        let files = try scanFiles(inFolderAt: canonicalPath)

        var vectors: [FolderVector] = []
        var failures: [ContentSampleFailure] = []

        // The .name vector is the profile's floor: without it there is
        // nothing to match against, so its absence is a typed error.
        guard let nameVector = unitEmbedding(for: "Folder name: \(displayName)") else {
            throw FolderProfileError.embeddingUnavailable(path: canonicalPath)
        }
        vectors.append(FolderVector(kind: .name, values: nameVector))

        let sampledNames = files.prefix(Self.filenameSampleLimit).map(\.name)
        if !sampledNames.isEmpty {
            let filenamesText = "Files in this folder: "
                + sampledNames.joined(separator: ", ")
            if let filenamesVector = unitEmbedding(for: filenamesText) {
                vectors.append(FolderVector(kind: .filenames, values: filenamesVector))
            }
        }

        for file in files.prefix(Self.contentSampleLimit) {
            let extracted = await extractContent(of: file)
            if case .metadataOnly(let reason) = extracted.method {
                failures.append(ContentSampleFailure(fileName: file.name, reason: reason))
            } else if let contentVector = unitEmbedding(for: extracted.snippet) {
                vectors.append(FolderVector(kind: .content, values: contentVector))
            } else {
                // Extracted fine, but the snippet carried no embeddable text
                // signal — recorded, never silently dropped.
                failures.append(ContentSampleFailure(fileName: file.name, reason: .noReadableText))
            }
        }

        return FolderProfile(
            canonicalPath: canonicalPath,
            displayName: displayName,
            vectors: vectors,
            sampledFileNames: Array(sampledNames),
            totalFileCount: files.count,
            contentSampleFailures: failures
        )
    }

    /// Lists the folder's non-hidden, non-directory entries with their
    /// metadata, most recently modified first (name as a deterministic
    /// tie-breaker). Read-only: listing and attribute reads mutate nothing.
    private func scanFiles(inFolderAt path: String) throws -> [ScannedFile] {
        let entryNames: [String]
        do {
            entryNames = try fileManager.contentsOfDirectory(atPath: path)
        } catch {
            throw FolderProfileError.folderUnreadable(path: path)
        }

        var files: [ScannedFile] = []
        for name in entryNames where !name.hasPrefix(".") {
            let entryPath = (path as NSString).appendingPathComponent(name)
            // An entry that vanishes or is unreadable mid-scan is skipped;
            // the folder itself was readable, so profiling continues.
            guard let attributes = try? fileManager.attributesOfItem(atPath: entryPath),
                  let type = attributes[.type] as? FileAttributeType,
                  type != .typeDirectory else {
                continue
            }
            files.append(ScannedFile(
                url: URL(fileURLWithPath: entryPath),
                name: name,
                modified: attributes[.modificationDate] as? Date ?? .distantPast,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0
            ))
        }
        return files.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.name < $1.name
        }
    }

    /// Bridges the extraction seam's completion callback into async.
    private func extractContent(of file: ScannedFile) async -> ExtractedContent {
        let event = FileEvent(url: file.url, size: file.size, detectedAt: file.modified)
        return await withCheckedContinuation { continuation in
            extractor.extract(from: event) { extracted in
                continuation.resume(returning: extracted)
            }
        }
    }

    /// Embeds text and normalizes the result to unit length — done ONCE here
    /// at build time, because FolderMatcher excludes (never renormalizes)
    /// non-unit vectors. Returns nil when no usable vector exists.
    private func unitEmbedding(for text: String) -> [Float]? {
        guard let raw = embedder.embedding(for: text) else { return nil }
        return FolderMatcher.unitNormalized(raw)
    }
}
