# M6 accessibility spec (from a11y-architect, 2026-07-27) — build to this, audit against §L

Founder decisions already resolve the two blocks: **A1 → Dismiss becomes "Hide", stays enabled mid-move, Esc always answered.** **A2 → dropdown switches to `.menuBarExtraStyle(.window)`.** Everything below still applies.

## B. Popup — "Moving…" state
- Suggested name must stay VoiceOver-readable: keep the `TextField` `.disabled(true)`, or a `Text` with `.accessibilityLabel("Suggested name")` + `.accessibilityValue(name)`. Never `.accessibilityHidden`.
- "Moving…" caption: `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Moving")`. Not read automatically — must be announced (§G).
- Accept disabled: `.accessibilityLabel("Accept suggestion")` `.accessibilityHint("Moving. Please wait.")`.
- Return must not start a second move — a `.defaultAction` shortcut on a `.disabled` button is already inert; **assert it in a test**.
- Focus must land on Hide when Accept disables (`@FocusState`). Never leave the panel with zero focusable controls.

## C. Popup — failed state
- Error + sub-line read as ONE element: `VStack` + `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Error. \(errorLine) \(subLine)")` — "Error." is the non-visual equivalent of the red.
- `.fixedSize(horizontal: false, vertical: true)` on the error `Text` — the panel is a fixed 312 pt wide; a long folder name would otherwise truncate the reason.
- **PANEL MUST RESIZE.** `SuggestionPanelController.show` computes `hosting.fittingSize` once (`SuggestionPanel.swift:70-77`). Recompute on state change and `setFrame` **top-anchored**, else the error is drawn outside the frame and is invisible. Real implementation trap.
- The "System Settings" link must be keyboard-reachable: make it its own `Button("Open System Settings")` on its own line, OR name the path in words ("System Settings › Privacy & Security › Files and Folders"). An inline link inside `Text` is not focusable on macOS.
- Accept re-enabled: `.accessibilityHint("Tries again. Renames the file to \(name) and moves it to \(folder).")`.
- Focus moves to **Accept** when the state flips to `.failed`, so Return retries.
- Auto-dismiss stays off in the failed state (WCAG 2.2.1).

## D. History rows — exact strings
Visible titles stay short; the accessible name carries the file.

| State | Visible | Accessible label | Hint |
|---|---|---|---|
| moved | `Undo` | `Undo move of {finalName}` | `Puts it back in Downloads as {originalName}. This can't be redone.` |
| renamed in place | `Undo` | `Undo rename of {finalName}` | `Puts the name {originalName} back. This can't be redone.` |
| moved, previous undo failed | `Undo` | `Undo move of {finalName}. Last attempt failed: that file isn't where the app left it.` | as moved |
| undone | *(no action)* | `{finalName}. Undone — back in Downloads as {restoredName}.` | — |
| failed | *(no action)* | `{name}. Couldn't move — no access to {folder}. The file is still in Downloads.` | — |
| unknown | *(no action)* | `{name}. Result unknown — the app stopped mid-move. Check Downloads and {folder}.` | — |
| empty | *(text)* | `No moves yet. Accepted files appear here.` | — |

- Each history row is ONE element: `.accessibilityElement(children: .combine)`.
- Say `"Moved to Invoices"`, never `"→ Invoices"`. Arrow and folder glyph are decoration → `.accessibilityHidden(true)`. **`FolderIcon` in the existing file rows is not hidden today (`MenuContentView.swift:126-128`) — fix while in there.**
- Use a real `Section("Recent")`, not a styled `Text`.
- Undo is one click with no redo: the hint is the ONLY warning. Do **not** add a confirmation dialog.

## E. Per-row Accept — exact strings

| State | Visible | Accessible label | Hint |
|---|---|---|---|
| ready, folder matched | `Accept` | `Accept suggestion for {originalName}` | `Renames it to {suggestedName} and moves it to {folder}.` |
| ready, no folder fits | `Accept` | `Accept suggestion for {originalName}` | `Renames it to {suggestedName}. It stays in Downloads.` |
| in flight | `Moving…` (disabled) | `Moving {originalName}` | — |
| previous move failed | `Accept` | `Accept suggestion for {originalName}. Retry after a failed move.` | as ready |

- Phrase identically to the popup for the same concept — the popup says `"Destination folder, Invoices."` (`PopupContentView.swift:137`). WCAG 3.2.4.
- In-flight row must be a **disabled `Button`**, not a `Text`, so item order stays stable.
- Drop the spinner from the menu row — "Moving…" as text is honest and motion-free.
- The `sub` indent must be **padding, not a narrowed row** — the whole row width stays clickable.

## F. Settings — Clear History
- `Button("Clear History…")` `.accessibilityLabel("Clear move history")` `.accessibilityHint("Opens a confirmation. Your files stay where they are; only the record is deleted.")`
- **Must be a real `.alert`, not a hand-built `.sheet`** — a custom sheet gets no alert role and VoiceOver will not announce it on open.
- `Button("Clear History", role: .destructive)`.
- `Button("Cancel", role: .cancel).keyboardShortcut(.defaultAction)` — **SwiftUI on macOS does NOT make cancel the default automatically.** Verify Return actually cancels.
- Announce `"Move history cleared. 0 moves stored."` — reliable, Settings is a key window.

## G. Announcements
Use a **pure static function** per message so it's unit-testable and reuses the visible string verbatim — the existing `SuggestionPanelController.announcement(for:)` pattern (`SuggestionPanel.swift:180-189`), posted via the `NSAccessibility.post(.announcementRequested, priority: .high)` helper (`PopupContentView.swift:180-189`).

| Moment | String | Reliability |
|---|---|---|
| Move exceeds 200 ms | `Moving {suggestedName}.` | Good — panel is key |
| Move succeeded (popup) | `Moved {suggestedName} to {folder}.` | Good **if posted before `hide()`** |
| Rename-in-place fallback | `Renamed to {suggestedName}. It stayed in Downloads — {folder} wasn't available.` | Good |
| Move failed (popup) | `Error. {visible error line} {visible sub-line}` | Good while key; unreliable if the user switched apps |
| Suggestion arrival (M5) | existing | **Still unverified — M6 must not assume it was solved** |
| Menu Accept/Undo result | `Moved {name} to {folder}.` / `Undone. {originalName} is back in Downloads.` / `Undone. Restored as {actualName} — the original name was taken.` / `Can't undo — that file isn't where the app left it.` | Verify live |
| Clear history | `Move history cleared. 0 moves stored.` | Reliable |

**Queue collision:** on success the popup closes and the next queued popup fires its own high-priority arrival announcement, clobbering the success message. When `AccessibilityStatusReading.wantsPersistentInteraction` is true, delay presenting the next popup by ~700 ms.

**The durable fallback:** the Recent section and per-row outcome lines are a re-readable record that needs no announcement to work. With `.window` style making them reachable, this is what makes the unreliable announcements survivable.

## H. Motion
| Item | Default | Reduce Motion |
|---|---|---|
| Popup spinner | `ProgressView().controlSize(.small)` after a 200 ms delay | **Omit entirely** — `ProgressView` does not stop on its own. `@Environment(\.accessibilityReduceMotion)` → `if !reduceMotion { ProgressView() }` |
| Footer swap | `.easeOut(duration: 0.12)` | instant — `withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12))` |
| Panel growth on error | animated `setFrame`, top-anchored | instant `setFrame(..., display: true)` — reuse `SuggestionPanel.swift:138-157` |
| Menu "Moving…" | text only | text only |

## I. Contrast & colour
- **Use semantic colours, not the mockup's hexes**: `.systemRed` / `.systemOrange` (or `.red` / `.orange`), never `#D70015` / `#B25000`. macOS adjusts system colours under Increase Contrast; a hex does not. Matters most in the dropdown, which composites over an arbitrary wallpaper.
- Measured: red 4.9:1 light / 5.1:1 dark; amber **4.74:1 light** (passes 4.5:1 with almost no margin) / 8.0:1 dark. The amber has no headroom.
- **`.secondary` status text is the weak link** — "Undone — back in Downloads" at 50% label colour measures ~3.9:1 on menu material, below 4.5:1 for an 11 pt caption. It is *status*, not decoration. Use semantic `.secondary` (macOS bumps it under Increase Contrast); fully compliant at default settings would need `.primary` weight — a visual call.
- **Do not set a custom dropdown background** — let system material handle it so Reduce Transparency makes it opaque automatically.
- No colour-only meaning anywhere: every amber/red state carries a full sentence. Passes as designed. Verify with Differentiate Without Color.

## J. Text size & truncation
- **NEVER pre-truncate a filename into a String.** Pass the full name; use `.lineLimit(1).truncationMode(.middle)` so VoiceOver reads the **full** name. Constructing `"2026-06 Chase Sapp…tement.pdf"` in code destroys the real name for VoiceOver. **The single most likely implementation mistake in §D/§E.**
- Semantic fonts only. No fixed-height containers — the popup's fixed *width* is fine, its *height* must grow.

## K. Two M5 strings M6 must not leave lying
1. `PopupContentView.swift:170` — `"Confirms the suggested name. No file is moved in this version."` becomes **false** the moment M6 lands. A VoiceOver user would be told nothing moves, then press Accept and have a file moved. Replace with the destination-aware hint from §C/§E. (WCAG 3.3.2)
2. `PopupContentView.swift:155-160` — Dismiss uses `.buttonStyle(.plain)` around a bare `Text`: hit area ≈ 55×17 pt, may draw no focus ring. M6 rewrites this footer anyway: add `.contentShape(Rectangle())` + vertical padding toward ~44 pt, confirm the focus ring under Full Keyboard Access. (WCAG 2.4.7, 2.5.8)

## L. Verification checklist (audit the built UI against this)
1. VoiceOver on, arrow through the dropdown — **every** history row and file row announced, including undone/failed/unknown.
2. Five Undo items read as five **different** things.
3. Full Keyboard Access: reach and activate a per-row Accept and an Undo without a mouse.
4. Popup mid-move: Esc → something happens. Return → no second move (assert in a test).
5. Force a failure (revoke access to the destination folder): the panel **grows**, the error is fully visible, and it is spoken.
6. After the failure, press Return with no mouse → it retries.
7. Reduce Motion on: no spinner, no slide, no growth animation.
8. Increase Contrast + Differentiate Without Color, light and dark: every status readable and distinguishable.
9. A 120-character filename with emoji: VoiceOver reads the **whole** name.
10. Clear History: alert announced on open; Return cancels; "history cleared" announcement fires.
11. Test: each announcement string == the corresponding visible string, verbatim.
