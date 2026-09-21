import Foundation

/// The hand-off seam the popup calls when the user accepts a suggestion.
/// The implementation owns EVERY filesystem effect: M6's `MoveCoordinator`
/// moves the file and records an undoable history row; `NoMoveAccepting` (still
/// what the app injects) does nothing at all.
///
/// M6 widened this from a `Void` call to an `async` call returning
/// `AcceptOutcome`. That return value IS the failure channel: without it the
/// popup closed the moment Accept was pressed, which reported every failed move
/// as a success. The popup now closes only on `.moved`/`.unchanged`.
@MainActor
protocol SuggestionAccepting {
    /// Called when the user accepts. `decision.chosenFilename` has already been
    /// validated at the popup's Accept boundary (see `PopupController.accept`),
    /// so an implementation can trust it is a single safe path component.
    ///
    /// Runs for as long as the move takes (a cross-volume copy is not instant),
    /// so it must be safe for the popup to be hidden while this is still
    /// running — founder decision 5: hiding the panel never cancels a move.
    func accept(_ decision: AcceptedSuggestion) async -> AcceptOutcome
}

/// Everything a mover needs to move + rename one file and record an undo,
/// captured at the moment the user accepts. A value type so it crosses the
/// seam without shared state.
struct AcceptedSuggestion: Sendable, Equatable {
    /// Identity of the originating `FileEvent`.
    let fileEventID: UUID
    /// Where the file is right now (the watched Downloads copy) — the source
    /// M6 moves from. M5 only reads its extension while validating the name.
    let sourceURL: URL
    /// The file's current on-disk name.
    let originalName: String
    /// The name the user confirmed, possibly edited. VALIDATED at the boundary:
    /// never empty, never a path separator, never a control/bidi character
    /// (see `PopupController.accept`, which runs it through `FilenameSanitizer`).
    let chosenFilename: String
    /// The destination folder's store identity, or nil to leave the file in
    /// Downloads / rename it in place. Identity — not just the name — so M6
    /// moves to the right folder even when two folders share a leaf name.
    let destinationFolderID: Int64?
    /// The destination folder's display name, for the history record M6 writes.
    let destinationFolderName: String?
}

/// The Accept seam when there is no history database to record a move in.
///
/// Founder decision 1 — fail closed — all the way to the screen: the file is not
/// touched AND the user is told, at the moment they ask for the move. The popup
/// stays open with the message, exactly as it does for any other refusal.
///
/// This exists because the honest-looking alternative was not honest.
/// `NoMoveAccepting` returns `.unchanged`, which the popup treats as success, so
/// with an unopenable `history.db` every Accept closed the popup exactly as a
/// real move does while the file sat untouched in Downloads — no row, no
/// message, and the menu still reading "Watching Downloads" (F2).
@MainActor
final class RefusingAccepting: SuggestionAccepting {
    init() {}

    func accept(_ decision: AcceptedSuggestion) async -> AcceptOutcome {
        .failed(.historyUnavailable(detail: "the history database could not be opened"))
    }
}

/// The zero-effect implementation of the Accept seam: it records the decision
/// in memory and (dev builds only) logs a sanitized one-liner. It performs NO
/// FileManager calls — no move, no rename, no delete, no create — pinned by a
/// zero-I/O test.
///
/// **A test double.** It reports `.unchanged`, which is a success, so a popup
/// wired to it closes as though a file had moved. That was fine when the app
/// deliberately moved nothing (M5) and became a silent failure the moment it
/// did (F2) — the app now injects `RefusingAccepting` instead. Keep this for
/// tests that need a seam with no filesystem effect at all.
@MainActor
final class NoMoveAccepting: SuggestionAccepting {
    /// The most recent accepted decision, kept so the app (and tests) can see
    /// what was accepted with no disk effect at all.
    private(set) var lastAccepted: AcceptedSuggestion?
    /// Every decision accepted this session, in order (in memory only).
    private(set) var accepted: [AcceptedSuggestion] = []

    /// Always `.unchanged`: nothing on disk changed, and nothing was recorded,
    /// so there is nothing to undo. `.unchanged` is a success, so the popup
    /// closes exactly as it did before the seam was widened.
    func accept(_ decision: AcceptedSuggestion) async -> AcceptOutcome {
        lastAccepted = decision
        accepted.append(decision)
        #if DEBUG
        // Both the chosen name AND the destination folder name are external input
        // (attacker-named download / user-named folder), so sanitize BOTH before
        // they reach a dev log (LogSanitizer discipline). Never the file's content.
        let destination = decision.destinationFolderName
            .map { " -> " + LogSanitizer.sanitized($0) } ?? ""
        print("NoMoveAccepting: accepted "
            + LogSanitizer.sanitized(decision.chosenFilename) + destination
            + " (no file moved)")
        #endif
        return .unchanged
    }
}
