import Foundation
import Combine

/// One target folder's live state, driving the Settings row status line.
/// Raw values are persisted in the store's `status` column.
enum FolderStatus: String, Sendable, Equatable {
    /// Profiled and usable for matching ("Indexed · N files, M read").
    case indexed
    /// A scan is running right now ("Scanning…"). Never persisted as-is:
    /// a scan interrupted by quit resumes honestly on next launch.
    case scanning
    /// The folder exists but could not be read ("Can't access — …").
    case cantAccess
    /// The folder is gone ("Folder missing"). Kept in the list, dimmed,
    /// so the user can remove it or rescan after restoring it.
    case missing
}

/// One folder as the registry (and Settings UI) sees it.
struct RegisteredFolder: Identifiable, Equatable {
    /// UI identity — stable across the add → scanned transition, before a
    /// store row ID exists.
    let id: UUID
    /// The store's row ID once the folder is persisted; nil while the very
    /// first scan is still running or if persistence failed.
    var storeID: Int64?
    var url: URL
    var displayName: String
    var status: FolderStatus
    /// Counts behind "Indexed · N files, M read"; zero until first scan.
    var totalFileCount: Int
    var contentReadCount: Int
    /// Unit-length profile vectors for matching; empty unless `.indexed`.
    var vectors: [FolderVector]
    /// Path shown dimmed in the row, home-abbreviated ("~/Documents/…").
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// Why a picked folder was not added. Typed so the UI explains honestly.
/// Conforms to Error so it can ride in `Result` from the validator.
enum FolderAddRejection: Error, Equatable {
    /// Already in the list (compared by symlink-resolved canonical path).
    case duplicate(canonicalPath: String)
    /// ~/Downloads itself — the watched source can't also be a destination.
    case isDownloads
}

/// The list of user-chosen target folders: add (validate → scan → persist),
/// rescan, remove, and per-folder status. Scans run FolderProfileBuilder off
/// the main thread; results land back here. Strictly read-only on target
/// folders — the registry never creates, modifies, or moves anything in them.
@MainActor
final class FolderRegistry: ObservableObject {

    @Published private(set) var folders: [RegisteredFolder] = []

    private let store: FolderIndexStore?
    private let builder: FolderProfileBuilder
    private let downloadsURL: URL

    /// Default on-disk location: ~/Library/Application Support/AI File Organizer/index.db
    static func defaultDatabaseURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("AI File Organizer")
            .appendingPathComponent("index.db")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AI File Organizer/index.db")
    }

    /// `store` nil means "run in-memory for this session" — used when the
    /// database could not be opened (the caller has already surfaced that).
    init(
        store: FolderIndexStore?,
        builder: FolderProfileBuilder = FolderProfileBuilder(),
        downloadsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
    ) {
        self.store = store
        self.builder = builder
        self.downloadsURL = downloadsURL
        Task { await loadPersistedFolders() }
    }

    // MARK: - Pure validation (unit-tested in FolderRegistryTests)

    /// Symlink-resolved absolute path — the registry's identity for a folder.
    nonisolated static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Validates a picked folder against the current list. Pure: no I/O
    /// beyond symlink resolution, no state. Nested folders are allowed —
    /// only an exact duplicate or ~/Downloads itself is rejected.
    nonisolated static func validateCandidate(
        _ url: URL,
        existingCanonicalPaths: Set<String>,
        downloadsURL: URL
    ) -> Result<String, FolderAddRejection> {
        let candidate = canonicalPath(for: url)
        if candidate == canonicalPath(for: downloadsURL) {
            return .failure(.isDownloads)
        }
        if existingCanonicalPaths.contains(candidate) {
            return .failure(.duplicate(canonicalPath: candidate))
        }
        return .success(candidate)
    }

    // MARK: - Add / rescan / remove

    /// Validates and adds a folder, then scans it. Returns the rejection
    /// (for the UI to explain) if the folder was not added.
    @discardableResult
    func addFolder(at url: URL) -> FolderAddRejection? {
        let existing = Set(folders.map { Self.canonicalPath(for: $0.url) })
        switch Self.validateCandidate(
            url, existingCanonicalPaths: existing, downloadsURL: downloadsURL
        ) {
        case .failure(let rejection):
            return rejection
        case .success:
            let folder = RegisteredFolder(
                id: UUID(),
                storeID: nil,
                url: url,
                displayName: url.lastPathComponent,
                status: .scanning,
                totalFileCount: 0,
                contentReadCount: 0,
                vectors: []
            )
            folders.append(folder)
            Task { await scan(folderID: folder.id) }
            return nil
        }
    }

    func rescan(folderID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        guard folders[index].status != .scanning else { return }
        folders[index].status = .scanning
        Task { await scan(folderID: folderID) }
    }

    func remove(folderID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let removed = folders.remove(at: index)
        guard let storeID = removed.storeID, let store else { return }
        Task {
            do {
                try await store.removeProfile(id: storeID)
            } catch {
                devLog("could not remove folder row from index store: \(error)")
            }
        }
    }

    // MARK: - Matching input

    /// Candidates for FolderMatcher, in added (store) order — ONLY folders in
    /// `.indexed` state; missing or inaccessible folders never match. A folder
    /// whose persistence failed (no store ID) cannot be referenced by ID, so
    /// it sits out until a later rescan persists it.
    var matchCandidates: [FolderMatchCandidate] {
        folders.compactMap { folder in
            guard folder.status == .indexed, let storeID = folder.storeID else { return nil }
            return FolderMatchCandidate(folderID: storeID, vectors: folder.vectors)
        }
    }

    /// Display name for a matched candidate's store ID.
    func displayName(forStoreID storeID: Int64) -> String? {
        folders.first { $0.storeID == storeID }?.displayName
    }

    // MARK: - Scanning

    private func scan(folderID: UUID) async {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let url = folders[index].url
        let builder = self.builder

        // FolderProfileBuilder is not main-actor-bound, so its async scan
        // (directory listing, extraction, embedding) runs off the main actor.
        let outcome: Result<FolderProfile, Error>
        do {
            outcome = .success(try await builder.buildProfile(for: url))
        } catch {
            outcome = .failure(error)
        }

        // Re-find the row: it may have moved or been removed mid-scan.
        guard let landing = folders.firstIndex(where: { $0.id == folderID }) else { return }

        switch outcome {
        case .success(let profile):
            folders[landing].displayName = profile.displayName
            folders[landing].status = .indexed
            folders[landing].totalFileCount = profile.totalFileCount
            folders[landing].contentReadCount = profile.contentReadCount
            folders[landing].vectors = profile.vectors
            await persistScanResult(profile: profile, folderID: folderID)
        case .failure(let error):
            let status = Self.status(forScanError: error, folderExists:
                FileManager.default.fileExists(atPath: url.path))
            folders[landing].status = status
            folders[landing].vectors = []
            await persistScanFailure(url: url, status: status, folderID: folderID)
        }
    }

    /// Maps a scan error to the honest row status — never a fake "Indexed".
    nonisolated static func status(forScanError error: Error, folderExists: Bool) -> FolderStatus {
        guard folderExists else { return .missing }
        return .cantAccess
    }

    private func persistScanResult(profile: FolderProfile, folderID: UUID) async {
        guard let store else { return }
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let bookmark = makeBookmark(for: folders[index].url)
        do {
            if let storeID = folders[index].storeID {
                try await store.updateProfile(
                    id: storeID, with: profile, bookmark: bookmark,
                    statusRaw: FolderStatus.indexed.rawValue, lastScannedAt: Date()
                )
            } else {
                let storeID = try await store.insertProfile(
                    profile, bookmark: bookmark,
                    statusRaw: FolderStatus.indexed.rawValue, lastScannedAt: Date()
                )
                await linkOrReclaim(storeID: storeID, folderID: folderID)
            }
        } catch {
            devLog("could not persist folder profile: \(error)")
        }
    }

    /// Attaches a freshly-inserted row's ID to its in-memory folder — or, if the
    /// folder was removed during the insert `await`, deletes the now-orphaned
    /// row. Without this a folder removed mid-first-scan leaves a row nothing
    /// references, which resurrects (and starts matching again) on next launch.
    private func linkOrReclaim(storeID: Int64, folderID: UUID) async {
        if let landing = folders.firstIndex(where: { $0.id == folderID }) {
            folders[landing].storeID = storeID
        } else if let store {
            do {
                try await store.removeProfile(id: storeID)
            } catch {
                devLog("could not reclaim orphaned folder row \(storeID): \(error)")
            }
        }
    }

    /// A folder that failed its scan is persisted too (with its honest
    /// status), so it survives relaunch and stays visible in Settings.
    private func persistScanFailure(url: URL, status: FolderStatus, folderID: UUID) async {
        guard let store else { return }
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let bare = FolderProfile(
            canonicalPath: Self.canonicalPath(for: url),
            displayName: url.lastPathComponent,
            vectors: [],
            sampledFileNames: [],
            totalFileCount: 0,
            contentSampleFailures: []
        )
        let bookmark = makeBookmark(for: url)
        do {
            if let storeID = folders[index].storeID {
                try await store.updateProfile(
                    id: storeID, with: bare, bookmark: bookmark,
                    statusRaw: status.rawValue, lastScannedAt: nil
                )
            } else {
                let storeID = try await store.insertProfile(
                    bare, bookmark: bookmark,
                    statusRaw: status.rawValue, lastScannedAt: nil
                )
                await linkOrReclaim(storeID: storeID, folderID: folderID)
            }
        } catch {
            devLog("could not persist folder status: \(error)")
        }
    }

    // MARK: - Launch load

    private func loadPersistedFolders() async {
        guard let store else { return }
        let stored: [StoredFolderProfile]
        do {
            stored = try await store.allProfiles()
        } catch {
            devLog("could not load folder index: \(error)")
            return
        }
        for row in stored {
            let resolved = resolveURL(for: row)
            let status = liveStatus(for: row, at: resolved)
            let folder = RegisteredFolder(
                id: UUID(),
                storeID: row.id,
                url: resolved,
                displayName: row.displayName,
                status: status,
                totalFileCount: row.totalFileCount,
                contentReadCount: status == .indexed
                    ? row.vectors.filter { $0.kind == .content }.count : 0,
                vectors: status == .indexed ? row.vectors : []
            )
            folders.append(folder)
            // A readable folder that is not indexed (scan interrupted by
            // quit, or a previous failure now resolved) rescans itself —
            // there is no "waiting" row state, and honesty beats staleness.
            if status == .scanning {
                Task { await scan(folderID: folder.id) }
            }
        }
    }

    /// Follows the stored bookmark (folders survive rename/move); falls back
    /// to the stored path when there is no bookmark OR it no longer resolves.
    /// Never returns nil: a genuinely-gone folder is caught by `liveStatus`'s
    /// existence check, not by pretending the path is unknown — a present
    /// folder with a broken bookmark must not be mislabeled "missing".
    private func resolveURL(for row: StoredFolderProfile) -> URL {
        let storedPath = URL(fileURLWithPath: row.canonicalPath)
        guard let bookmark = row.bookmark else { return storedPath }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return storedPath
        }
        return resolved
    }

    /// Re-derives a row's live status at launch: the disk is the truth, the
    /// persisted status only a hint. A previously indexed folder keeps its
    /// counts and vectors as long as it is still present and readable; a
    /// readable folder in any other persisted state (failed or interrupted
    /// scan, unknown future value) comes back as `.scanning` and the caller
    /// starts a real rescan for it.
    private func liveStatus(for row: StoredFolderProfile, at url: URL) -> FolderStatus {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missing
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .cantAccess
        }
        return FolderStatus(rawValue: row.statusRaw) == .indexed ? .indexed : .scanning
    }

    private func makeBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil
            )
        } catch {
            devLog("could not create folder bookmark: \(error)")
            return nil
        }
    }

    /// Dev-build diagnostics, control-character-sanitized (LogSanitizer
    /// discipline — same as Watcher/Extraction). Never file contents; typed
    /// error descriptions may carry a folder path, which is dev-build-only
    /// per docs/process/engineering-rules.md and gated out here for release.
    private func devLog(_ message: String) {
        #if DEBUG
        print("FolderRegistry: \(LogSanitizer.sanitized(message))")
        #endif
    }
}

// MARK: - Destination lookup for the mover

/// The registry answering the one question [[History-Undo]]'s move path asks:
/// where is this folder RIGHT NOW, and what is it called? Read-only, and no
/// behaviour change — `url` is already bookmark-resolved at launch, so a folder
/// the user renamed or moved is still found.
extension FolderRegistry: DestinationResolving {
    func liveDestination(forStoreID storeID: Int64) -> LiveDestination? {
        guard let folder = folders.first(where: { $0.storeID == storeID }) else { return nil }
        return LiveDestination(url: folder.url, displayName: folder.displayName)
    }

    /// Every folder the user registered. With the watched folder, this is the
    /// complete set of places the move path may write into — the bounds both
    /// accept and undo are checked against (M14).
    func registeredFolderURLs() -> [URL] {
        folders.map(\.url)
    }
}
