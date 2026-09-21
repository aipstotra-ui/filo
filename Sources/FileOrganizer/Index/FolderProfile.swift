import Foundation

/// Which text source a folder-profile embedding came from. Persisted by
/// FolderIndexStore, so the raw values are part of the schema contract.
enum FolderVectorKind: String, Sendable, Equatable {
    /// Embedding of the folder's own name (template text).
    case name
    /// Embedding of the sampled file names (template text).
    case filenames
    /// Embedding of extracted text from one sampled file's contents.
    case content
}

/// One embedding vector inside a folder profile, tagged by its source.
/// Vectors handed to FolderMatcher must be pre-normalized (unit length);
/// the matcher EXCLUDES non-normalized vectors rather than trusting them
/// (pinned in FolderMatcherTests).
struct FolderVector: Sendable, Equatable {
    let kind: FolderVectorKind
    let values: [Float]
}

/// A content sample that could not contribute a vector, with the typed reason.
/// Never replaced by a fake vector; surfaced so the failure is visible.
struct ContentSampleFailure: Sendable, Equatable {
    let fileName: String
    let reason: FallbackReason
}

/// What FolderProfileBuilder produces for one target folder — everything the
/// matcher and store need, plus typed diagnostics. Built entirely on-device;
/// no file is ever moved or written during profiling (read-only scan, pinned
/// in FolderProfileBuilderTests).
struct FolderProfile: Sendable, Equatable {
    /// Symlink-resolved absolute path (`url.resolvingSymlinksInPath().path`).
    /// Unique key in FolderIndexStore.
    let canonicalPath: String
    /// The folder's display name (last path component).
    let displayName: String
    /// Embedding vectors, tagged by kind. Always contains at least the `.name`
    /// vector; `.content` vectors appear only for samples that actually
    /// extracted AND embedded — never fabricated.
    let vectors: [FolderVector]
    /// Non-hidden regular file names sampled from the folder (not recursed),
    /// most recent first, capped at `FolderProfileBuilder.filenameSampleLimit`.
    let sampledFileNames: [String]
    /// Every non-hidden, non-directory file seen in the folder — the "34
    /// files" half of the status line "Indexed · 34 files, 3 read". Counts
    /// the whole folder, not just the sampled names. Persisted by the store.
    let totalFileCount: Int
    /// Content samples that failed extraction, with typed reasons.
    /// Diagnostics only — deliberately not persisted by FolderIndexStore.
    let contentSampleFailures: [ContentSampleFailure]

    /// How many files were successfully content-read — the "3 read" half of
    /// the status line. Derived from the `.content` vectors (one per file
    /// that extracted AND embedded), so it can never drift from the data.
    var contentReadCount: Int {
        vectors.filter { $0.kind == .content }.count
    }
}
