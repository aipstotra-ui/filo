# Design System

The visual foundations for [[00-Overview|AI File Organizer]]. Every mockup in `docs/mockups/` and every SwiftUI view should draw from this file. Brand in one line: **calm, trustworthy, native, private** — a quiet assistant that lives in the menu bar, never a mascot, never an ad.

## Principles

1. **Native first.** If macOS has a standard control, use it. SF Pro system font, standard control sizes, system accent color, vibrancy where macOS would use it (menus, menu bar).
2. **Glanceable.** Any state must be readable in under 2 seconds: one primary line, small secondary lines, one clear action.
3. **Honest.** No fake progress, no dark patterns, no pretending to have an answer ("No folder fits — leaving it in Downloads"). Errors are stated plainly and stay visible until resolved.
4. **Quiet.** Color is information, not decoration. Accent blue only for interactive/identity elements; amber and red only for real problems.

## Typography

System font stack (SwiftUI: default `Font` styles; HTML mockups: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif`).

| Role | Size / weight | SwiftUI equivalent | Used for |
|---|---|---|---|
| Body | 13 px regular | `.body` | menu rows, folder names, buttons, intro text |
| Body semibold | 13 px semibold | `.body.weight(.semibold)` | window title, empty-state title |
| Caption | 11 px regular | `.caption` | status lines, paths, destination line, hints, tab labels |
| Page title (mockups only) | 20 px bold | — | not part of the app |

Never larger than 13 px inside the app's own UI. No custom fonts, ever.

**Filenames truncate in the middle** (`.truncationMode(.middle)` / `NSLineBreakByTruncatingMiddle`), everywhere a filename is shown in the menu, the popup or a history row. The menu is 300 px and cannot grow; tail truncation would hide the extension, which is the one part that says what kind of file it is. Everything that is not a filename (status lines, folder names, reasons) truncates at the tail as usual. Added M6.

## Spacing & geometry

4 px base grid.

| Token | Value | Used for |
|---|---|---|
| space-xs | 4 px | line-to-line inside a row (SwiftUI `spacing: 2–4`) |
| space-s | 8–9 px | icon-to-text gap, row vertical padding |
| space-m | 12 px | row horizontal padding, gaps between grouped blocks |
| space-l | 20 px | settings pane padding |
| radius-row | 6 px | menu-item highlight, small icon buttons, push buttons |
| radius-box | 8–9 px | privacy box, inset list group, tab highlight |
| radius-panel | 12 px | menus, windows |
| hairline | 1 px `sep` | separators, list borders |

Standard sizes: menu width ≈ 300 px · settings window ≈ 620 px · icon button 24 × 24 px · folder list icon 26 × 21 px · menu destination folder icon 13 × 11 px.

## Color tokens

All colors are semantic; SwiftUI should map them to system colors (right column) so the user's accent-color and increased-contrast settings are respected automatically. Hex values are for HTML mockups only.

| Token | Light | Dark | SwiftUI |
|---|---|---|---|
| `accent` | `#007AFF` | `#0A84FF` | `Color.accentColor` |
| `label-1` (primary) | `rgba(0,0,0,.85)` | `rgba(255,255,255,.86)` | `.primary` |
| `label-2` (secondary) | `rgba(0,0,0,.50)` | `rgba(255,255,255,.55)` | `.secondary` |
| `label-3` (tertiary) | `rgba(0,0,0,.28)` | `rgba(255,255,255,.28)` | `.tertiary` |
| `sep` (hairline) | `rgba(0,0,0,.08)` | `rgba(255,255,255,.10)` | `Divider` default |
| `warning-text` | `#C93400` | `#FFB340` | **`.systemOrange`** — semantic, never a hex |
| `error-text` | `#D70015` | `#FF6961` | **`.systemRed`** — semantic, never a hex |
| `window-bg` | `#F5F4F5` | `#2A2A2C` | window background material |
| `content-bg` (inset group) | `#FFFFFF` | `rgba(255,255,255,.055)` | `.quaternary` fill / grouped list |
| `menu-bg` (vibrancy) | `rgba(248,248,248,.80)` + blur | `rgba(44,44,48,.72)` + blur | menu material (free with `MenuBarExtra`) |
| `privacy-bg` | `rgba(0,122,255,.06)` | `rgba(10,132,255,.13)` | `accent.opacity(...)` |
| folder icon | gradient `#74B9FF → #3E8EF0` | same | system folder blue / SF Symbol `folder.fill` tinted |

Rules: amber and red appear **only** in status text, never as fills or badges. The privacy box is the only tinted container in the app.

**Status colours must be the semantic system colours** (`.systemRed` / `.systemOrange`), never the hex values above — those exist only so the HTML mockups render in a browser. macOS re-derives system colours under *Increase Contrast*; a hex does not. Known and accepted consequence (M6): Apple's readable light-mode orange is a deep burnt one that sits visually close to red at 11 px. Dark mode separates cleanly. This is tolerable **only** because colour never carries meaning alone — see the next rule.

**Contrast: outcome vs diagnostic** (M6). `.secondary` measures ~3.9:1 at caption sizes against a 4.5:1 bar, on both window and menu backgrounds. Rather than darken everything (which flattens the hierarchy that makes a glance work), split by what the line is *for*:

- **`.primary`** — any line reporting what happened to a file or needed to decide: `Moved to …`, `Undone …`, `Suggested: …`, `Moving…`, and the instruction line under an inline error.
- **`.secondary`** — lines describing only *how* the app read the file or where it came from: `PDF text · 132 words`, `Reading…`, `was {originalName}`, timestamps, section headers, empty-state hints.

**Colour is never the only signal.** Every amber and red state is a full sentence that means the same thing with the colour removed. Verify with Differentiate Without Color.

## Materials

- Menus and the menu bar: translucent + background blur (`blur(30px) saturate(180%)` in mockups; comes free with native `MenuBarExtra`/`NSMenu`).
- Windows: opaque standard window background. No translucency inside panes.
- Shadows: system defaults; mockups approximate with soft large-radius shadows plus a 0.5 px edge line.

## Motion

- Fades and short slides only, **≤ 250 ms**, ease-out. No bouncing, no springs with overshoot.
- Indeterminate spinners are the one allowed looping animation (standard small `ProgressView`, ~0.8 s rotation, 11 px in caption lines).
- State changes inside a row (e.g. "Scanning…" → "Indexed · 34 files, 3 read") swap with a plain crossfade or none at all.
- **Spinners are delayed ~200 ms** (M6). Work that finishes faster than that must show no spinner at all — a spinner that flashes on and off reads as a glitch, i.e. as failure. The *disabling* of controls is immediate; only the visible spinner waits.
- **A surface may grow but must not jump** (M6). When an inline error adds lines, the surface grows downward only, ≤ 200 ms ease-out, anchored at its top edge so nothing already on screen moves under the cursor. A surface never shrinks or resizes at the moment of a click.

## Voice & copy

- Short, factual, sentence case. **No exclamation marks.** No mascot language.
- Em dash for honest qualifiers: "Can't access — click to learn why", "No folder fits — leaving it in Downloads".
- Middle dot `·` separates facts on one line: "Indexed · 34 files, 3 read", "PDF text · 214 words".
- Ellipsis `…` marks both ongoing work ("Scanning…") and actions that open something ("Add Folder…", "Choose folders…") — macOS convention.
- The privacy sentence is fixed copy, always shown in full where folder data is collected: *"To learn what a folder holds, the app reads its file names and briefly looks inside a few files. Nothing leaves your Mac."* (Founder decision 2026-07-18: indexing reads file names plus a small on-device text sample from ~3 files per folder, so the earlier "names only" wording would be untrue.)

### Canonical strings (M4)

Keep these exact — they are part of the design:

| Context | String |
|---|---|
| Folder row, indexed | `Indexed · {N} files, {M} read` |
| Folder row, scanning | `Scanning…` |
| Folder row, no permission | `Can't access — click to learn why` |
| Folder row, gone | `Folder missing` |
| Menu, destination line | `→ {Folder name}` (arrow secondary, folder icon + name primary) |
| Menu, no match | `No folder fits — leaving it in Downloads` |
| Menu, zero folders hint | `No target folders yet — destinations appear once you choose folders` |
| Menu item | `Choose folders…` |
| Settings intro | `The app can suggest one of these folders as a destination for a new download. It only ever suggests — nothing is moved.` |
| Empty-state title | `No target folders yet` |

### Canonical strings (M6)

| Context | String |
|---|---|
| Popup / menu row, move in flight | `Moving…` |
| Popup, failed — no permission | `Couldn't move it into {Folder} — the app isn't allowed to write there.` |
| Popup, failed — no permission, 2nd line | `Give access in System Settings, then press Accept again.` |
| Popup, failed — source gone | `Couldn't move it — that file isn't in Downloads any more.` |
| Popup, failed — source gone, 2nd line | `It may have been moved or deleted. Nothing was changed.` |
| ⚠️ *The nine `Menu, history…` rows below are* ***superseded*** | *see the note under this table* |
| Menu, history header | `Recent` |
| Menu, history — moved | `Moved to {Folder}` (folder icon + name, `Moved to` secondary) |
| Menu, history — renamed in place | `Renamed in Downloads — {Folder} wasn't available` (amber) |
| Menu, history — undone | `Undone — back in Downloads` |
| Menu, history — undone under a new name | `Undone — back in Downloads as {name}` |
| Menu, history — failed | `Couldn't move — no access to {Folder}` (red) |
| Menu, history — unknown | `Result unknown — the app stopped mid-move` (amber) + `Check Downloads and {Folder}` |
| Menu, history — undo failed | `Can't undo — that file isn't where the app left it` (red; Undo stays offered) |
| Menu, history empty | `No moves yet — accepted files appear here` |
| Menu, action items | `Undo` · `Accept` |
| Settings, group title | `Move history` |
| Settings, explanation | `The app remembers your last 200 moves so you can undo them. Clearing the history means those moves can no longer be undone. Your files stay where they are.` |
| Settings, button + count | `Clear History…` · `{N} moves stored` |
| Confirm sheet | `Clear move history?` / `Your files stay where they are. The record of your last 200 moves is deleted, so those moves can no longer be undone.` / `Cancel` (default) · `Clear History` |

Rule behind these: a failure line names **what happened** and **the specific folder or file**, then optionally **what the user can do**. "Unknown" is a legitimate answer and is stated as one — the app never guesses, and never offers Undo for a move it cannot prove happened.

> ⚠️ **The `Menu, history…` rows are superseded** (founder decision 6, 2026-07-28).
> There is no history section in the menu: the dropdown keeps its `.menu` style and
> history + Undo live in the Settings window (`UI/HistoryPane.swift`). Those rows
> describe a design that was never built. **The live wording is in
> `History/HistoryRowPresentation.swift`** and is unit-tested rather than eyeballed.
> They stay here until the built strings are folded back into this table.

## Component anatomy

**Menu file row** (extends M1–M3 row): line 1 filename + size (body, primary) · line 2 extraction status (caption, secondary) · line 3 AI suggestion (caption, secondary) · line 4 destination `→ [folder icon] Name` (caption; arrow secondary, name primary) **or** the no-match line (caption, secondary). Destination is the only line carrying the folder icon — that alone makes it findable in a glance.

**Settings folder row**: folder icon · name (body) with dimmed path inline (caption, tertiary) · status line below (caption; secondary / amber / red) · trailing quiet icon buttons Rescan and Remove (24 px, tertiary, hover fill only).

**Privacy box**: shield icon (accent) + fixed sentence, `privacy-bg` fill, radius-box. Sits above the folder list, never collapsible.

### Added in M6

**In-flight (busy) state.** While an action the user started is still running: every control on that surface disables in place (0.4 opacity, no hover), any editable field stops accepting input but stays fully readable (text drops to `label-2`, affordances like the pencil fade out), any auto-dismiss timer is cancelled, and a single caption — `[spinner] Doing…` — appears at the leading edge of the footer. Layout must not shift: same surface size, same button widths, same line positions. No progress bars and no percentages for work whose duration we cannot honestly predict.

**Inline error.** A failure is reported *inside the surface that owns the action*, never in a system alert and never with a sound. The surface stays open until the user resolves or dismisses it, and auto-dismiss stays off. Anatomy: one caption line in `error-text` saying what happened and naming the specific object ("…into Invoices"), then at most one `label-2` caption saying what the user can do — with the actionable words underlined in the M4 "click to learn why" style when they open something. No banner, no fill, no icon, no warning triangle; red appears on the sentence only. The primary action stays enabled so the user can correct and retry. Never surface an error code or a POSIX name.

**Destructive confirm.** Standard sheet alert from the window title bar. Body text states what is *not* affected first ("Your files stay where they are"), then what is lost. **Cancel is the default button** — blue, rightmost, bound to Return — so a stray keystroke is harmless. The button that opens it carries an ellipsis (`Clear History…`); the button inside the sheet does not (`Clear History`). Used only where the loss cannot be undone.

> ⚠️ **The two blocks below are SUPERSEDED** (founder decision 6, 2026-07-28) and
> describe a menu design that was never built. Kept for the reasoning only. What
> shipped: the dropdown is unchanged except that a settled file row is now a
> `Button` that reopens that file's popup, and all history/Undo lives in
> Settings › History.

**Menu section header.** Small `label-2` caption (11 px) above a group of menu rows, e.g. `Recent`. Shown even when the group is empty, so the feature stays discoverable; the empty group then holds one `label-2` caption row.

**Menu row with an action.** A macOS menu row is a single click target and cannot hold a trailing button, so an action belonging to a row is **its own menu item directly beneath it, indented** (`Undo`, `Accept`). Informational rows are disabled and never highlight; only action items take the accent-blue hover. An action item is shown only when the action is genuinely possible — never disabled-as-decoration, never offered for something the app cannot honestly do. While that row's action is in flight the item becomes a disabled `[spinner] Moving…`. Because clicking any menu item closes the menu, the *result* of a menu action is reported by the row's own outcome line on the next open, not by live feedback.

### History pane (what was actually built in M6)

**History row.** Three lines inside an inset list in Settings › History: line 1
the filename the file has **now** (body, primary, never pre-truncated — VoiceOver
must read the whole name); line 2 the outcome sentence (`Moved to {Folder}`,
`Undone — back in Downloads`, or the honest failure/unknown line); line 3 the
`was …` detail (caption, secondary). Rows are grouped under day headers
(`Today`, `Yesterday`, then weekday + date). **Undo appears only on rows whose
state proves it is safe** — never greyed-out-as-decoration; a row that cannot be
undone says so in words. The wording lives in
`History/HistoryRowPresentation.swift` and is unit-tested, not eyeballed.

## Mockups

- `docs/mockups/m4-folders-settings.html` — M4: Settings › Folders pane (populated + empty state) and menu-dropdown destination lines.
- `docs/mockups/m5-popup.html` — M5: the suggestion popup — hero, no-destination, editing, empty-name and post-Accept states.
- `docs/mockups/m6-history-undo.html` — M6 (revision 3, founder-approved 2026-07-28): popup "Moving…" and "Couldn't move" states, **Settings › History** (all six row states + empty), per-row Undo, and Clear History with its confirm sheet. Revisions 1–2 drew the history in the menu dropdown; that design was dropped by founder decision 6.

All three carry a Light/Dark toggle at the top. Approved mockups are the reference the built SwiftUI is checked against (pipeline step 7).
