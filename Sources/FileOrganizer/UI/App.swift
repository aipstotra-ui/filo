import SwiftUI
import AppKit

@main
struct FileOrganizerApp: App {
    /// The delegate owns the pipeline and popup controller and wires them at
    /// launch (see `AppDelegate`). Using a delegate — not a lazily-created
    /// `@StateObject` — guarantees the popup starts observing new downloads as
    /// soon as the app launches, whether or not the user ever opens the menu.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("AI File Organizer", systemImage: "tray.and.arrow.down.fill") {
            MenuContentView(
                watcher: appDelegate.pipeline.watcher,
                pipeline: appDelegate.pipeline,
                registry: appDelegate.pipeline.registry,
                popups: appDelegate.popupController
            )
        }

        Settings {
            SettingsView(
                watcher: appDelegate.pipeline.watcher,
                registry: appDelegate.pipeline.registry,
                coordinator: appDelegate.coordinator,
                openFailure: appDelegate.historyOpenFailure
            )
        }
    }
}

/// Wires the pipeline to the popup (Popup-UI's "conductor"). Created once by the
/// SwiftUI app lifecycle; `applicationDidFinishLaunching` runs exactly once at
/// launch, so the popup controller observes the same pipeline the menu shows for
/// the app's whole lifetime.
///
/// **M6 is where this app first touches the user's files.** `MoveCoordinator`
/// replaces M5's `NoMoveAccepting` as the Accept seam, so accepting a suggestion
/// now really moves the file — recorded before it happens, undoable after.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created at delegate init (launch, on the main actor); shared by the menu,
    /// Settings, and the popup.
    let pipeline: PipelineModel

    /// The move history and undo, or nil when the history database could not be
    /// opened at all.
    ///
    /// nil is a deliberate, honest degradation rather than a crash: founder
    /// decision 1 says a move the app cannot record is a move it does not make,
    /// so with no history the app makes no moves — and says so, at the moment
    /// the user asks for one, not only in a Settings tab nothing points at.
    let coordinator: MoveCoordinator?

    /// Why the history database could not be opened, when it could not. Kept so
    /// Settings can be specific: "restarting usually fixes this" is true of a
    /// locked file and false of a database written by a newer version (F12).
    let historyOpenFailure: MoveHistoryStore.StoreError?

    /// Held for the app's lifetime so its subscription and any shown popup stay
    /// alive, and so the menu can reopen a popup for a file that scrolled past
    /// the queue.
    let popupController: PopupController

    /// Everything is built HERE, not in `applicationDidFinishLaunching`.
    ///
    /// SwiftUI evaluates the `App`'s `body` — and so reads these properties —
    /// before the delegate's launch callback runs. Building them later left the
    /// `Settings` scene holding the nil it saw at startup forever: the History
    /// tab claimed the history was unavailable while the app was, at that very
    /// moment, moving files and recording them. The menu got a nil
    /// `popupController` the same way, so its rows were never clickable.
    /// Constructing in `init` removes the ordering question entirely.
    override init() {
        let pipeline = PipelineModel()
        let watcher = pipeline.watcher
        let opened = Self.makeCoordinator(pipeline: pipeline, watcher: watcher)

        self.pipeline = pipeline
        self.coordinator = opened.coordinator
        self.historyOpenFailure = opened.failure
        self.popupController = PopupController(
            presenter: SuggestionPanelController(),
            // The one line that makes this app move files. Everything that
            // blocked it — the cross-volume delete (C1), adopting a stranger's
            // file on reconcile (C2), a failed move reporting success (C3), the
            // failure having no route to the screen (M6), the claim race (M7),
            // and the undo write-bounds gate (M14) — is fixed and pinned by
            // mutation-verified tests.
            //
            // With no history database the seam REFUSES rather than pretending.
            // `NoMoveAccepting` returns `.unchanged`, which is a success, so the
            // popup closed exactly as it does after a real move while the file
            // sat untouched in Downloads (F2) — the precise shape of failure
            // founder decision 1 exists to prevent. It is a test double now.
            accepter: opened.coordinator ?? RefusingAccepting(),
            accessibility: SystemAccessibilityStatus()
        )
        super.init()
        popupController.observe(pipeline)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        if let coordinator {
            // Launch pass: settle any row stranded by a crash mid-move, prune to
            // the retention limit, and publish the history Settings shows.
            Task { await coordinator.start() }
        }
    }

    /// Quit, while this app may be part-way through moving one of the user's
    /// files.
    ///
    /// A cross-volume move is a copy, and killing the process mid-`copyfile`
    /// leaves a partial file nothing cleans up plus an `inProgress` row that the
    /// next launch can only settle as `unknown` — sending the user to look in
    /// two places for a file the app was seconds from placing correctly (F10).
    /// So quitting waits, briefly and boundedly: the move is finishing anyway,
    /// and it is the record of it that needs those last milliseconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.isBusy else {
            closeHistory()
            return .terminateNow
        }
        Task { [weak self] in
            await coordinator.waitUntilIdle(limit: Self.quitGracePeriod)
            self?.closeHistory()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// How long a quit waits for a move to finish before giving up on it. Long
    /// enough for a same-volume rename and a modest copy; short enough that the
    /// app never feels stuck. A move still running past this settles at the next
    /// launch, exactly as a crash would.
    private static let quitGracePeriod: TimeInterval = 5

    /// Closes the history connection so a quit is a clean close rather than an
    /// abandoned one (X4).
    private func closeHistory() {
        guard let coordinator else { return }
        Task { await coordinator.closeStore() }
    }

    /// Builds the real Accept seam, or reports why it could not.
    private static func makeCoordinator(
        pipeline: PipelineModel, watcher: DownloadsWatcher
    ) -> (coordinator: MoveCoordinator?, failure: MoveHistoryStore.StoreError?) {
        let store: MoveHistoryStore
        do {
            store = try MoveHistoryStore(databaseURL: MoveHistoryStore.defaultDatabaseURL())
        } catch {
            // Kept, not discarded. `try?` threw away a typed error that
            // distinguishes "can't open", "query failed" and "written by a newer
            // version" — and the pane's one sentence, "restarting the app
            // usually fixes this", is only true of the first two (F12).
            #if DEBUG
            print("AppDelegate: the history database could not be opened: "
                + LogSanitizer.sanitized("\(error)"))
            #endif
            return (nil, error)
        }

        // The mover announces every name it is about to write, and the watcher's
        // claim box keeps the ones landing in the folder it watches. Without
        // this, a rename in place — and every undo, which restores a file *into*
        // Downloads — looks like a brand-new download and the app makes a
        // suggestion for the file it just wrote.
        let claims = watcher.appCreatedClaims
        let coordinator = MoveCoordinator(
            store: store,
            resolver: MoveDestinationResolver(
                registry: pipeline.registry,
                watchedDirectory: watcher.folderURL
            ),
            mover: FileMover(
                announceCandidate: { url, group in claims.claim(url, group: group) }
            ),
            claims: claims,
            fileWasFiled: { [weak watcher] id in watcher?.forget(fileEventID: id) }
        )
        return (coordinator, nil)
    }
}
