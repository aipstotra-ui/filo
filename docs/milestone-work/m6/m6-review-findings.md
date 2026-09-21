# M6 review round — consolidated findings (2026-07-28)

> ## ⚠️ CLOSED — history only
>
> Round 1 of the M6 review. **Every finding here was fixed and
> mutation-verified**, and this round was superseded by
> `m6-final-review-findings.md` (round 2, seven reviewers). Do not work from
> this list — its items are done.
>
> **Current status lives in [[open-work]] (what's open) and [[milestones]] (what
> shipped).** Nothing durable exists only in this file — it can be deleted once
> M6 commits. Kept for the reasoning trail.


Five reviewers ran in parallel on the file-moving core: `code-critic`, `swift-reviewer`, `silent-failure-hunter`, `security-auditor`, `database-reviewer`.

**security-auditor verdict on the privacy promise: PASS** — zero network (full API sweep, zero package dependencies), and `history.db` holds filenames/paths/folder names only: no content, no summaries, no snippets, no embeddings, no BLOB column at all.

**Milestone verdict: BLOCK.** Three criticals, and the milestone's own release-checklist item is still open.

Where three reviewers converged independently on the same bug (C2), it is certain, not speculative.

---

## CRITICAL — fix before anything else

### C1. A verified cross-volume copy is deleted when the source delete fails → the file exists in NEITHER place
`Sources/FileOrganizer/History/FileMover.swift:375-389`

`try copier.removeItem(at: source)` sits inside the same `do` as the byte-verification, so ANY source-delete failure runs `discardingCopy(at: destination)` — destroying a copy already verified complete.

- **Loss (racy):** `EXDEV` → copy succeeds → bytes verified equal → source unlinked by something else (browser cleanup, sync agent, the user) in the microseconds before `removeItem` → `ENOENT` → we delete the destination copy. **File gone from both places.** This is plan risk #3 reached from the other side.
- **Lie + stray duplicate (reproducible, no race):** user ticked "Locked" in Finder (`uchg`). `copyItem` succeeds and *preserves the immutable flag*; `removeItem` then throws on both source and copy. A complete duplicate is left in the destination folder, the row says `failed`, and the popup says *"Copying to that disk failed, so the file was left where it is."* — while a full copy sits in the destination. The appended detail calls it "the incomplete copy"; it is not.

**Fix:** split the block. Once `copiedBytes == originalBytes` the destination is authoritative and must NEVER be discarded. A failed source delete is its own outcome ("copied, but the original couldn't be removed"). Keep `discardingCopy` only for the genuinely-unverifiable window (copy returned but verification threw or mismatched).

**Test gap:** `FaultyCopier` (`Tests/FileOrganizerTests/FileMoverTests.swift:36-92`) has `failEveryCopy` and `truncateCopy` but no `failRemove` mode, so both existing EXDEV tests stop short of this branch. Add it.

### C2. Launch reconcile adopts a STRANGER'S file as ours, then offers Undo on it
Found independently by `code-critic`, `silent-failure-hunter`, and `database-reviewer`.
`Sources/FileOrganizer/History/MoveCoordinator.swift:214-229, 244-249` + `MoveHistoryStore.swift:144-174, 321-335`

`recordIntent` stores the **intended** name in `final_name`. The mover may legitimately land on a different name — collision ladder (`FileMover.swift:193-205`) or the 255-byte trim (`FileMover.swift:180`). Only `finalize` ever corrects the row, and its failure is swallowed into a `#if DEBUG` log.

1. `Invoices/report.pdf` already exists — an unrelated file the app never touched.
2. Accept `Downloads/scan.pdf` → `report.pdf` → Invoices. Intent row: final = `Invoices/report.pdf`.
3. Mover: rung 1 `EEXIST` → rung 2 succeeds. File is at `Invoices/report 2.pdf`.
4. `finalize` never lands — force-quit, power loss, **or any transient SQLite error** (does not require a crash).
5. Next launch: source gone → true; target `Invoices/report.pdf` present → true (**the stranger's file**) → rule returns `.moved` → `isUndoable`.
6. Undo moves **`Invoices/report.pdf`, which the app never touched**, into `~/Downloads` renamed `scan.pdf`. The file that actually moved is orphaned with no record.

**Fix (cheapest first):**
- Fail safe — reconcile may only return `.moved` when it can prove the file at the target is ours; otherwise `.unknown` (no undo offered).
- Better (~15 lines): capture `(st_dev, st_ino)` or size+mtime at intent time and require a match at reconcile. Inode survives a same-volume rename; mismatch or cross-volume → `.unknown`. Partly closes plan risk #7 too.
- Or track the candidate actually being attempted with one bounded `UPDATE` per rung (rungs are rare).

**Test gap:** `reconcileResolvesEveryStrandedRow` and `reconcileRuleIsHonest` stub the probe, so they test only the pure rule; `startReconcilesAndCapsTheMenu` uses an intent whose intended name is exactly the one that landed. Add a coordinator test that dedups AND strands the row, then reconciles and asserts the untouched file was not adopted.

### C3. `errno` is read after `withCString` unwinds — a failed move can report success
`Sources/FileOrganizer/History/FileMover.swift:49-56` (plus `:298-300`, `:315-316`)

```swift
let result = sourcePath.withCString { source in
    destinationPath.withCString { destination in
        renamex_np(source, destination, UInt32(RENAME_EXCL))
    }
}
return result == 0 ? 0 : errno      // errno read AFTER both buffers are freed
```

`free()` is not guaranteed to preserve `errno`. If it reads back `0`, `attemptMove` (`:335-337`) takes `case 0: return true` → a `MoveOutcome` for a move that never happened → a history row saying the file is in Invoices while it is still in Downloads.

**Fix:** capture errno inside the innermost closure — `renamex_np(...) == 0 ? 0 : errno`. Same at the two `lstat` sites (there it only mislabels the error).

---

## MAJOR — data honesty

### M4. A fallback that happens to be a no-op closes as success and records NOTHING
`MoveCoordinator.swift:203-209`. `resolved.directory` is the *post-fallback* directory. If the destination folder was unusable, the resolver rewrites the destination to the source's own folder and sets `fallbackReason`; if the chosen name equals the current name, `isNoOp` is true → `.unchanged` → popup closes as success, **no history row, no message**. The user believes the file went to Invoices; it is in Downloads with no record. Violates founder decision 2.
**Fix:** `.unchanged` only when `resolved.fallbackReason == nil`. With a fallback reason, write the row and return an outcome carrying the reason.

### M5. `MoveSummary` reaches the popup and is thrown away
`UI/PopupController.swift:406-411` — `case .moved, .unchanged: finishCurrent()`. `fallbackReason`, `destinationFolderName`, `finalURL`, `wasRenamedForCollision` are all discarded. Founder decision 2 requires the fallback be surfaced *with its reason*; the same applies to a collision rename (asked for `Invoice.pdf`, got `Invoice 2.pdf`).

### M6. The failure channel has NO route to the user's eyes — hard prerequisite for wiring
`UI/PopupController.swift:78-91, 134` + `UI/PopupContentView.swift` (unmodified). Grep confirms zero readers of `activity`/`PopupActivity` outside `PopupController`. The controller is a plain `final class` — not `ObservableObject`, not `@Observable` — and `PanelPresenting` (`:10-16`) exposes only `show`/`hide`, so **there is no way to update a panel already on screen**. With the real coordinator wired, a failed move leaves the popup open, unchanged, Accept still enabled, no "Moving…", no error text — indistinguishable from "my click didn't register". Same dead end for `MoveCoordinator.historyRecoveredFromCorruption` (`:61-64`), which has no reader.
**Must land before `App.swift` swaps in `MoveCoordinator`.**

### M7. The watcher claim: a data race on wiring, and it swallows real downloads
`Watcher/DownloadsWatcher.swift:31-44, 121-130` + `FileMover.swift:154, 199` + `MoveCoordinator.swift:279`
- `noteAppCreatedFile` mutates a plain `[String: Date]` under a "main queue only" contract, but `CandidateAnnouncing` is called **synchronously from inside `Task.detached`**. Package is Swift 5 language mode (`Package.swift:17`), so the compiler will NOT diagnose the obvious step-10 one-liner. Unsynchronized `Dictionary` mutation racing `scanForNewcomers` — crash/corruption class. Cannot be fixed by hopping to main, because the claim must be registered *before* the file can appear. **Fix: a small locked box owned by the watcher.**
- Claims are **name-only, unscoped, and never consumed on use**. Unused ladder rungs linger 300 s: accept into a folder where `Invoice.pdf` is taken → claims `Invoice.pdf` + `Invoice 2.pdf` → rung 2 lands → within 5 minutes the user downloads a real `Invoice.pdf` from their bank → adopted into `knownNames` and **never announced**: no popup, no menu row, ever. `DownloadsWatcherClaimTests.onlyTheUsedRungIsAdopted` currently pins this as intended — that test's expectation is wrong.
- **Fix:** scope claims to the watched directory (the hook has the full URL), consume on first match, and release unused rungs when the move settles rather than on a timer.

### M8. Transient SQLite errors are misdiagnosed as corruption → irreplaceable history orphaned
`MoveHistoryStore.swift:117-128` — `catch StoreError.queryFailed where existed` catches `readUserVersion` and all three `executeStatic` calls. Verified on this machine: `PRAGMA journal_mode=WAL` returns `SQLITE_BUSY` under a concurrent reader; `PRAGMA user_version` returns `SQLITE_BUSY` under a concurrent writer; disk-full gives the same shape. The real `history.db` is renamed to `history.db.corrupt-<uuid>`, replaced with an empty file, and the user is told history was lost. **One-way:** the next launch reports `.openedExisting` and the real history is orphaned forever. If `openAndPrepare` fails again after the move-aside, `init` throws and the next launch sees a normal empty DB — a **silent** fresh start, exactly what the plan forbids.
**Fix:** carry the SQLite result code in `StoreError.queryFailed`; treat only `SQLITE_CORRUPT (11)` / `SQLITE_NOTADB (26)` as corruption. `SQLITE_BUSY`/`SQLITE_IOERR`/`SQLITE_FULL` → `cannotOpen`, file untouched.

### M9. "Clear history" does not clear — measured, not theorised
`MoveHistoryStore.swift:308-311`. macOS system SQLite is not built with `SECURE_DELETE`. Two reviewers reproduced independently: 400 rows → prune → `clearAll` left **445 plaintext occurrences of the filename and 439 of the destination path** readable in the file; a separate run found 300/300 `SECRETDOC-…-divorce-settlement.pdf` still greppable. Founder decision 3 promises this button clears the history.
**Fix:** `PRAGMA secure_delete=ON` next to the WAL pragma (`:476`), and `clearAll` follows the delete with `VACUUM` + `sqlite3_wal_checkpoint_v2(..., SQLITE_CHECKPOINT_TRUNCATE, ...)`. Add a test that greps the raw file bytes after `clearAll`. **The same `secure_delete` line belongs in `Index/FolderIndexStore.swift`, which holds embeddings of the user's file contents.**

### M10. `synchronous=NORMAL` — the intent row is not durable against power loss
`MoveHistoryStore.swift:476`. Apple's build sets `SQLITE_DEFAULT_WAL_SYNCHRONOUS=1`, so `PRAGMA synchronous` drops from FULL to NORMAL when WAL is enabled: commits do not fsync. Intent row "committed" → rename (APFS journals the metadata op) → power loss → the rename survived, the WAL frame did not → **file moved with no history row**. Plan risk #6. The store's doc comment claims intent-first makes this impossible; today it makes it unlikely.
**Fix:** `PRAGMA synchronous=FULL` on this connection (one fsync per Accept — user-paced, free). Leave `index.db` at NORMAL; record why the two differ in `docs/product/decisions.md`.

### M11. Release builds print the user's filenames — M6's own release-checklist item
Six ungated `print` sites, no `#if DEBUG` in either file:
- `Watcher/DownloadsWatcher.swift:94` — full folder path, **not even `LogSanitizer`-scrubbed**
- `Watcher/DownloadsWatcher.swift:268` — every download's filename
- `AI/AIEngine.swift:174, 192, 221, 284` — `:284` prints the filename with each AI outcome

`swift build -c release` does not define `DEBUG`; `CLAUDE.md`'s documented run command is `./.build/release/FileOrganizer` from a terminal, so a release binary streams filenames into scrollback. **Fix:** gate all six, sanitize `:94`.

### M12. Store failures are swallowed into DEBUG-only logs — release builds are mute
`MoveCoordinator.swift:77, 82, 159, 248, 262, 294` via `devLog` (`:313-317`).
- `refreshRecent()` fails → `recent` silently keeps a stale/empty value. `decode` throws on ONE unreadable row (`MoveHistoryStore.swift:614-645`), so a single bad row makes the whole history unreadable — and that is then swallowed. The user cannot tell "nothing happened" from "your undo history is unreadable".
- `reconcileInProgress` (`MoveHistoryStore.swift:339-355`) **aborts the whole loop on the first row that fails to settle**, leaving every later stranded row `inProgress` permanently (the pass only runs at launch).
- `finalize` fails after a successful move → `.moved` returned (correct) but the row stays `inProgress`, so **no Undo for that move for the rest of the session**, with no signal. Feeds C2.
**Fix:** a published `historyProblem: String?` the menu renders as one honest line; `reconcileInProgress` continues past a failing row and reports.

### M13. The mover's most important detail is stripped before storage
`MoveCoordinator.swift:260` — `markFailed(detail: error.message)` stores the generic sentence and drops the typed payload. Worst instance: `FileMover.discardingCopy` (`:397-404`) deliberately appends `"; the incomplete copy could not be removed either"` — precisely because a stray partial file is something the user must hear about. That clause dies here and the stored line becomes *"…the file was left where it is."*, an affirmative all-tidy statement while a partial file sits at the destination.

---

## MEDIUM

- **M14. Undo's write destination is not bounds-checked.** `MoveCoordinator.swift:141-145` passes `record.originalDirectory` straight from the DB column. The *name* is re-validated on read-back; the *directory* is not. An edited `history.db` row turns Undo into "move any user-readable file into any user-writable directory". Requires write access to a 0600 user-owned file, so no privilege boundary is crossed — but the non-malicious version is real (a row written during a `FILE_ORGANIZER_WATCH_DIR` session pointing at a recycled temp dir). **Fix: one `isWithinAllowedRoots(_:)` gate applied to BOTH accept and undo** — allowed = watched folder + registry folder URLs, compared on `resolvingSymlinksInPath().path` with a component-boundary prefix test. This also closes the forward gap: `MoveDestinationResolver.resolve` never checks `decision.sourceURL` is inside the watched folder either (true by construction today, unenforced).
- **M15. `FILE_ORGANIZER_WATCH_DIR` is honored in release, unvalidated.** `DownloadsWatcher.swift:48-53`. `launchctl setenv` needs no admin rights and no TCC prompt, and silently repoints the app at any folder — which, once wired, becomes a folder it *writes* to. **Fix: `#if DEBUG`**, or require the resolved path be inside the user's home plus a persistent banner.
- **M16. `pruneBeyond` has no floor and no `inProgress` protection.** `MoveHistoryStore.swift:289-304`: `max(0, keeping)` makes `pruneBeyond(0)` a `LIMIT 0` whose `NOT IN (empty)` is TRUE for every row — it silently wipes the irreplaceable table. Add `guard keeping > 0` and `AND state <> 'inProgress'`.
- **M17. `clearAll` mid-move produces a move with no record.** It deletes `inProgress` rows; `finalize` then fails on `changes != 1` and is only devLogged. Guard on `inFlight.isEmpty`, or delete only settled rows.
- **M18. Retention is only enforced at launch** (`MoveCoordinator.swift:79-83`). A menu-bar app runs for weeks, so founder decision 3's "keeps the last 200" isn't true in-session. Prune after each successful `finalize`.
- **M19. `clearHistory()` doesn't clear derived UI state.** `recent = []` but `outcomes` (`:40`) keeps every per-file "Moved to Invoices" line, so the menu still shows history after clearing. `outcomes` is also never pruned. The `undo` failure paths never call `refreshRecent()`.
- **M20. Blocking disk I/O on the main actor.** `MoveDestinationResolver.resolve` is `@MainActor` and synchronously calls `fileExists`/`resourceValues`; a spun-down external disk or stale SMB mount blocks the menu bar. The mover was deliberately pushed off-main for exactly this reason.
- **M21. Blocking I/O on the cooperative pool.** `MoveCoordinator.swift:279` runs `FileManager.copyItem` in `Task.detached`; a multi-GB copy parks a pool thread for minutes. A dedicated serial `DispatchQueue` bridged with `withCheckedContinuation` is the idiomatic shape. (The `Result` return rather than `throws` is correctly reasoned — keep it.)
- **M22. No migration ladder.** `MoveHistoryStore.swift:477-482`: the `foundVersion < schemaVersion` branch runs `CREATE TABLE IF NOT EXISTS` (a no-op) then stamps the new version, so bumping to 2 would silently mark a v1 DB as migrated. For an irreplaceable DB, run an explicit ordered migration or refuse. Wrap DDL + version stamp in a transaction.
- **M23. Folder identity cross-check compares leaf names only.** `MoveDestinationResolver.swift:166-186` + `FolderRegistry.swift:397-400`. Two registered folders sharing a leaf name ("Receipts", "2026") defeat the risk-#4 mitigation. Compare the stored path or a stable per-folder UUID.
- **M24. `isWritableDirectory` can't see a TCC denial.** `access(W_OK)` returns true for TCC-blocked `~/Documents`/`~/Desktop`, so risk #9 — the most likely real case on the founder's own Invoices folder — does NOT take the decision-2 fallback path; it hard-fails at the mover. Decide which behaviour is wanted and make both paths agree.

## MINOR
- **M25.** Self-rename short-circuit only covers rung 1 (`FileMover.swift:187-189` vs `:193-205`): a deduped rung can land on the source's own name → `renamex_np` returns 0 → an undoable row for a move that never happened. Apply the identity check per candidate.
- **M26.** `isNoOp` uses `standardizedFileURL` (collapses `..`, not symlinks). Registry URLs are symlink-resolved, the watcher's are not — on a symlinked home, the no-op check misses. Compare `resolvingSymlinksInPath()` for the *directory* only.
- **M27.** Cross-volume no-overwrite is advisory, not kernel-enforced: `copyItem` pre-checks then calls `copyfile()` without `COPYFILE_EXCL` — a genuine TOCTOU window, unlike `RENAME_EXCL`. Reserve with `open(O_CREAT|O_EXCL)` or pass `COPYFILE_EXCL`. At minimum soften the comments at `FileMover.swift:5-11, 30-31` which claim both paths "refuse".
- **M28.** Undo is not intent-first (`MoveCoordinator.swift:141-163`) — move-then-record. No data loss, but the crash-consistency guarantee doesn't extend to undo. State it in `docs/product/modules/History-Undo.md` if deliberate.
- **M29.** `try?` swallows the journal move whose comment says stale journals "would poison a fresh one" (`MoveHistoryStore.swift:520-529`). Fold the failure into `OpenOutcome`.
- **M30.** Typed throws stops at the store boundary — every `MoveHistoryStore` method is untyped `throws`, and the coordinator stringifies into `.historyUnavailable(detail: "\(error)")`. Use `throws(StoreError)`.
- **M31.** `MoveHistoryStore.deinit` does not compile in Swift 6 language mode (`Package.swift:17` pins `.v5`). Same pre-existing issue at `FolderIndexStore.swift:143`. On this deployment target: `isolated deinit`. **The repo is NOT Swift 6 strict-concurrency despite the docs saying so** — AIEngine/ExtractionEngine/FolderRegistry also error under `-swift-version 6`.
- **M32.** Bare `default:` over our own `MoveState` (`MoveHistoryStore.swift:359-368`) — a new state silently returns nil instead of failing to compile.
- **M33.** `sqlite3_close` (v1) unchecked on two open-error paths (`:458`, `:485`); the rest of the file uses `close_v2`.
- **M34.** `historySQLiteTransient` (`:8`) duplicates `sqliteTransient` in `FolderIndexStore.swift:8` — prefer a `static let` on the owning type.
- **M35.** `performAccept` is 79 lines / 4 nesting levels (`MoveCoordinator.swift:189-267`). Extract the settle step. Matters for a beginner-coder audience.
- **M36.** `waitForActiveMoves()` is production API existing only for tests; the `while let ... .first` spin assumes each task removes its own key.
- **M37.** `PopupController.accept` returns silently on an unusable name (`:330-334`) — set `activity = .failed(...)` so a future divergence from `canAccept` isn't an unreported no-op.
- **M38.** Moved-aside corrupt DBs are permanent and `clearAll` ignores them; no uninstall/reset story (deleting the `.app` leaves `~/Library/Application Support/AI File Organizer/` intact). Add a "Reset app data" action; document the manual path.
- **M39.** `createParentDirectoryIfNeeded` never tightens an existing directory's mode. Fine today (0700 by construction), unasserted.
- **M40.** Packaging blocker (not M6): `FolderRegistry.swift:368-372` creates ordinary bookmarks and nothing calls `startAccessingSecurityScopedResource`. A sandboxed build needs app-scoped bookmarks + `com.apple.security.files.user-selected.read-write`, with every move wrapped in the access, or moves fail silently.

## Test gaps to close
1. `FaultyCopier` needs a `failRemove` mode → C1.
2. A coordinator test that dedups AND strands the row, then reconciles and asserts the untouched file was not adopted → C2.
3. A `.unchanged`-with-fallback test → M4.
4. A claim test where a real download collides with an unused rung → M7 (and fix `onlyTheUsedRungIsAdopted`, which currently pins the wrong expectation).
5. `concurrentUndosHaveExactlyOneWinner` (`MoveHistoryStoreTests.swift:261-277`) **cannot observe concurrency** — both `async let` calls enter the same actor and there is no suspension point, so it is a silent duplicate of `markUndoneIsStateGuarded`. Drop it or drive two separate connections.
6. Raw-bytes assertion that `clearAll` removes the data → M9.
7. Rows survive close-and-reopen, directly in the store suite.
8. `-wal`/`-shm` permissions (passes today by SQLite behaviour, not by our code).
9. `finalize` on an already-settled row (the `changes != 1` throw).
10. `pruneBeyond` against an `inProgress` row, and with `0`/negative.

## What is genuinely clean — do not "fix"
No bare `rename(2)`, no `replaceItem`, no remove-then-move anywhere; the collision ladder is bounded and never inspects or touches an occupant; undo reuses the identical primitive; `RENAME_EXCL` puts no-clobber in the kernel with no TOCTOU on the primary path; six tests assert a pre-existing file's exact bytes after a refused overwrite. Fail-closed is correct and well tested. No path closes the popup on `.failed`; founder decision 5 (hide ≠ cancel) is implemented correctly — no stranded `inFlight`, no blocked queue, identity guard prevents resurrection. Double-accept and `markUndone` races are properly guarded and tested. `SQLITE_TRANSIENT` on every bind; no statement leaks; `close_v2`; future-`user_version` refusal. Zero force unwraps / `try!` / `as!` / `fatalError` in `Sources/FileOrganizer/History/`. Two independent layers of filename validation (`../../../../etc/cron.d/evil` → `etccron.pdf`). `lstat` (not `stat`) so a symlinked download moves as the link. Corruption evidence preservation asserts byte equality. Actor confinement holds; `reconcileInProgress` has no `await`, which is load-bearing — add a comment so a future `await` doesn't quietly break it.
