import Foundation
import Combine

// MARK: - Injected seams (kept AppKit-free so the queue/timer logic is testable)

/// Shows and hides the one on-screen popup. The real implementation is the
/// AppKit `SuggestionPanelController`; tests pass a mock. Keeping all windowing
/// behind this protocol is what lets `PopupController`'s queue/timer logic run
/// in a plain unit test with no real panel.
@MainActor
protocol PanelPresenting {
    /// Shows the popup for `suggestion`, wiring its controls to `callbacks`.
    func show(_ suggestion: PopupSuggestion, callbacks: PopupCallbacks)
    /// Hides/closes the current popup, if any.
    func hide()
    /// Re-renders the popup already on screen for a new activity, so "Moving…"
    /// and a failure message can reach the user.
    ///
    /// Without this the protocol could only put a popup up and take it down,
    /// and a failed move would leave the panel looking exactly as it did before
    /// the click — indistinguishable from "my Accept didn't register" (M6).
    /// A no-op when nothing is showing.
    func update(activity: PopupActivity)
    /// Speaks one line to VoiceOver.
    ///
    /// A move that succeeds closes the popup, so there is no state left for a
    /// view to announce — without this the whole success path is silent and the
    /// panel simply vanishes (A5). Kept on this protocol rather than done in the
    /// view so the controller stays AppKit-free and the announcement is testable.
    func announce(_ message: String)
}

/// The controls a shown popup reports back to the controller. `onAccept`
/// carries the field's current (possibly edited) text; the controller — not
/// the view — validates it at the boundary.
@MainActor
struct PopupCallbacks {
    let onAccept: (String) -> Void
    let onDismiss: () -> Void
    /// Pointer moved onto (true) or off (false) the panel — pauses auto-dismiss.
    let onHoverChanged: (Bool) -> Void
    /// The panel became key (true) or resigned key (false) — pauses auto-dismiss
    /// while the user is interacting (editing the field makes the panel key).
    let onKeyChanged: (Bool) -> Void
}

/// A cancellable one-shot timer. Abstracted so tests can drive time by hand.
@MainActor
protocol PopupTimerToken: AnyObject {
    func cancel()
}

/// Schedules the auto-dismiss timer. Abstracted (a "clock") so the queue/timer
/// logic is unit-testable without waiting real seconds.
@MainActor
protocol PopupScheduling {
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> PopupTimerToken
}

/// Production clock: a cancellable main-queue delay.
@MainActor
final class RealPopupScheduler: PopupScheduling {
    /// Holds no state, so it is safe to construct off the main actor — this
    /// lets it be a default argument for `PopupController.init`.
    nonisolated init() {}

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> PopupTimerToken {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return Token(item)
    }

    private final class Token: PopupTimerToken {
        private let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}

/// Reads the assistive-technology state that must keep the popup on screen.
/// Injected so tests can simulate VoiceOver on/off without touching the system.
@MainActor
protocol AccessibilityStatusReading {
    /// True when the popup must NOT auto-close: VoiceOver or Full Keyboard
    /// Access is active and the user needs time to reach it and act explicitly.
    var wantsPersistentInteraction: Bool { get }
}

// MARK: - The controller

/// What the popup on screen is doing. Modelled as a state rather than a pair of
/// booleans so "moving" and "the last attempt failed" can never both be true.
enum PopupActivity: Equatable {
    /// Waiting for the user. Accept is available and the auto-dismiss
    /// countdown runs.
    case editing
    /// A move is running for this popup. Accept is unavailable (a second press
    /// would be a second move) and the auto-dismiss countdown is cancelled —
    /// the panel must not vanish out from under a move in progress.
    case moving
    /// The last attempt failed and nothing on disk changed. The popup STAYS
    /// OPEN with this message, and Accept is available again so the user can
    /// edit the name and retry. The countdown stays off: an error the user
    /// never read is exactly the silent failure this milestone exists to kill.
    ///
    /// `offersPrivacySettings` marks the one failure the user can actually fix
    /// from here — macOS privacy (TCC) blocking the destination folder — so the
    /// view can offer "Open System Settings" (founder decision 7). It is a flag
    /// rather than a string match because the message is prose that will be
    /// reworded.
    case failed(message: String, offersPrivacySettings: Bool)
    /// The move SUCCEEDED, but not exactly as asked — the chosen name was taken
    /// and a deduped one was used, or the destination folder was unusable and
    /// the file was renamed where it is.
    ///
    /// The popup stays open with the notice and the countdown stays off, for
    /// the same reason `failed` does: closing on success meant the user asked
    /// for `Invoice.pdf`, got `Invoice 2.pdf`, and could only discover it by
    /// opening the folder (M5). There is nothing left to accept — the file has
    /// already moved — so the only control is Dismiss, reading "OK".
    case completed(notice: String)

    /// Whether pressing Accept in this state is still a meaningful request.
    ///
    /// `.completed` is the one that matters: the file has already moved, so the
    /// path this popup's snapshot names is stale, and a second Accept would try
    /// to move a file that is no longer there — failing, and writing a `failed`
    /// history row about a move that in fact succeeded (F13). `.failed` must
    /// still accept: that is the "Try again" retry, and nothing moved.
    var acceptsAnotherMove: Bool {
        switch self {
        case .editing, .failed: true
        case .moving, .completed: false
        }
    }
}

/// Presents suggestion popups one at a time. Subscribes to
/// `PipelineModel.$fileStates` and enqueues each file exactly once, the first
/// time it settles into a real suggestion; shows a FIFO queue (capped) of
/// self-contained snapshots; and runs a ~15 s auto-dismiss timer that does
/// nothing but close. All windowing is behind `PanelPresenting` and all timing
/// behind `PopupScheduling`, so this whole class is unit-testable with mocks.
///
/// Accept validates the name, hands it to the `SuggestionAccepting` seam, and
/// waits for the answer. It closes the popup ONLY on success — the unconditional
/// close that used to follow the hand-off reported every failed move as a
/// success. Dismiss and auto-dismiss never call the seam.
///
/// Founder decision 5: Dismiss stays available during a move and means *hide*.
/// The panel goes away, the queue advances, and the move runs to completion and
/// records its outcome. It is never a cancel, and a move that finishes after its
/// panel was hidden never brings the panel back.
@MainActor
final class PopupController {
    /// Founder decision: at most this many popups may WAIT in the queue at once
    /// (the one on screen is separate). Overflow files stay in the menu-bar
    /// list, read-only, as today — nothing is lost.
    static let maxQueued = 3

    /// Idle time before a popup auto-dismisses (closing only — no accept).
    static let autoDismissDelay: TimeInterval = 15

    private let presenter: PanelPresenting
    private let accepter: SuggestionAccepting
    private let scheduler: PopupScheduling
    private let accessibility: AccessibilityStatusReading

    /// Files already decided (enqueued, shown, handled, or dropped as overflow),
    /// so each file is considered for a popup exactly once. Dedup by `FileEvent.id`.
    private var decidedIDs: Set<UUID> = []
    /// Popups waiting their turn, oldest first. The one on screen is `current`.
    private var queue: [PopupSuggestion] = []
    /// The popup on screen right now, or nil when none is showing.
    private(set) var current: PopupSuggestion?

    /// What the popup on screen is doing. Every change is pushed straight to the
    /// panel, because a state the user cannot see is not a state — this is the
    /// only route "Moving…" and a failure message have to the screen (M6).
    private(set) var activity: PopupActivity = .editing {
        didSet {
            guard activity != oldValue else { return }
            presenter.update(activity: activity)
        }
    }

    /// Moves started by this controller that have not finished yet, keyed by
    /// file. A move outlives its panel (founder decision 5), so this is NOT the
    /// same thing as "the popup on screen is busy" — it is the record of what is
    /// still touching the user's files.
    private var activeMoves: [UUID: Task<Void, Never>] = [:]

    /// The most recent `fileStates`, used to re-check that a queued item is
    /// still a live settled suggestion before it is shown (spec §5).
    private var latestStates: [UUID: PipelineModel.FileState] = [:]

    // Auto-dismiss suspension inputs (the countdown pauses while any is true).
    private var isPointerInside = false
    private var isPanelKey = false
    private var autoDismissTimer: PopupTimerToken?

    private var statesSubscription: AnyCancellable?

    init(
        presenter: PanelPresenting,
        accepter: SuggestionAccepting,
        scheduler: PopupScheduling = RealPopupScheduler(),
        accessibility: AccessibilityStatusReading
    ) {
        self.presenter = presenter
        self.accepter = accepter
        self.scheduler = scheduler
        self.accessibility = accessibility
    }

    /// Wires the controller to a live pipeline. Call once at app start; the
    /// subscription lasts the app's lifetime. Tests skip this and call
    /// `ingest(_:)` directly, so no real watcher/AI is needed.
    func observe(_ pipeline: PipelineModel) {
        statesSubscription = pipeline.$fileStates.sink { [weak self] states in
            self?.ingest(states)
        }
    }

    // MARK: - Ingesting pipeline state

    /// Considers the latest per-file states: enqueues any newly-settled
    /// suggestion exactly once (oldest first), then shows the next one if idle.
    /// Internal (not private) so unit tests can drive it without a real pipeline.
    func ingest(_ states: [UUID: PipelineModel.FileState]) {
        latestStates = states

        // Newly-settled suggestions we have not decided on yet, oldest first
        // (FIFO by the file's detection time — the dictionary itself is unordered).
        let newlySettled = states
            .compactMap { id, state -> (Date, PopupSuggestion)? in
                guard !decidedIDs.contains(id) else { return nil }
                guard case .suggested(let content, _, _) = state else { return nil }
                guard let snapshot = Self.popupSuggestion(for: state) else { return nil }
                return (content.event.detectedAt, snapshot)
            }
            .sorted { $0.0 < $1.0 }

        for (_, snapshot) in newlySettled {
            decidedIDs.insert(snapshot.fileEventID)
            enqueue(snapshot)
        }

        pruneDecidedIDs()
        showNextIfIdle()
    }

    /// Brings a file's popup back on demand, from a click on its menu row.
    ///
    /// This is how "overflow (menu-only) files can be acted on" is satisfied
    /// (M5 hand-off #3). The queue is capped at `maxQueued`, and a file the user
    /// has already dismissed is in `decidedIDs` — either way it would never pop
    /// again on its own, and until now there was no way to act on it at all.
    ///
    /// Routing back through the popup rather than accepting straight from the
    /// menu is deliberate: the user gets the same editable name, the same
    /// "Moving…", and the same honest failure message. The menu closing on click
    /// is then correct rather than a compromise, because the popup takes over.
    ///
    /// Ignored while that file's move is already running, so a second click
    /// cannot start a second move.
    func reopen(fileEventID: UUID) {
        guard activeMoves[fileEventID] == nil else { return }
        guard current?.fileEventID != fileEventID else { return }
        guard let state = latestStates[fileEventID],
              let snapshot = Self.popupSuggestion(for: state) else { return }

        queue.removeAll { $0.fileEventID == fileEventID }
        decidedIDs.insert(fileEventID)
        // Ahead of the queue: the user asked for this one, now.
        queue.insert(snapshot, at: 0)
        if current != nil { dismiss() } else { showNextIfIdle() }
    }

    /// True when this file can be reopened from its menu row — it has a settled
    /// suggestion and is not the popup already on screen, and no move of it is
    /// running.
    func canReopen(fileEventID: UUID) -> Bool {
        guard activeMoves[fileEventID] == nil else { return false }
        guard current?.fileEventID != fileEventID else { return false }
        guard let state = latestStates[fileEventID] else { return false }
        return Self.popupSuggestion(for: state) != nil
    }

    /// True when this file's popup will NOT appear on its own, so a menu row is
    /// the only way left to act on it — a file the user dismissed, or one that
    /// overflowed the queue.
    ///
    /// Deliberately narrower than `canReopen`: a file still waiting its turn is
    /// about to pop by itself, and an extra "Review…" item for it is a second
    /// visible row per file that the founder-approved dropdown does not have
    /// (D7). The item still exists where it is genuinely the only route, because
    /// the menu's plain `Text` lines render as *disabled* `NSMenuItem`s that
    /// keyboard navigation and VoiceOver skip entirely.
    func needsMenuRoute(fileEventID: UUID) -> Bool {
        guard canReopen(fileEventID: fileEventID) else { return false }
        return !queue.contains { $0.fileEventID == fileEventID }
    }

    /// Builds a display snapshot from a file state, or nil if the state is not
    /// a poppable suggestion. A popup shows only for a real AI suggestion whose
    /// destination has settled (`.pending` is still matching → not yet).
    static func popupSuggestion(for state: PipelineModel.FileState) -> PopupSuggestion? {
        guard case .suggested(let content, let result, let destinationState) = state,
              case .suggestion(let suggestion) = result else { return nil }

        let destination: PopupDestination
        switch destinationState {
        case .pending:
            return nil
        case .quiet:
            destination = .quiet
        case .match(let name, let id):
            destination = .folder(name: name, id: id)
        case .noMatch:
            destination = .noFolderFits
        }

        return PopupSuggestion(
            fileEventID: content.event.id,
            sourceURL: content.event.url,
            originalName: content.event.name,
            suggestedFilename: suggestion.suggestedFilename,
            destination: destination
        )
    }

    /// Appends to the pending queue, or drops the item as overflow (it stays in
    /// the menu list) once the queue is full.
    private func enqueue(_ snapshot: PopupSuggestion) {
        guard queue.count < Self.maxQueued else { return }
        queue.append(snapshot)
    }

    /// Keeps `decidedIDs` from growing unbounded over a long session: forget
    /// files that are no longer in `fileStates` and are not currently active.
    /// Safe because every `FileEvent` gets a fresh id, so a forgotten id never
    /// recurs.
    private func pruneDecidedIDs() {
        var keep = Set(latestStates.keys)
        keep.formUnion(queue.map(\.fileEventID))
        if let current { keep.insert(current.fileEventID) }
        decidedIDs.formIntersection(keep)
    }

    // MARK: - Showing / advancing

    private func showNextIfIdle() {
        guard current == nil else { return }        // one popup at a time
        guard let next = dequeueNextLiveSuggestion() else { return }
        present(next)
    }

    /// Removes and returns the next queued item that is still a live settled
    /// suggestion, skipping any that were pruned or unsettled while waiting.
    private func dequeueNextLiveSuggestion() -> PopupSuggestion? {
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            if isStillLiveSuggestion(candidate.fileEventID) {
                return candidate
            }
            // Pruned or no longer a settled suggestion — drop it, try the next.
        }
        return nil
    }

    private func isStillLiveSuggestion(_ id: UUID) -> Bool {
        guard let state = latestStates[id] else { return false }
        return Self.popupSuggestion(for: state) != nil
    }

    private func present(_ suggestion: PopupSuggestion) {
        current = suggestion
        activity = .editing
        isPointerInside = false
        isPanelKey = false
        // One rule for every callback: it only acts on the popup that created it.
        // A single Return can fire both the field's onSubmit and the default-action
        // button; if the first closes this popup and advances to the next queued
        // one, a second (stale) call from the just-closed popup must be dropped —
        // otherwise accept/dismiss would act on a different file the user never
        // confirmed, and a stale hover/key would perturb the next popup's
        // auto-dismiss timer. Guarding all four (rather than only the data-critical
        // accept/dismiss) keeps the model uniform and needs no per-callback reasoning.
        let shownID = suggestion.fileEventID
        let callbacks = PopupCallbacks(
            onAccept: { [weak self] name in
                guard self?.current?.fileEventID == shownID else { return }
                self?.accept(editedName: name)
            },
            onDismiss: { [weak self] in
                guard self?.current?.fileEventID == shownID else { return }
                self?.dismiss()
            },
            onHoverChanged: { [weak self] inside in
                guard self?.current?.fileEventID == shownID else { return }
                self?.setPointerInside(inside)
            },
            onKeyChanged: { [weak self] isKey in
                guard self?.current?.fileEventID == shownID else { return }
                self?.setPanelKey(isKey)
            }
        )
        presenter.show(suggestion, callbacks: callbacks)
        scheduleAutoDismissIfAppropriate()
    }

    // MARK: - User actions

    /// The user accepted. Validates the (possibly edited) name at the boundary —
    /// it becomes a real filename — then hands a built `AcceptedSuggestion` to
    /// the seam and waits. If the name is unusable the hand-off is refused and
    /// nothing crosses the seam (defense in depth; the Accept control is already
    /// disabled for this case).
    ///
    /// Synchronous on purpose: pressing Accept must put the popup into its
    /// "moving" state immediately, while the move itself runs on.
    func accept(editedName: String) {
        guard let current else { return }
        // One move per file. This is both the "Accept is disabled while moving"
        // rule and the guard against a single Return firing the field's onSubmit
        // AND the default-action button.
        guard activeMoves[current.fileEventID] == nil else { return }
        // ...and that guard is not enough on its own. It falls away the moment
        // the first move finishes, which is exactly when the popup is sitting in
        // `.completed` — file already moved, snapshot path already stale. The
        // footer hides Accept there, but the name field's Return does not go
        // through the footer (F13).
        guard activity.acceptsAnotherMove else { return }

        // Same output-side guard the AI module applies to its own suggestions:
        // strips path separators, control/bidi characters, leading dots, and
        // path traversal, and re-applies the real extension. nil = nothing usable.
        guard let chosenFilename = FilenameSanitizer.sanitize(
            editedName, originalExtension: current.fileExtension
        ) else {
            return
        }

        let decision = AcceptedSuggestion(
            fileEventID: current.fileEventID,
            sourceURL: current.sourceURL,
            originalName: current.originalName,
            chosenFilename: chosenFilename,
            destinationFolderID: current.destination.folderID,
            destinationFolderName: current.destination.folderName
        )
        activity = .moving
        cancelAutoDismiss()
        startMove(decision)
    }

    /// The user dismissed — the button, or Esc. Hides the panel and advances the
    /// queue. It is never a cancel: a move already running for this file keeps
    /// going and still records its outcome (founder decision 5), which is why
    /// Dismiss stays available throughout and Esc is always answered.
    func dismiss() {
        guard current != nil else { return }
        finishCurrent()
    }

    /// The auto-dismiss timer fired. Identical to `dismiss()` — it closes and
    /// advances but performs NO action and never calls the seam (spec §2).
    func autoDismiss() {
        guard let current else { return }
        // Belt and braces: the countdown is already cancelled when a move
        // starts, and a timer that somehow survived must not take the panel
        // away mid-move without the user ever choosing to.
        guard activeMoves[current.fileEventID] == nil else { return }
        finishCurrent()
    }

    /// Closes the current popup and advances to the next queued one. Deliberately
    /// does NOT touch `activeMoves`: hiding a panel never stops a move.
    private func finishCurrent() {
        cancelAutoDismiss()
        current = nil
        activity = .editing
        isPointerInside = false
        isPanelKey = false
        presenter.hide()
        showNextIfIdle()
    }

    // MARK: - The move in flight

    /// Starts the seam call and remembers it, so a hidden popup's move is still
    /// tracked to completion.
    private func startMove(_ decision: AcceptedSuggestion) {
        let fileEventID = decision.fileEventID
        activeMoves[fileEventID] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.accepter.accept(decision)
            self.finish(move: fileEventID, with: outcome)
        }
    }

    /// The seam answered. The popup closes only on success; a failure leaves it
    /// open with an honest message and Accept available for a retry.
    private func finish(move fileEventID: UUID, with outcome: AcceptOutcome) {
        activeMoves.removeValue(forKey: fileEventID)

        // The same identity rule every popup callback follows: only ever act on
        // the popup that started this move. If it was hidden mid-move, or the
        // queue has moved on, the panel is left exactly as it is — a finished
        // move must never resurrect a popup the user sent away, nor act on the
        // next file the user has not decided about yet.
        guard let current, current.fileEventID == fileEventID else { return }

        switch outcome {
        case .moved(let summary):
            // A move that did exactly what was asked closes, as before. One that
            // quietly did something else — a deduped name, a folder that wasn't
            // available — holds the popup open and says so, because the folder
            // is the only other place that information exists (M5).
            if let notice = summary.notice {
                activity = .completed(notice: notice)
            } else {
                // Spoken BEFORE the close, because the close is the whole event:
                // a sighted user sees the popup go and the file land, a VoiceOver
                // user gets nothing at all unless we say it (A5).
                presenter.announce(Self.successAnnouncement(for: summary))
                finishCurrent()
            }
        case .unchanged:
            presenter.announce(
                "Nothing to change — that file already has this name in this folder."
            )
            finishCurrent()
        case .failed(let failure):
            // The folder by name, not "that folder" (D5): the sentence is read
            // seconds after the user picked that folder in this very popup.
            activity = .failed(
                message: failure.message(namingFolder: current.destination.folderName),
                offersPrivacySettings: failure.isBlockedByPrivacy
            )
        }
    }

    /// What VoiceOver hears when a move went exactly as asked. Static and pure
    /// so the wording is unit-testable rather than eyeballed.
    static func successAnnouncement(for summary: MoveSummary) -> String {
        guard let folder = summary.destinationFolderName else {
            return "Renamed to \(summary.finalName)."
        }
        return "Moved. \(summary.finalName) is now in \(folder)."
    }

    /// Awaits every move still running. The app never blocks on this; it exists
    /// so tests can observe a move's completion deterministically instead of
    /// sleeping.
    func waitForActiveMoves() async {
        while let task = activeMoves.values.first {
            await task.value
        }
    }

    // MARK: - Auto-dismiss timer

    /// Pointer entered/left the panel — pause or resume the countdown.
    func setPointerInside(_ inside: Bool) {
        isPointerInside = inside
        scheduleAutoDismissIfAppropriate()
    }

    /// Panel became/resigned key — pause the countdown while the user interacts
    /// (editing the name field makes the panel key, so this covers editing too).
    func setPanelKey(_ isKey: Bool) {
        isPanelKey = isKey
        scheduleAutoDismissIfAppropriate()
    }

    private var autoDismissSuspended: Bool { isPointerInside || isPanelKey }

    /// (Re)starts the auto-dismiss countdown, or leaves it cancelled when it
    /// must not run: no popup, assistive tech active (require an explicit
    /// choice), or the countdown is paused by hover/interaction.
    private func scheduleAutoDismissIfAppropriate() {
        cancelAutoDismiss()
        guard current != nil else { return }
        // A move in flight, or a failure the user has not read yet, both need an
        // explicit choice — never a countdown that closes the popup for them.
        guard activity == .editing else { return }
        guard !accessibility.wantsPersistentInteraction else { return }
        guard !autoDismissSuspended else { return }
        autoDismissTimer = scheduler.schedule(after: Self.autoDismissDelay) { [weak self] in
            self?.autoDismiss()
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.cancel()
        autoDismissTimer = nil
    }
}
