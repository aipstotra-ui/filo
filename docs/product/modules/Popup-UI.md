# Popup-UI

Everything the user sees: the menu-bar item and (from M5) the floating suggestion popup. Also home to the small "conductor" object that wires the pipeline together.

## The menu bar (built M1–M2, still the base layer)

- Menu-bar icon (no Dock icon) with a dropdown listing recently detected files from [[Watcher]], plus Quit.
- Each file is a **two-line row**: line 1 is name + size, line 2 is a status line — "Reading…", then either "*method* · *N* words" (e.g. "PDF text · 214 words") or "*reason* — using name & type". **Status only — snippet content is never displayed or logged.**
- `Sources/FileOrganizer/UI/App.swift` — app entry point, menu-bar setup, owns the `PipelineModel`
- `Sources/FileOrganizer/UI/MenuContentView.swift` — the dropdown list and status lines
- `Sources/FileOrganizer/UI/PipelineModel.swift` — connects [[Watcher]] → [[Extraction]]: subscribes to the watcher's new-file hook, kicks off extraction, tracks per-file progress for the UI, enforces a **60-second per-file timeout** ("Took too long to read") and drops results that arrive after it, and prunes state for files no longer shown.

## M5 — the suggestion popup (built 2026-07-23; reviewed)

A floating **non-activating** panel slides in at the top-right when a new download settles into a real suggestion. It shows the current name (dimmed), an **editable** suggested name, the destination (a matched folder, the honest "No folder fits — leaving it in Downloads", or nothing), and **Dismiss** / **Accept**. Ignore it and it fades after ~15 s, doing nothing. Founder-approved mockup: `docs/mockups/m5-popup.html`. Styling in [[design-system]].

**Hard scope boundary — M5 moves NO file.** Accept validates the (possibly edited) name and hands a value to a seam; M5's implementation of that seam does nothing to disk. The real move + undo are [[History-Undo]] (M6). Pinned by a zero-I/O test.

Files (all `Sources/FileOrganizer/UI/`):
- `PopupController.swift` — the brain: subscribes to `PipelineModel.$fileStates`, enqueues each file exactly once when it settles into a real suggestion, shows a FIFO queue (cap 3; overflow stays menu-only), runs the ~15 s auto-dismiss timer. AppKit-free (windowing behind `PanelPresenting`, timing behind `PopupScheduling`, assistive-tech behind `AccessibilityStatusReading`) so the queue/timer logic is unit-tested with mocks. Every popup's callbacks are **identity-bound** — a callback only ever acts on the popup that created it.
- `SuggestionAccepting.swift` — the Accept seam: `protocol SuggestionAccepting` + the `AcceptedSuggestion` value (carries the destination folder's **`Int64` store identity**, not just its name) + `NoMoveAccepting` (M5's impl: records the decision in memory, zero FileManager work).
- `PopupSuggestion.swift` — the self-contained snapshot the popup renders from (never live `fileStates` after show), + `PopupDestination` (folder / noFolderFits / quiet).
- `PopupContentView.swift` — the SwiftUI content: semantic system colors + native controls only, so Increase Contrast / Reduce Transparency / accent respond automatically. Return accepts, Esc dismisses; the field is never auto-focused.
- `SuggestionPanel.swift` — the real `NSPanel` (non-activating, key only on user click, never `NSApp.activate`) + `SuggestionPanelController` (top-right placement, Reduce-Motion-aware animation, VoiceOver arrival announcement) + `PopupPositioner` (pure geometry) + `SystemAccessibilityStatus`.
- `App.swift` — wires it at launch via an `AppDelegate` (so the popup observes downloads whether or not the menu is ever opened); injects `NoMoveAccepting`.

**Reviewed** 2026-07-23 by the full independent round (security-auditor **PASS**; all reviewers clean). 94 tests green; `swift build` debug + release clean.

**Open before M5 is fully signed off:**
- **Founder live-VoiceOver check** (~5 min) — code can't prove macOS actually *speaks* the arrival announcement from a non-key `.accessory` panel while another app is frontmost (Apple makes this unreliable). If silent, the fix is a design/menu path in M6 — **not** making the panel key (that breaks the non-activating promise).
- **M6 hand-off requirements** (from the review round):
  1. The seam must gain a **failure channel** and `PopupController` must make closing the popup **conditional on move success** — a failed move/rename/history-write must keep the popup open and surface an error, never close-as-success ("history says it moved but it didn't").
  2. M6's mover must **re-validate `sourceURL` and `destinationFolderID` fresh at move time** (both are enqueue-time snapshots and can be stale after the popup sits open) — fall back to "leave in Downloads" if the file or folder is gone; never trust the snapshot blindly. For undo, persist the **resolved destination path**, not the raw id (a rebuilt index resets AUTOINCREMENT).
  3. Overflow files (beyond the 3-deep queue) are menu-only and never re-pop — M6 needs a way to act on them, since the menu is read-only today.

## Talks to

- Consumes events from [[Watcher]] and results from [[Extraction]] (via `PipelineModel`); later suggestions from [[Folder-Index]] (M4+).
- Accept hands off through the `SuggestionAccepting` seam — in M5 that's `NoMoveAccepting` (records the choice, moves nothing); M6 plugs the real [[History-Undo]] mover behind the same protocol. The UI itself never moves files.
