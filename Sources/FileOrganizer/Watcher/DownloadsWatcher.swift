import Foundation
import Combine

/// Watches a folder and announces new files only once they are fully written.
///
/// Browsers write a download over many seconds (often via a `.crdownload` /
/// `.download` partial that is renamed when complete), so a file is only
/// announced after its size has stopped changing for two consecutive
/// one-second checks.
final class DownloadsWatcher: ObservableObject {
    @Published private(set) var recentEvents: [FileEvent] = []
    @Published private(set) var statusMessage = "Starting…"

    /// Pipeline hook: called on the main queue with each newly announced file.
    var onNewFile: ((FileEvent) -> Void)?

    /// The folder being watched. Read by `App.swift` so the mover's write-bounds
    /// gate and the watcher agree on exactly one directory.
    let folderURL: URL
    private let maxRecentEvents = 20
    private let stabilityChecksRequired = 2
    private let partialExtensions: Set<String> = ["crdownload", "download", "part", "tmp"]

    private var directoryDescriptor: CInt = -1
    private var directorySource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?

    /// Files already announced or present when watching began.
    private var knownNames: Set<String> = []
    /// Newcomers waiting to become stable: name -> (last seen size, consecutive unchanged checks).
    private var pending: [String: (size: Int64, stableChecks: Int)] = [:]

    /// Names the app itself is about to create in this folder — a rename-in-place,
    /// or an undo restoring a file to Downloads. This watcher diffs by NAME, so
    /// without a claim the app's own output looks like a brand-new download and
    /// gets a suggestion made for it.
    ///
    /// A claim cannot simply go into `knownNames`: every scan runs
    /// `knownNames.formIntersection(currentNames)`, which would drop the name
    /// again before the file exists. It also cannot live in a plain dictionary
    /// here, because the mover registers claims from a background task while
    /// this class runs on the main queue — see `AppCreatedFileClaims` (M7).
    let appCreatedClaims: AppCreatedFileClaims

    /// Watches ~/Downloads, unless FILE_ORGANIZER_WATCH_DIR is set (used by QA to
    /// point the app at a sandbox folder instead of the real Downloads).
    ///
    /// **Dev builds only.** In a release build the override is ignored entirely:
    /// `launchctl setenv` needs no admin rights and raises no TCC prompt, so an
    /// honoured override would silently repoint the app at any folder — which,
    /// once M6's mover is wired, is a folder the app *writes* to. "Watches
    /// ~/Downloads only" is a product promise, so release builds have no way to
    /// change it. Even in dev the path must resolve inside the user's home, so
    /// a stray value can't aim the watcher at a system directory.
    static func defaultFolder() -> URL {
        // `.first ?? home/Downloads`, never `[0]`: an empty result traps, and a
        // menu-bar app that crashes on launch tells the user nothing (X7).
        // `MoveHistoryStore.defaultDatabaseURL()` already does it this way.
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
        #if DEBUG
        guard let override = ProcessInfo.processInfo.environment["FILE_ORGANIZER_WATCH_DIR"] else {
            return downloads
        }
        let candidate = URL(fileURLWithPath: override, isDirectory: true)
        guard isInsideHome(candidate) else {
            devLogStatic("ignoring FILE_ORGANIZER_WATCH_DIR — outside the home directory")
            return downloads
        }
        return candidate
        #else
        return downloads
        #endif
    }

    /// True when `url` resolves to the home directory or something beneath it.
    /// Compares on resolved paths at a component boundary, so `/Users/aiden` is
    /// not treated as inside `/Users/ai`.
    static func isInsideHome(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        if candidate == home { return true }
        return candidate.hasPrefix(home.hasSuffix("/") ? home : home + "/")
    }

    private static func devLogStatic(_ message: String) {
        #if DEBUG
        print("DownloadsWatcher: \(LogSanitizer.sanitized(message))")
        fflush(stdout)
        #endif
    }

    init(folderURL: URL = DownloadsWatcher.defaultFolder()) {
        self.folderURL = folderURL
        self.appCreatedClaims = AppCreatedFileClaims(watching: folderURL)
        start()
    }

    deinit {
        directorySource?.cancel()
        pollTimer?.invalidate()
    }

    // MARK: - Setup

    private func start() {
        guard let initial = listFolder() else {
            statusMessage = "Can't read \(folderURL.lastPathComponent) — check folder permissions"
            return
        }
        knownNames = Set(initial.keys)

        directoryDescriptor = open(folderURL.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            statusMessage = "Can't watch \(folderURL.lastPathComponent) — check folder permissions"
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scanForNewcomers()
        }
        source.setCancelHandler { [descriptor = directoryDescriptor] in
            close(descriptor)
        }
        source.resume()
        directorySource = source
        statusMessage = "Watching \(folderURL.lastPathComponent)"
        devLog("watching: \(folderURL.path)")
    }

    // MARK: - Detection

    /// Returns visible regular files in the folder as name -> size, or nil if unreadable.
    private func listFolder() -> [String: Int64]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var result: [String: Int64] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            // A file whose size can't be read is skipped, never treated as 0 bytes —
            // otherwise a transient read failure would count as "stable at 0" and
            // announce a still-downloading file.
            guard let size = values?.fileSize else { continue }
            result[url.lastPathComponent] = Int64(size)
        }
        return result
    }

    /// Dev-build-only diagnostics. Filenames and folder paths are user-private
    /// AND attacker-influenced (a download can be named anything), so every
    /// message is sanitized and the whole path compiles out of release builds —
    /// `swift build -c release` does not define DEBUG. Never file contents.
    private func devLog(_ message: String) {
        #if DEBUG
        print("DownloadsWatcher: \(LogSanitizer.sanitized(message))")
        fflush(stdout)
        #endif
    }

    /// Called on every folder change: diff against known files, queue newcomers.
    private func scanForNewcomers() {
        guard let current = listFolder() else {
            handleFolderUnreadable()
            return
        }
        let currentNames = Set(current.keys)

        // Forget files that were removed, so a re-download of the same name is detected again.
        knownNames.formIntersection(currentNames)

        // Adopt any claimed name that has now appeared — from here it is an
        // ordinary known file, and the intersection above will keep it. The
        // claim is spent in the same pass, so it can never shadow a later
        // download of the same name.
        knownNames.formUnion(appCreatedClaims.consumeAppeared(presentNames: currentNames))
        for gone in pending.keys where !currentNames.contains(gone) {
            pending.removeValue(forKey: gone)
        }

        for (name, size) in current {
            guard !knownNames.contains(name), pending[name] == nil else { continue }
            if isPartialDownload(name) {
                // Deliberately left out of knownNames: when the browser renames the
                // partial to its final name, that name then diffs in as a new file.
                continue
            }
            pending[name] = (size: size, stableChecks: 0)
        }

        updatePollTimer()
    }

    private func isPartialDownload(_ name: String) -> Bool {
        partialExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: - Stability debounce

    private func updatePollTimer() {
        if pending.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkPendingFiles()
            }
            // .common mode: keep firing while the menu-bar menu is open (menu
            // tracking pauses .default-mode timers — the file would never appear
            // at the exact moment the user is watching for it).
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    private func checkPendingFiles() {
        guard let current = listFolder() else {
            handleFolderUnreadable()
            return
        }

        for (name, state) in pending {
            guard let sizeNow = current[name] else {
                pending.removeValue(forKey: name)  // vanished mid-download
                continue
            }
            if sizeNow == state.size {
                let checks = state.stableChecks + 1
                if checks >= stabilityChecksRequired {
                    pending.removeValue(forKey: name)
                    announce(name: name, size: sizeNow)
                } else {
                    pending[name] = (size: sizeNow, stableChecks: checks)
                }
            } else {
                pending[name] = (size: sizeNow, stableChecks: 0)  // still growing
            }
        }

        updatePollTimer()
    }

    /// The watched folder was deleted, renamed, or became unreadable:
    /// stop polling and say so instead of spinning against a dead descriptor.
    private func handleFolderUnreadable() {
        pending.removeAll()
        updatePollTimer()
        directorySource?.cancel()
        directorySource = nil
        statusMessage = "Lost access to \(folderURL.lastPathComponent) — restart the app"
    }

    /// Drops a file from the dropdown once the app has moved it out of the
    /// watched folder.
    ///
    /// The list is "recently detected downloads", and a file that has been filed
    /// away is no longer one. Left in, it appeared twice — once here and once in
    /// the history — and its row still offered to reopen a suggestion for a file
    /// that is no longer at that path (D6).
    ///
    /// Only ever called for a move this app itself performed and recorded; a
    /// file the *user* moves is left alone, because the watcher does not police
    /// the folder, it reports on it.
    func forget(fileEventID: UUID) {
        guard let index = recentEvents.firstIndex(where: { $0.id == fileEventID }) else { return }
        let gone = recentEvents.remove(at: index)
        // Out of `knownNames` too, so re-downloading the same name is detected
        // as the new file it is.
        knownNames.remove(gone.name)
    }

    private func announce(name: String, size: Int64) {
        knownNames.insert(name)
        let event = FileEvent(
            url: folderURL.appendingPathComponent(name),
            size: size,
            detectedAt: Date()
        )
        recentEvents.insert(event, at: 0)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeLast(recentEvents.count - maxRecentEvents)
        }
        // Dev-only visibility for QA runs from a terminal; filename only, never
        // contents — and sanitized, since filenames are attacker-controlled.
        devLog("detected: \(name) (\(event.formattedSize))")
        onNewFile?(event)
    }
}
