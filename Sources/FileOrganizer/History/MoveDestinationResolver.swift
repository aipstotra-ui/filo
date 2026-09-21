import Foundation

// MARK: - Ports

/// What one registered destination folder looks like right now.
struct LiveDestination: Sendable, Equatable {
    /// The folder's live URL — resolved through its bookmark, so a folder the
    /// user renamed or moved since indexing is still found.
    let url: URL
    /// Its current display name, cross-checked against what the popup showed.
    let displayName: String
}

/// The one question the mover asks the folder index at move time. Declared
/// here (in `History/`) and satisfied by `FolderRegistry` in an extension, so
/// the move path depends on a two-line port rather than the whole registry.
@MainActor
protocol DestinationResolving: AnyObject {
    /// The live URL and display name for a store row id, or nil when no folder
    /// with that id is registered any more.
    func liveDestination(forStoreID storeID: Int64) -> LiveDestination?

    /// Every registered folder's live URL. Together with the watched folder
    /// these are the ONLY directories this app may write into — the bounds both
    /// accept and undo are checked against (M14).
    func registeredFolderURLs() -> [URL]
}

/// What kind of thing is at a path. Follows symlinks (a symlink to a file
/// reads as `.regularFile`) — the mover deliberately moves the link itself.
enum FileKind: Sendable, Equatable {
    case regularFile
    case directory
    case other
}

/// The minimal filesystem questions the resolver asks, behind a port so every
/// failure path (missing / not-a-directory / not-writable, including a macOS
/// TCC denial) is testable without chmod games or a second user account.
protocol FileProbing: Sendable {
    /// nil when nothing exists at `url`.
    func kind(at url: URL) -> FileKind?
    /// True only when `url` is a directory this process may create files in.
    func isWritableDirectory(at url: URL) -> Bool
}

/// Production probe: `FileManager`, nothing else.
struct SystemFileProbe: FileProbing {
    init() {}

    func kind(at url: URL) -> FileKind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return .directory }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? .regularFile : .other
    }

    func isWritableDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }
}

// MARK: - Resolution

/// Where the mover has been cleared to move this file, decided fresh at move
/// time — never trusted from the popup snapshot.
struct ResolvedDestination: Sendable, Equatable {
    /// The source, re-stat'ed and confirmed to be a regular file right now.
    let sourceURL: URL
    /// The directory to move into. Equal to the source's own directory for a
    /// rename in place.
    let directory: URL
    /// The name to try first.
    let preferredName: String
    /// The destination folder's display name, or nil when the file is staying
    /// where it is (either by the user's choice or by fallback).
    let destinationFolderName: String?
    /// Non-nil ONLY when a requested folder was unusable and we fell back to
    /// renaming in place. `nil` for the ordinary "leave it in Downloads" case:
    /// that is the user's intent, not a failure, and must not be reported as
    /// "that folder wasn't available".
    let fallbackReason: MoveFallbackReason?

    var isRenameInPlace: Bool { destinationFolderName == nil }
}

/// Re-validates, at move time, everything the popup captured when it was shown
/// — the file may have moved, and the destination folder may have been removed,
/// renamed, deleted, or replaced by a *different* folder that inherited its
/// row id when the index was rebuilt (SQLite AUTOINCREMENT resets, risk #4).
///
/// Contract pinned by `MoveDestinationResolverTests`:
/// - the source must still exist, still be a regular file, and still be inside
///   the watched folder → otherwise a HARD failure with no fallback (we never
///   invent a move for a file we cannot see, or for a file that is not ours)
/// - the destination folder id is re-resolved live, and its display name must
///   still match what the popup showed
/// - a folder that is GONE or UNUSABLE → fall back to renaming in place,
///   carrying the typed reason (founder decision 2), never a stop-and-ask
/// - a folder that is BLOCKED (permissions, macOS privacy) → honest failure,
///   no move and no rename in place (founder decision 2026-07-28, M24)
/// - the resolved *path* is what gets persisted, never the store id
@MainActor
struct MoveDestinationResolver {

    private let registry: DestinationResolving
    private let probe: FileProbing
    /// The one folder this app watches, and the only place a source file may
    /// come from.
    private let watchedDirectory: URL

    init(
        registry: DestinationResolving,
        watchedDirectory: URL,
        probe: FileProbing = SystemFileProbe()
    ) {
        self.registry = registry
        self.watchedDirectory = watchedDirectory
        self.probe = probe
    }

    /// Resolves one accepted suggestion into a destination the mover may act
    /// on, or fails typed when the source itself is unusable.
    func resolve(_ decision: AcceptedSuggestion) throws(MoveError) -> ResolvedDestination {
        // The source is checked FIRST and always. Falling back to "rename it
        // where it is" for a file that is not there would write a history row
        // for a move that cannot happen.
        try validateSource(decision.sourceURL)
        let sourceDirectory = decision.sourceURL.deletingLastPathComponent()
        // "Watches ~/Downloads only" is a product promise, and a rename in
        // place writes into whatever folder the source is in — so a source from
        // anywhere else is refused rather than acted on (M14).
        guard Self.path(sourceDirectory, isWithin: watchedDirectory) else {
            throw .sourceOutsideWatchedFolder(path: decision.sourceURL.path)
        }

        // No folder chosen: leaving the file in Downloads under a better name
        // is what the user asked for, so it is NOT a fallback.
        guard let folderID = decision.destinationFolderID else {
            return renameInPlace(decision, in: sourceDirectory, because: nil)
        }

        // Resolved ONCE, live: the registry follows the folder's bookmark, so a
        // folder the user renamed or moved since indexing is still found.
        // Founder decision 2: a folder that is gone below falls back to renaming
        // the file where it is and says why, rather than stopping to ask.
        guard let live = registry.liveDestination(forStoreID: folderID) else {
            return renameInPlace(decision, in: sourceDirectory, because: .folderNotRegistered)
        }
        if let reason = try unusableReason(for: live, expectedName: decision.destinationFolderName) {
            return renameInPlace(decision, in: sourceDirectory, because: reason)
        }
        // Last gate before the mover: whatever the registry handed back has to
        // be a folder this app is allowed to write into. Vacuous today — the
        // URL came from the registry — and deliberately kept anyway, because
        // the day a bookmark resolves somewhere unexpected is the day it stops
        // being vacuous.
        guard allowsWriting(into: live.url) else {
            throw .destinationOutsideAllowedFolders(path: live.url.path)
        }
        return ResolvedDestination(
            sourceURL: decision.sourceURL,
            directory: live.url,
            preferredName: decision.chosenFilename,
            destinationFolderName: live.displayName,
            fallbackReason: nil
        )
    }

    // MARK: - Write bounds (M14)

    /// True when this app may write into `directory`: it is the watched folder,
    /// a folder the user registered, or inside one of them.
    ///
    /// The ONE gate, called from both halves of the move path. Accept reaches it
    /// through `resolve`; undo calls it directly, because undo takes its
    /// destination straight from a database column and a database column is not
    /// a promise — an edited (or stale) row would otherwise turn Undo into
    /// "move any readable file into any writable directory".
    ///
    /// Deliberately NOT applied to where a file is moved *from* on undo: a user
    /// who un-registers a folder in Settings must still be able to undo the
    /// moves they already made into it.
    func allowsWriting(into directory: URL) -> Bool {
        let roots = [watchedDirectory] + registry.registeredFolderURLs()
        return roots.contains { Self.path(directory, isWithin: $0) }
    }

    /// Path containment on a COMPONENT boundary, both sides symlink-resolved:
    /// "/Users/me/Downloads-old" is not inside "/Users/me/Downloads", and a
    /// symlinked home does not make the same folder look like two.
    private static func path(_ candidate: URL, isWithin root: URL) -> Bool {
        let candidatePath = FileMover.canonicalDirectoryPath(candidate)
        let rootPath = FileMover.canonicalDirectoryPath(root)
        if candidatePath == rootPath { return true }
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// The file must still be there, and must still be a regular file. Neither
    /// is a fallback case: there is nothing to move.
    private func validateSource(_ sourceURL: URL) throws(MoveError) {
        switch probe.kind(at: sourceURL) {
        case .none:
            throw .sourceMissing(path: sourceURL.path)
        case .regularFile:
            return
        case .directory, .other:
            throw .sourceNotAFile(path: sourceURL.path)
        }
    }

    /// Why this destination folder cannot be used right now, or nil when it is
    /// healthy. Identity is checked before disk: a row id pointing at a
    /// *different* folder is the case where moving the file would put it
    /// somewhere the user never chose (risk #4).
    ///
    /// Returns a fallback reason for a folder that is GONE, and throws for a
    /// folder that is BLOCKED — the two are different things and founder
    /// decision 2026-07-28 (M24) treats them differently. A folder we cannot
    /// write into is not a case for quietly renaming the file in Downloads: the
    /// user chose Invoices, and "it silently stayed in Downloads" is
    /// indistinguishable from the app not working.
    private func unusableReason(
        for live: LiveDestination, expectedName: String?
    ) throws(MoveError) -> MoveFallbackReason? {
        // No name captured means nothing to cross-check the id against, and an
        // unverifiable folder is not one we move a user's file into.
        guard let expectedName, live.displayName == expectedName else {
            return .folderIdentityChanged
        }
        switch probe.kind(at: live.url) {
        case .none:
            return .folderMissing
        case .regularFile, .other:
            return .folderNotADirectory
        case .directory:
            break
        }
        // This catches the POSIX case only. `access(W_OK)` returns TRUE for a
        // directory macOS privacy (TCC) is blocking, so that one cannot be seen
        // from here at all — it arrives as EPERM at write time and the mover
        // turns it into `.destinationBlockedByPrivacy`. Both paths refuse the
        // move; neither renames in place.
        guard probe.isWritableDirectory(at: live.url) else {
            throw .destinationNotWritable(
                path: live.url.path, detail: "the folder's permissions refuse a write"
            )
        }
        return nil
    }

    /// The file keeps its home and takes its new name there. `reason` is nil
    /// for the ordinary "leave it in Downloads" case and non-nil only when a
    /// chosen folder turned out to be unusable.
    private func renameInPlace(
        _ decision: AcceptedSuggestion, in directory: URL, because reason: MoveFallbackReason?
    ) -> ResolvedDestination {
        ResolvedDestination(
            sourceURL: decision.sourceURL,
            directory: directory,
            preferredName: decision.chosenFilename,
            destinationFolderName: nil,
            fallbackReason: reason
        )
    }
}
