# M6 — Log & undo: build history (ARCHIVE)

> ## ⚠️ Do not use this file for current status
>
> **This is a build log from 2026-07-28, kept for the reasoning trail only.**
> It was appended to across several sessions without the top being reconciled,
> so it **contradicts itself** and parts of it are now flatly wrong.
>
> Two examples, both dangerous if believed:
> - It says below that *"the shipped app still moves ZERO files"*. **False.**
>   `App.swift` injects the real `MoveCoordinator` — the app moves real files on
>   Accept. The same file says so correctly 66 lines further down.
> - It reports `swift test` green at 209/209 and again at 231/231. **Neither
>   holds.** The suite does not currently finish at all.
>
> **For current status use [[open-work]] (what's open) and [[milestones]] (what
> shipped).** Everything below is history.

**Original header, preserved as written on 2026-07-28 — inaccurate, see above:**

~~Read this first, then `m6-review-findings.md`.~~

~~**Tree state:** `swift build` clean (debug + release), **`swift test` 209/209 green**, nothing half-applied. Nothing is committed yet — all M6 work is uncommitted in the working tree.~~

**The fix round is DONE.** C1, C2, C3 and every assigned major/minor are fixed, plus M7 (the watcher claim) and M6 (the popup failure route). *(Accurate — this round did complete.)*

~~**The shipped app still moves ZERO files.** `Sources/FileOrganizer/UI/App.swift:51` injects `NoMoveAccepting`. Swapping in `MoveCoordinator` is a one-line change, and it is **deliberately not done**.~~ — **superseded the same day by step 10 below; the coordinator IS wired and the app moves real files.**

---

## The M6 documents — corrected 2026-07-30

| File | What it is | Still live? |
|---|---|---|
| `m6-final-review-findings.md` | **The work list.** Round 2, seven reviewers. Full detail — file, line, failing sequence, fix direction — for everything summarised in [[open-work]]. | ✅ **yes** |
| `m6-accessibility-spec.md` | Build the UI to this; audit against §L. The A2–A8 fixes are graded against it. | ✅ **yes** |
| `m6-review-findings.md` | Round 1's findings. ~~"The work list"~~ — **superseded**; every item here was fixed and mutation-verified. History only. | ❌ closed |
| `m6-working-plan.md` | The approved plan and the syscall-probe corrections. Plan executed; decisions now live in [[decisions]], syscall findings in [[History-Undo]]. | ❌ closed |
| `docs/mockups/m6-history-undo.html` | ~~stale, needs revision, not yet founder-approved~~ — **revised and founder-approved 2026-07-28.** | ✅ reference |

## The locked founder decisions
1. **Fail closed** — if the history row can't be written, do not move the file.
2. **Destination folder gone or unusable at move time → rename in place in Downloads**, and say so honestly. (Scope narrowed by decision 7: this covers *gone*, not *blocked*.)
3. **Retention** — DB keeps 200, plus a "Clear history" button in Settings. (The "menu shows last 5" half is superseded by decision 6 — Settings shows the history now.)
4. ~~**Dropdown switches to `.menuBarExtraStyle(.window)`**~~ — **SUPERSEDED by decision 6.**
5. **During a move, Dismiss stays enabled and becomes "Hide"** — hides the panel, the move continues, the result lands in history. Accept is the only disabled control. **Esc must always be answered, never inert.**
6. **(2026-07-28) The dropdown keeps its current `.menu` style; history and Undo move to the Settings window.** The founder was offered the panel from decision 4 and chose the conservative option — nothing about today's dropdown changes visually. Settings is a real window, so the a11y block that forced decision 4 (plain `Text` rows become *disabled* `NSMenuItem`s, unreachable by keyboard and VoiceOver) simply does not apply there.
7. **(2026-07-28) A destination folder blocked by macOS privacy (TCC) is a failure, not a fallback.** The popup says so and offers an "Open System Settings" button; the file is neither moved nor renamed. Distinct from decision 2 because a TCC denial is a one-time fixable permission problem, and renaming in Downloads would hide it. Closes finding **M24**.

### Step 9 as re-scoped by decision 6
- **9a — `UI/HistoryPane.swift` (new), in the Settings window.** The history list, per-row **Undo** on `moved` rows, honest one-liners for `failed`/`undone`/`unknown` (no Undo offered on `unknown`), and the **Clear history** button (absorbs step 12's Settings work).
- **9b — `UI/MenuContentView.swift`: a menu row with a settled suggestion becomes a `Button` that re-opens that file's popup.** This satisfies "overflow (menu-only) files can be acted on". A `Button` in `.menu` style is an *enabled* `NSMenuItem` — keyboard-navigable and VoiceOver-readable, unlike a text row. Routing through the popup reuses the entire approved Accept path, so the menu never needs to render an outcome line.

---

## DONE — built, tested, and verified

**Plan steps 1–5, 7, 8, and the non-visual half of step 6.** All of `Sources/FileOrganizer/History/` is implemented: `FileMover`, `MoveHistoryStore`, `MoveDestinationResolver`, `MoveCoordinator`, `MoveRecord`. Plus the async `SuggestionAccepting` seam, `PopupController`'s in-flight state machine (close-only-on-success, hide≠cancel, auto-dismiss cancelled mid-move), and the watcher claim API.

**Verified by deliberate mutation** (broke the code, confirmed the test failed, restored it) — do not assume other tests bite without checking:
- The stale-Accept identity guard. **It originally did NOT bite** — the assertions ran before the async work landed, so it passed with the guard deleted. Fixed by awaiting after the stale fire.
- Close-only-on-success. Confirmed it catches the close-as-success bug.

**Release-hygiene fixes done this session (mine, verified):**
- Six ungated `print`s that leaked filenames and full paths into release builds are now behind `#if DEBUG` via a house-style `devLog` in `AI/AIEngine.swift` (file-scope) and `Watcher/DownloadsWatcher.swift`. **Verified empirically against the release binary** — `strings .build/release/FileOrganizer` finds none of `detected:` / `watching:` / `ai: generation` / `ai: embedding` / `DownloadsWatcher:`, while the debug binary still contains them. This closes finding **M11**.
- `FILE_ORGANIZER_WATCH_DIR` is now **ignored entirely in release builds**, and in debug must resolve inside the user's home (`DownloadsWatcher.defaultFolder()` + `isInsideHome`). Closes finding **M15**.

---

## Where things stand (2026-07-28, evening)

**Done and mutation-verified this session** — each fix was checked by deliberately breaking the code and confirming the test failed, then restoring:

| Finding | What it was | Verified by breaking |
|---|---|---|
| C1 | A verified cross-volume copy was deleted when the source delete failed → file in neither place | `FaultyCopier.failRemove` |
| C2 | Reconcile adopted a stranger's file by NAME and offered Undo on it | identity check removed → `reconcileRefusesToAdoptAStrangersFile` failed |
| C3 | `errno` read after `withCString` unwound → a failed move reported as success | errno now captured inside the closure |
| M9 | "Clear history" left ~445 readable plaintext copies | `secure_delete=OFF` + no `VACUUM` → raw-bytes test failed |
| M16 | `pruneBeyond(0)` silently wiped the whole table | floor removed → test failed |
| M17 | `clearAll` mid-move destroyed a running move's row | in-flight guard removed → test failed |
| M7 | Claim box raced, and an unused collision rung could swallow a real download for 5 minutes | four separate mutations, all bit |
| M6 | The failure channel had no route to the screen | panel push removed → test failed |

Also fixed: **M4, M8, M10, M12 (store half), M13, M14, M18, M22, M24, M25, M26, M27, M30, M32, M33**. **M11 and M15** were closed earlier.

**M7's shape:** claims moved out of the watcher into `Watcher/AppCreatedFileClaims.swift` — lock-guarded, scoped to the watched directory, **spent on first match**, and grouped per move so the rungs a move did not use are retired the instant it settles rather than lingering. `FileMover.move` gained `claimGroup:`; `MoveCoordinator` releases the group in both the success and failure paths.

**M6's shape:** `PanelPresenting` gained `update(activity:)`, `PopupController.activity` pushes every change through it, and `SuggestionPanelController` holds a `PopupViewState` so the panel re-renders in place (recreating the view would throw away the user's typed name). The popup now renders "Moving…", the "Hide" label, and the failure line with Accept re-enabled as "Try again" — and announces each to VoiceOver, which would otherwise never read a line that appeared without a keystroke.

### Done — the UI, built to the approved mockup (founder approved 2026-07-28)
- **Step 9a — `UI/HistoryPane.swift` + `History/HistoryRowPresentation.swift`.** The History tab (third, after General and Folders), the three-line row shape from the mockup, per-row Undo on `moved` rows only, honest sentences for failed/undone/unknown, day headers, Clear History behind a confirmation, the empty state, and an honest banner when the history database itself is unhealthy. The *wording* is pure and unit-tested (`HistoryRowPresentationTests`) rather than eyeballed — being misleading here is the exact failure this milestone exists to prevent.
- **Step 9b — `UI/MenuContentView.swift` + `PopupController.reopen(fileEventID:)`.** A settled menu row is now a `Button` that reopens that file's popup, which is how menu-only overflow files can be acted on (M5 hand-off #3). Refused while that file's move is running, so a second click cannot start a second move.
- **Step 10 — `App.swift` wired.** `MoveCoordinator` replaces `NoMoveAccepting`; `FileMover(announceCandidate:)` is bound to `watcher.appCreatedClaims`; `coordinator.start()` runs the launch reconcile and prune. **The app now moves real files on Accept.** If `history.db` cannot be opened the coordinator is nil and the app degrades to M5 behaviour — suggestions appear, nothing moves — with Settings › History saying so (founder decision 1).

**Verified:** `swift build` clean debug + release, **`swift test` 231/231 green**, release binary contains none of the dev log strings, no networking API anywhere in `Sources/`, zero package dependencies, `history.db` schema has no content column. A launch smoke test against a sandbox folder ran 12 s with no crash and created `history.db` at 0600 inside a 0700 directory.

### Still to do
1. Closing pipeline: `code-simplifier` → `ui-designer` verify + `a11y-architect` audit against `m6-accessibility-spec.md` §L → re-run the reviewers whose code changed → `docs-keeper` → commit.
2. **Founder live QA** — nobody has yet accepted a suggestion in the running app and watched a real file move and undo. Every layer is covered by tests against real files and a real database, but the click-through is a human check.

### Known divergences from the mockup, deliberate
- **An undone row cannot name the folder-side filename it had.** `markUndone` overwrites `final_name` with the restored name, so "had been *2026-05 Chase statement.pdf* in Invoices" loses the italic part; the row says "had been in Invoices". Fixing it properly means a new column and a schema migration — worth doing, not worth doing inside this milestone.
- **No per-row "Can't undo — that file isn't where the app left it" on render.** Detecting it needs a disk probe per row on every redraw, which is exactly the main-thread I/O M20 warns about. Instead the Undo is attempted and the honest failure appears on that row.

---

## Historical — the fix round as it was briefed (now complete)

### 1. The fix round (START HERE)
A `swift-builder` was dispatched against `docs/milestone-work/m6/m6-review-findings.md` and **stopped before making any edit** — zero work landed. Re-dispatch it with the same scope:

> Criticals **C1, C2, C3**, then majors **M4, M8, M9, M10, M13, M14, M16, M17, M18**, plus the store half of **M12**. Minors if they fall out naturally: M25, M26, M27, M30, M32, M33. Also fix the test defects listed in the findings' "Test gaps" section.
>
> Out of scope for that pass: `DownloadsWatcher.swift`, `AIEngine.swift` (already done above), and everything in plan steps 9–12.

**The three criticals, in one line each:**
- **C1** — a *verified* cross-volume copy is deleted when the source delete fails → **the file exists in neither place**. Also leaves a stray duplicate plus a lying message for a Finder-locked file.
- **C2** — launch reconcile can adopt a **stranger's file** as ours and offer Undo on it, which then relocates a file the app never touched. Found independently by three reviewers.
- **C3** — `errno` is read after `withCString` unwinds; if it reads back 0, a failed move is reported as success.

**M11 and M15 in the findings doc are already fixed — skip them.**

### 2. Still outstanding after the fix round
- **M5, M6** — the failure channel has **no route to the user's eyes**. `PopupActivity` has zero readers, `PopupController` is not `ObservableObject`, and `PanelPresenting` has no way to update a panel already on screen. **Hard prerequisite before wiring.**
- **M7** — the watcher claim. Two real problems: (a) wiring it as the obvious one-liner is an **unsynchronized dictionary mutation** from a detached task (the compiler won't catch it — the package is Swift 5 language mode, not Swift 6 as the docs claim); (b) claims are name-only, unscoped, and not consumed on use, so an unused collision rung can **silently swallow a genuine download for 5 minutes**. Note `DownloadsWatcherClaimTests.onlyTheUsedRungIsAdopted` currently pins the *wrong* expectation and must change.
- **M19–M24, M28–M40** — medium/minor, see the findings doc.
- **Plan steps 9–12** — the history UI, per-row Accept, Settings "Clear history", and the `App.swift` wiring.

### 3. Mockup revision (was interrupted mid-fix)
`docs/mockups/m6-history-undo.html` predates founder decisions 4 and 5. Needs: the panel-style dropdown redrawn (sections 3 and 4), "Hide" during a move, the failed popup drawn at its true taller height, "System Settings" as a real button, no spinner in the menu row, semantic `.systemRed`/`.systemOrange` instead of hexes, and a recommendation on the `.secondary` status-caption contrast (~3.9:1 against a 4.5:1 bar). It also needs to resolve the double-appearance of a successful move. The designer's last note: the slow-case caption wraps to two lines and makes the popup footer jump — fix that too.

---

## Blocking gates — do not skip
1. **Founder approval of the revised mockup** — the only mid-pipeline founder touchpoint. Steps 9–12 must not be built before it.
2. ~~**Do not wire `MoveCoordinator` into `App.swift`**~~ — **DONE, gate passed.** C1, C2, C3, M6, M7 and M14 were all fixed first, then the coordinator was wired. The app has been moving real files on Accept since 2026-07-28.

## Still owed by the founder (from earlier milestones)
- **M4** — the real-folder acceptance test with their own Screenshots/Invoices folders.
- **M5** — the live-VoiceOver check. **This matters more now:** M6's design leans on the history list being readable precisely *because* announcements from a non-key corner panel are unreliable.

## Remaining pipeline steps after the fixes
`code-simplifier` → `ui-designer` verify + `a11y-architect` audit against `m6-accessibility-spec.md` §L → `docs-keeper` → commit.

**~~`docs/product/milestones.md` is stale~~ — fixed 2026-07-30.** (Original note:) `docs/product/milestones.md` was stale — it still describes `MoveHistoryStore`/`MoveDestinationResolver`/`MoveCoordinator` as signature-only stubs with 48 red tests. They are implemented and green. `docs/product/modules/History-Undo.md` is still the two-line pre-M6 stub. `docs/product/decisions.md` needs entries for the separate `history.db`, its journal mode, and why its corruption policy differs from `index.db`'s.

## One thing worth carrying forward
Three separate tests this milestone **passed against deliberately broken code** — the stale-callback guard, and `concurrentUndosHaveExactlyOneWinner` (which cannot observe concurrency at all: both `async let` calls enter the same actor with no suspension point). A green suite is not evidence here. Mutation-check any test that guards user data before trusting it.
