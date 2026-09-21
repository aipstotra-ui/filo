# M6 — Log & undo: approved plan (founder decisions locked 2026-07-27)

> ## ⚠️ CLOSED — history only
>
> The plan for M6, **fully executed**. The founder decisions it locked now
> live in [[decisions]] (all seven, including the two added later); the
> syscall-probe corrections live in [[History-Undo]].
>
> **Current status lives in [[open-work]] (what's open) and [[milestones]] (what
> shipped).** Nothing durable exists only in this file — it can be deleted once
> M6 commits. Kept for the reasoning trail.


## Founder decisions (LOCKED — do not re-litigate)
1. **Fail closed on history-write failure.** If the intent row can't be written, DO NOT move the file. Return a failure; popup stays open with an honest message.
2. **Destination folder gone at move time → rename in place in Downloads**, and say so honestly in the menu/history ("folder wasn't available"). Do not stop-and-ask.
3. **Retention:** menu shows the **last 5** actions with Undo; DB keeps the last **200** (undo never expires inside that window); **"Clear history" button in Settings**.

## Founder decisions round 2 (LOCKED 2026-07-27, after the a11y review blocked the mockup)
4. ~~**The menu-bar dropdown switches from `.menu` style to `.menuBarExtraStyle(.window)`.**~~ **SUPERSEDED by decision 6 (2026-07-28).** Kept for the record: the a11y block was real — in `.menu` style a plain `Text` row is a *disabled* `NSMenuItem`, skipped by NSMenu keyboard navigation and unreadable by VoiceOver, so history rows shown as text would be unreachable. Decision 6 solves the same problem by moving history somewhere that has no such constraint.
5. **During a move the popup's Dismiss stays ENABLED and becomes "Hide"** — clicking it (or Esc) hides the panel, the move continues, the result appears in the history list. Accept is disabled during the move. Esc must ALWAYS be answered — never inert. This supersedes any "disable both buttons" text below.

## Founder decisions round 3 (LOCKED 2026-07-28)
6. **The menu-bar dropdown keeps its current `.menu` style — history and Undo move to the Settings window instead.** Replaces decision 4. The founder was offered the panel and chose the conservative option: nothing about today's dropdown changes visually. Settings is a real window, so keyboard navigation, VoiceOver, and multi-line honest status text all work there with no `NSMenuItem` constraints. **Consequences:** (a) no "Recent" section is added to the menu; (b) retention wording in decision 3 becomes *Settings shows the retained history, DB keeps 200*; (c) the menu no longer needs to render per-row outcome lines, which would have been unreadable disabled items anyway.
7. **A destination folder blocked by macOS privacy (TCC) is a failure, not a fallback.** The popup says the folder is blocked and offers a button to open System Settings; the file is not moved and not renamed. This does **not** contradict decision 2: decision 2 covers a folder that is *gone or unusable* (deleted, unmounted, no longer in the index), where there is nothing the user can do. A TCC denial is a one-time, fixable permission problem, and silently renaming in Downloads would hide it. Closes finding **M24** by making both paths agree on "blocked ⇒ fail honestly".

## Step 9 is re-scoped by decision 6 (2026-07-28)
The original step 9 (history section + per-row Accept + per-row outcome lines in the menu) is replaced by:
- **9a — `UI/HistoryPane.swift` (new), shown in the Settings window.** The retained history: state, original name → final name, destination folder, timestamp; an **Undo** button on each `moved` row; honest one-liners for `failed` / `unknown` / `undone`; a **Clear history** button (this absorbs step 12's Settings work).
- **9b — `UI/MenuContentView.swift`: each menu row with a settled suggestion becomes a `Button` that re-opens that file's popup.** This is how "overflow (menu-only) files can be acted on" is satisfied. A `Button` in `.menu` style renders as an *enabled* `NSMenuItem`, so unlike a text row it is keyboard-navigable and VoiceOver-readable. Routing through the existing popup — rather than accepting straight from the menu — reuses the whole approved Accept path (edit the name, "Moving…", the failure message, the a11y spec) and means the menu never has to render an outcome line. The menu closing on click is then correct behaviour, not a compromise: the popup takes over.

## Success criteria
- History of accepted moves in the menu; one-click undo restores file **and** original name.
- Seam has a failure channel; popup closes **only** on success — never close-as-success.
- Mover re-validates `sourceURL` and `destinationFolderID` fresh at move time; falls back to rename-in-place if the folder is gone; persists the **resolved destination path**, not the store id.
- Overflow (menu-only) files can be acted on.
- Never overwrites an existing file; atomic where the platform allows.
- `swift test` green (hard gate); `swift build` debug + release clean; zero network.

## CORRECTIONS from tdd-guide's live syscall probe (Darwin 25.5, APFS) — these OVERRIDE the plan text below
1. **`renamex_np(RENAME_EXCL)` returns 0 for a self-rename, NOT `EEXIST`.** The short-circuit is still mandatory, but for a different reason: the syscall would silently "succeed" and the coordinator would write an undoable history row for a move that never happened. Pinned by `selfRenameIsANoOp`, which also asserts the renamer was never called.
2. **A pure case change (`report.pdf` → `Report.pdf`) and an NFD→NFC change both return 0** — the kernel treats them as same-file renames. So the mover must **NOT** pre-check occupancy with `FileManager.fileExists`, which is case- and normalization-insensitive on APFS: doing so would dedupe a legitimate case-only rename into `Report 2.pdf`. Pinned by `caseOnlyRenameIsNotACollision` and `normalizationOnlyRenameIsNotACollision`.

## Storage decision (firm)
**A separate SQLite database `history.db`** in the same app-support dir, owned by a new actor `MoveHistoryStore` modelled line-for-line on `Sources/FileOrganizer/Index/FolderIndexStore.swift`.
- The index DB has a *corrupt → move aside → rebuild fresh* policy. History is the ONLY record of what we did to the user's files — irreplaceable. It must not live in a file with a "wipe and start fresh" recovery path.
- Not an append-only file: undo is a *mutation* and needs a state-guarded atomic `UPDATE ... WHERE state = 'moved'` to defeat double-undo.
- Corrupt history → move aside intact **and surface it honestly**; never silently reset.
- **Write ordering: two-phase, intent-first.** Write `inProgress` row → move → `UPDATE` to `moved` with the resolved final path. A launch-time reconcile pass resolves stranded `inProgress` rows by probing disk (source gone + target present → `moved`; source present + target absent → `failed`; else → `unknown`, shown honestly, **no undo offered**).

## Steps (1–8 = the file-touching core, no new UI; 9–12 = UI, behind the mockup gate)

| # | File | Action |
|---|---|---|
| 1 | `Tests/FileOrganizerTests/FileMoverTests.swift` (new) | Full failing suite for the move primitive (edge cases below) |
| 2 | `Sources/FileOrganizer/History/FileMover.swift` (new) | The primitive: `renamex_np(RENAME_EXCL)` (atomic **and** no-clobber, no TOCTOU) → on `EEXIST` retry Finder-style " 2", " 3"… (bounded ~50) → on `EXDEV` fall back to `FileManager.moveItem` (also never overwrites; copies then deletes so the source survives a failed copy). Typed `throws(MoveError)`. Trims names to a 255-**byte** UTF-8 budget. Not main-actor. **No bare `rename(2)`, no `replaceItem`, no remove-then-move — anywhere.** |
| 3 | `Sources/FileOrganizer/History/MoveRecord.swift` (new) | Value types: `MoveRecord` (id, fileEventID, original dir + name, final dir + name, destination-folder display name, state, timestamps, fallback reason), `MoveState` enum (`inProgress`/`moved`/`undone`/`failed`/`unknown`), `MoveError`, `UndoError`, `AcceptOutcome`. All `Sendable`. |
| 4 | `Tests/.../MoveHistoryStoreTests.swift` + `Sources/FileOrganizer/History/MoveHistoryStore.swift` (new) | Actor, raw `SQLite3`, own `history.db`, mirroring `FolderIndexStore`: WAL, every value bound, `user_version`, `0600`/`0700`, corrupt → move aside + report. API: `recordIntent`, `finalize`, `markFailed`, `markUndone` (state-guarded **in the statement** so a double-undo can't win a race), `recent(limit:)`, `pruneBeyond(200)`, `reconcileInProgress`, `clearAll`. |
| 5 | `Tests/.../MoveDestinationResolverTests.swift` + `Sources/FileOrganizer/History/MoveDestinationResolver.swift` (new); `Index/FolderRegistry.swift` (extension only) | Declares a small `DestinationResolving` port in `History/`; `FolderRegistry` conforms in an extension (no behavior change). At move time: re-stat source (must exist, be a regular file); re-resolve `destinationFolderID` → live URL through the registry (follows the bookmark); require directory + writable + **display name still matches what the popup showed** (a rebuilt index resets `AUTOINCREMENT`, so id 3 can be a different folder). Any failure → fall back to rename-in-place, with a typed reason (founder decision 2). Source missing → hard fail, no fallback. |
| 6 | `UI/SuggestionAccepting.swift`, `UI/PopupController.swift`, `UI/PopupContentView.swift`, `Tests/.../PopupControllerTests.swift` | Hand-off #1. Seam becomes `func accept(_:) async -> AcceptOutcome`. `PopupController` gains an in-flight state: Accept/Dismiss disabled, **auto-dismiss cancelled**, no next popup presented, popup shows "Moving…". `.moved` → close + advance. `.failed` → **stay open**, show the honest error, re-enable Accept so the user can edit and retry. Keep `NoMoveAccepting` as the test double (update its comment; it still pins "the popup itself does no I/O"). The existing unconditional `finishCurrent()` is exactly the close-as-success bug. |
| 7 | `Tests/.../MoveCoordinatorTests.swift` + `Sources/FileOrganizer/History/MoveCoordinator.swift` (new) | Implements `SuggestionAccepting`. Orchestrates resolve → `recordIntent` (**fail closed** per founder decision 1) → `FileMover` → `finalize`/`markFailed` → return `AcceptOutcome`. Also `undo(recordID:)`, `@Published recent: [MoveRecord]`, and a `fileEventID → outcome` map for the menu. Dedups concurrent accepts per `fileEventID`. |
| 8 | `Watcher/DownloadsWatcher.swift` + coordinator hook | **The watcher is non-recursive and diffs by NAME** (`DownloadsWatcher.swift:107-131`). A rename-in-place therefore looks like a brand-new file → the app re-suggests a name for the file it just renamed; undo (which restores a file *into* Downloads) does the same. Fix: `noteAppCreatedFile(named:)` pre-registers each candidate name into `knownNames` before each attempt; `knownNames.formIntersection(currentNames)` already self-cleans names that never appeared, so a failed move needs no rollback. |
| 9 | `UI/HistorySection.swift` (new), `UI/MenuContentView.swift` | **Mockup gate.** (a) "Recent" section: last 5 records, each with Undo (hidden/disabled when state ≠ `moved`), plus honest lines for `failed`/`unknown`/`undone`. (b) Hand-off #3: each menu row with a settled suggestion gets an **Accept** button using the AI's suggested name as-is (no in-menu editing — text fields in a `MenuBarExtra` menu are unreliable), disabled while a move is in flight or while that file's popup is showing. (c) Per-row outcome line ("Moved to Invoices" / "Couldn't move — …") since there is no popup to hold open. |
| 10 | `UI/App.swift` | Inject `MoveCoordinator` in place of `NoMoveAccepting`; hold it for the app lifetime; pass to `MenuContentView`. |
| 11 | `MoveCoordinator` + `MoveHistoryStore` | Launch reconcile of `inProgress` rows + retention prune to 200. |
| 12 | `UI/SettingsView.swift`; `Watcher/DownloadsWatcher.swift` | "Clear history" button (founder decision 3). Gate the watcher's two ungated `print`s (`:79`, `:205`) behind `#if DEBUG` — an M6 release-checklist item. |

## Edge cases — the test list

**`FileMover` (write these first):**
- Destination free → moved; source gone; destination present; bytes identical.
- **Destination occupied → never overwritten**; assert the existing file's bytes are unchanged; new file gets a deduped name.
- Destination name occupied by a **directory**.
- 50 consecutive collisions → bounded, typed failure, nothing clobbered.
- **Rename to the identical path** (same dir, same name — the common "leave in Downloads, name unchanged" case). `RENAME_EXCL` returns `EEXIST` for a self-rename — short-circuit to a success no-op **before** the syscall, and produce **no history row** (nothing to undo).
- Source missing at move time / source is a directory / source is a symlink (moves the link, target untouched).
- Destination directory missing → typed error, **never created by us**.
- Destination not writable; the macOS TCC case (unsandboxed write into `~/Documents`/`~/Desktop` can be blocked) → honest specific message, source untouched.
- Cross-volume (`EXDEV`) → fallback path; a simulated mid-copy failure must leave the source intact.
- Non-ASCII: emoji, CJK, combining accents (**NFC vs NFD** round-trip on APFS), RTL — moved, recorded, and found again by undo.
- Name of 100 emoji → exceeds 255 UTF-8 bytes → trimmed to a valid unique name, extension preserved. (`FilenameSanitizer` caps at 100 *grapheme clusters*, not bytes — this gap is real.)
- Case-insensitive volume: `invoice.pdf` exists, moving `Invoice.pdf` → must not clobber.

**Undo behaviour (locked):**
| Situation | Behaviour |
|---|---|
| File since moved/renamed by the user | Fail honestly: "Can't undo — that file isn't where the app left it." Never search the disk, never guess. Row stays `moved`, Undo stays offered. |
| File since deleted | Same message (we can't distinguish moved from deleted; pretending we can would be dishonest). |
| Destination folder gone | Same as above — the file isn't at the recorded path. |
| Original name now taken | **Never overwrite.** Restore as `report 2.pdf` and say so: "restored as report 2.pdf". |
| Undo of an already-undone entry | Guarded twice: button gone for state ≠ `moved`, and `markUndone` is state-guarded inside the statement. No redo in M6. |
| App relaunched between move and undo | Works — undo is purely path-based off the persisted resolved paths, never the store id. |
| Original directory (`~/Downloads`) missing | Typed failure. **Never recreate directories.** |

**Coordinator / controller:**
- Intent-row write fails → **no move performed**, failure returned, popup stays open.
- Move fails → row marked `failed`, popup stays open with the error, next popup NOT presented.
- Accept pressed twice / popup Accept and menu Accept race the same file → deduped; the loser fails honestly.
- Auto-dismiss must not fire mid-move.
- Relaunch with a stranded `inProgress` row → all four disk combinations reconcile correctly.
- Rename-in-place and undo-restore produce **no** new `FileEvent`.

## Risks, ranked by harm to a user's file
1. **Overwriting an existing file at the destination.** → `RENAME_EXCL`/`FileManager.moveItem` (both refuse) + collision loop + tests asserting pre-existing bytes unchanged.
2. **Undo overwriting a newer file of the same name in Downloads.** → undo uses the *identical* primitive; no "restore" shortcut path.
3. **Non-atomic cross-volume move interrupted** → file in neither place. Only copy-then-delete; delete only after a verified copy.
4. **Moving into the wrong folder** because `destinationFolderID` went stale (index rebuilt → `AUTOINCREMENT` reset). → fresh resolution + directory/writability + display-name cross-check; persist the resolved path, not the id.
5. **"History says it moved but it didn't."** → failure channel, close-only-on-success, intent-first write, launch reconciliation.
6. **Move succeeded but history write failed → an unundoable move.** → intent-first + fail-closed.
7. **Moving the wrong file** — `sourceURL` now points at a *different* file that reused the name. Partially mitigated (re-stat + regular-file check). Full inode-identity tracking is deliberately **out of M6**; record as a known limitation in `docs/product/modules/History-Undo.md`.
8. **Self-retrigger loop** — rename-in-place and undo-restore re-announce as new downloads (Step 8).
9. **Permission / TCC denial** writing into `~/Documents`/`~/Desktop` — likely on the founder's real Invoices folder on first run. Specific, actionable message; never a silent no-op.
10. **Name too long in bytes** → `ENAMETOOLONG` on names that passed the 100-character sanitizer.
11. **Double accept** (popup + menu row) → double move. → in-flight guard + per-`fileEventID` dedup.
12. **History DB corrupt** → undo history lost. Moved aside intact, surfaced honestly, never silently reset.
13. Extended attributes / quarantine flag: preserved by both `renamex_np` and `FileManager.moveItem`. Note only.
