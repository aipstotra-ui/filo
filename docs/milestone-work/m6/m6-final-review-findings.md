# M6 — final review round findings (2026-07-29)

Seven reviewers run in parallel against the complete M6 tree before commit:
`code-critic`, `swift-reviewer`, `silent-failure-hunter`, `security-auditor`,
`database-reviewer`, `a11y-architect`, `ui-designer`.

`ai-reviewer` was deliberately skipped: the only AI-module change this milestone
was gating six debug `print`s behind `#if DEBUG`, which `security-auditor`
covers at the binary level.

**Verdicts:** security PASS · database WARNING · swift-idiom WARNING ·
code-critic 1 critical · silent-failure 2 criticals · a11y BLOCK · design BLOCK.

**Nothing below is a re-report of an already-fixed C1–C3 / M4–M33 finding.**
Numbering here is `F##` to avoid collision with the earlier round.

---

## Tier 1 — data safety. Must fix before commit.

### F1. Undo trusts a stored *path*, never the file's identity
**Found independently by `code-critic` (critical) and `database-reviewer` (H1).**
`Sources/FileOrganizer/History/MoveCoordinator.swift:177-202`

The only precondition on undo is `itemExists(at: record.finalURL)`.

1. Accept: `~/Downloads/scan.pdf` → `Invoices/report.pdf`. Row = `moved`.
2. Weeks later the user deletes it and files a *different* `report.pdf` into
   Invoices by hand. Retention is 200 rows, not 200 hours — the row is still there.
3. Settings › History still shows Undo (no per-row probe, by design).
4. Undo relocates **the stranger's file** into Downloads, renamed to `scan.pdf`.
5. Row flips to `undone`. There is no undo-of-an-undo in M6.

This is finding C2's harm reached through the door nobody closed: the *reconcile*
path was hardened against adopting a stranger's file, the *undo* path was not —
and undo is the more reachable of the two (no crash required).

**Fix (cheap, no migration):** after the existence guard, read
`FileIdentity.ofItem(atPath:)`. If the recorded `sourceIdentity` is non-nil and
`deviceID` matches but `inode` differs → refuse with `.fileNotWhereWeLeftIt`.
Closes every same-volume move. Cross-volume needs `final_device`/`final_inode`
(schema v3) — deferrable **only if written down** in `docs/product/modules/History-Undo.md`.

### F2. With no history database, Accept closes as success and moves nothing
**Found by `silent-failure-hunter` (critical) and `code-critic` (major).**
`Sources/FileOrganizer/UI/App.swift:84` → `SuggestionAccepting.swift:67-81`
→ `PopupController.swift:478-479`

`accepter: coordinator ?? NoMoveAccepting()`. `NoMoveAccepting.accept` returns
`.unchanged`; `finish` treats `.unchanged` as success and calls `finishCurrent()`.

Sequence: `history.db` won't open → coordinator nil → suggestions appear as
normal → Accept → **popup closes exactly as it does after a real move** → file
still in Downloads under its old name, no row, no message. Menu bar still says
"Watching Downloads". The only honest text is in a Settings tab nothing points at.

Contradicts founder decision 1, which the coordinator implements correctly —
the nil branch bypasses it.

**Fix:** replace the fallback with an accepter returning
`.failed(.historyUnavailable(...))`. That message already reads exactly right.
Keep `NoMoveAccepting` as a test double only. Add a `PopupControllerTests` case
asserting the popup does **not** close on the degraded seam.

### F3. A failed row leads with a filename the file does not have
**Found by `silent-failure-hunter` (critical).**
`Sources/FileOrganizer/History/HistoryRowPresentation.swift:47, 94-99`

`recordIntent` writes `final_name = intendedName`; `markFailed` never rewrites it;
`currentName = record.finalName` unconditionally. A failed move of
`statement(1).pdf → 2026-05 Chase statement.pdf` renders headline
`2026-05 Chase statement.pdf` and line 3 "Still in Downloads under this name."
The file is still `statement(1).pdf`. The row's most prominent field is the one
name guaranteed wrong for this state.

**The unit test masks it:** `HistoryRowPresentationTests.swift:105-110` passes
`originalName` and `finalName` identical — a rename that renames nothing, which
is not what a failed accept produces.

**Fix:** in the `.failed` and `.unknown` branches lead with `record.originalName`.
Re-point the fixture at differing names.

### F4. The popup never resizes, so the failure message is drawn outside the window
**Found independently by `ui-designer` (#1) and `a11y-architect` (M1).**
`Sources/FileOrganizer/UI/SuggestionPanel.swift:78-87` (measures `fittingSize`
once at `show()`), `:93-95` (`update(activity:)` only mutates state).

No `setFrame` and no `sizingOptions` anywhere in `Sources/` (grep-verified). The
TCC failure string is ~150 characters — three to four wrapped lines at the
panel's fixed 312 pt width. The message is clipped, and in the taller failure
states the footer with Dismiss/Accept goes off-window.

`docs/milestone-work/m6/m6-accessibility-spec.md`:15` names this trap verbatim
("else the error is drawn outside the frame and is invisible. Real
implementation trap"). Invisible to the suite because `PanelPresenting` is mocked.

**Fix:** retain the `NSHostingView`; on `update(activity:)` call `layout()`, read
`fittingSize`, `setFrame` top-anchored (hold `frame.maxY`), animated ≤200 ms
unless `accessibilityDisplayShouldReduceMotion`.

---

## Tier 2 — honesty and correctness. Should fix before commit.

### F5. Clear History reports total failure after it has already deleted everything
**Three reviewers: `silent-failure-hunter` #4, `database-reviewer` H2, `swift-reviewer` #5.**
`MoveHistoryStore.swift:418-434` + `MoveCoordinator.swift:237-257`

`DELETE` commits (autocommit), then `VACUUM` runs. On a full disk or a lock,
`VACUUM` throws → `.historyUnavailable` → banner says "The history couldn't be
cleared" → `recent` is never emptied. The user sees rows that no longer exist,
every Undo on them fails, and they believe the clear didn't happen.

**Fix:** treat the delete as the commit point. Wrap `VACUUM`/checkpoint in their
own catch, return a distinct "cleared but not compacted" outcome, and clear
`recent` on every path where the delete committed.

### F6. The launch reconcile can settle a row belonging to a *live* move
**Two reviewers: `silent-failure-hunter` #7, `database-reviewer` H3.**
`MoveCoordinator.swift:92-113` + `MoveHistoryStore.swift:466-499`

`inProgressRecords()` has no launch cutoff and no `inFlight` exclusion. Nothing
prevents a second instance — no bundle, no `LSMultipleInstancesProhibited`, no
lock file — and `CLAUDE.md` tells the founder to run the binary from a terminal.

Instance B's reconcile settles instance A's live row as `.failed` ("the file
stayed where it was"); A's `finalize` then fails and A closes as success. Net:
the file moved, and the permanent record says it didn't.

**Fix:** reconcile only rows with `accepted_at < launchTime`, and skip rows whose
`file_event_id` is in `inFlight`. An `flock` beside `history.db` is the fuller fix.

### F7. `refreshRecent()` erases every honest message the move paths just wrote
**Found by `code-critic` (#3).** `MoveCoordinator.swift:431-443`, `historyProblem = nil` at `:435`

Called unconditionally at the end of every path that just set a problem —
`settle` (`:377`→`:382`), `performAccept` failure (`:349`→`:351`), `start()`
(`:99`, `:450`→`:113`). The single most important sentence in this milestone —
*the move happened and cannot be undone* — is written and wiped microseconds
later. In practice `historyProblem` can only ever display "Your undo history
couldn't be read", which undoes the M12 fix it was written for.

**Fix:** `refreshRecent()` clears only a problem it owns; `noteHistoryProblem`
wins over a later successful read.

### F8. A successful undo whose history write fails leaves the row permanently wrong
**Two reviewers: `silent-failure-hunter` #5, `security-auditor` F3.**
`MoveCoordinator.swift:206-220`

The file is back in Downloads when `markUndone` throws; the catch returns
`.failed`. Row stays `moved`, still points at the destination folder, still shows
Undo. Pressing it again says "that file isn't where the app left it" — which
reads as an accusation that the user moved it. `reconcileInProgress` only settles
`inProgress` rows, so nothing ever corrects it.

**Fix:** report the truth (`.restored`), set `historyProblem`, `refreshRecent()`,
and suppress Undo for that record for the session.

### F9. Claims keyed by name only — one move retires another move's live claim
**Three reviewers: `code-critic` #4, `swift-reviewer` #1, `silent-failure-hunter` minor.**
`Sources/FileOrganizer/Watcher/AppCreatedFileClaims.swift:69, 78-85`

`claims[name] = Claim(group:)` is last-writer-wins. Two concurrent accepts are
reachable (a move outlives its panel per decision 5). Move A claims and uses
`report.pdf`; B claims the same name, overwriting ownership; B settles and
`releaseUnused(group: B)` deletes the entry A's real file depends on. The watcher
then announces **the file the app just renamed** as a brand-new download — risk #8,
exactly what M7 exists to prevent.

**Fix:** value holds a `Set` of groups; delete only when it empties (never for
`keptName`). Or make `claim` non-clobbering.

### F10. Quit during a move is unguarded
**Found by `silent-failure-hunter` (#8).** `App.swift:91-100`, `MenuContentView.swift:60-62`

No `applicationShouldTerminate`. Quit during a cross-volume copy kills the
process mid-`copyfile`, leaving a partial file nothing cleans up and an
`inProgress` row that reconciles to `unknown` — the user is sent to look in two
places for a file the app was seconds from placing correctly.

**Fix:** `applicationShouldTerminate` → `.terminateLater` while moves are in
flight, reply after a bounded wait.

### F11. "Moving…" is shown only in the cases where it is false
**Two reviewers: `silent-failure-hunter` #3, `code-critic` #7.**
`HistoryRowPresentation.swift:50-56`

`recent` is never refreshed between `recordIntent` and settle, so a genuinely
running move never appears as `inProgress`. The only ways such a row reaches the
pane are: finalize threw, a reconcile couldn't settle, or another instance's row
— in all three the app is not moving that file and offers no Undo.

**Fix:** pass a real liveness signal (`coordinator.inFlight`); when false render
"Interrupted — the app can't confirm this one", tone `.caution`, no Undo.

### F12. `try?` swallows the error that decides whether the app moves files at all
**Two reviewers: `silent-failure-hunter` #6, `swift-reviewer` low.** `App.swift:106-110`

Discards a typed `StoreError` distinguishing `cannotOpen`, `queryFailed`, and
`unsupportedSchemaVersion(found:supported:)`. Nothing is logged even in DEBUG,
and the user-facing text asserts "Restarting the app usually fixes this" —
false for a future-version DB written by a newer build.

**Fix:** `do/catch`, keep the error, `devLog` it, branch the pane's sentence.

---

## Tier 3 — accessibility (a11y-architect: BLOCK)

- **A1 (=F4)** panel never resizes.
- **A2** Clear History confirmation has no `.keyboardShortcut(.defaultAction)` on
  Cancel — `HistoryPane.swift:55-56`. The spec says verbatim that SwiftUI on macOS
  does **not** make cancel the default automatically. **Return probably fires the
  destructive button**, wiping up to 200 undo records.
- **A3** Clear History announces nothing, and the footer holding the button is
  removed on success (`HistoryPane.swift:41-46`), destroying focus.
- **A4** Undo announces nothing on success *or* failure, and `undoFailure` is
  never in the row's accessible label (`HistoryPane.swift:220-222`) — a VoiceOver
  user concludes the file went back when it did not.
- **A5** A move that *succeeds* announces nothing; the popup just vanishes.
  Success never becomes an activity (`PopupController.swift:468-477`).
- **A6** Esc is inert in the `.completed` state (`PopupContentView.swift:207-215`)
  — violates locked founder decision 5 ("Esc must always be answered").
- **A7** Five Undo buttons all read "Undo this move" (`HistoryPane.swift:213`);
  spec wants `Undo move of {finalName}`.
- **A8** Reduce Motion ignored — two `ProgressView` spinners that never stop
  (`PopupContentView.swift:199`, `HistoryPane.swift:207`).
  `@Environment(\.accessibilityReduceMotion)` appears nowhere in `Sources/`.

**Credited as right:** filenames are never pre-truncated (flagged in advance as
the most likely mistake), semantic colour throughout, no greyed-out Undo,
auto-dismiss correctly off, day headers carry `.isHeader`.

---

## Tier 4 — design drift (ui-designer: fix 1–5 before commit)

- **D1 (=F4)** panel resize.
- **D2** Failure renders as an orange warning triangle
  (`PopupContentView.swift:258-267`); `docs/product/design-system.md:151` says "No banner,
  no fill, no icon, no warning triangle; red appears on the sentence only."
- **D3** "Open System Settings" button absent — **founder decision 7**.
  Structural cause: `PopupActivity.failed` carries only a `String`
  (`PopupController.swift:481`), so the view cannot recognise the TCC case.
  (`a11y-architect` notes the text names the pane, so nobody is *misled* — but
  the locked decision is unmet.)
- **D4** Raw POSIX paths and `errno` reach History rows
  (`HistoryRowPresentation.swift:95` ← `MoveRecord.swift:302-303`). A full disk
  reads "(errno 28: No space left on device)". Design system: never surface an
  error code or POSIX name.
- **D5** Failure sentences say "that folder", never its name.
- **D6** A moved file stays in the dropdown (`DownloadsWatcher.recentEvents` is
  never pruned on success) — double appearance, and `canReopen` still true so the
  menu offers to reopen a file that is gone.
- **D7** The dropdown gained a visible second row per file
  (`MenuContentView.swift:38-42`), contradicting the mockup's promise to the
  founder that "nothing here looks different".
- **D8** Outcome lines render `.secondary` (~3.9:1) where `design-system.md:67-71`
  — written this milestone — names them `.primary`.
- Plus: amber tinted banner box violates the "only tinted container" rule; Clear
  History confirmation copy leads with the loss instead of the reassurance;
  empty-state strings differ from approved; the approved post-clear empty state
  is missing; in-flight popup doesn't dim the name field; spinner has no ~200 ms
  delay; 220 pt list floor; day headers lost their band; missing slow-disk line.

### Needs a founder decision, not an engineering one
- **D9** Accept was changed to read **"Try again"** after a failure
  (`PopupContentView.swift:232`). The mockup recorded the opposite recommendation
  and `docs/milestone-work/m6/m6-status.md` records no overrule.
- **D10** A new `.completed` popup state (holds open after a *successful* move
  with an "OK" button) that the founder has never seen.

---

## Tier 5 — security (PASS, no blockers)

Zero-network promise **verified at five levels**: source grep (~40 identifiers,
one comment hit), import set, `Package.swift` (zero dependencies, no
`Package.resolved`), `otool -L` on the release binary (no CFNetwork, Network,
WebKit, Security), and `nm -u` (no socket/DNS/TLS symbols). All 9 `print` sites
are `#if DEBUG`; confirmed absent from the release binary by string search.
`history.db` has no content column; DB files are `0600` inside a `0700` directory.
No-clobber is kernel-enforced on both the forward and undo paths. Path traversal
is blocked in two layers. Symlinks are moved as links, never followed.

Three Lows, none blocking: **S1** deleted embeddings/paths stay readable in
`index.db` until the next launch (WAL, no checkpoint after `removeProfile`);
**S2** `*.corrupt-<uuid>` databases are never cleaned up and survive
"Clear History"; **S3** = F8.
Informational: a user who picks their home folder as a target widens the M14
write-bounds gate; `PopupController.accept` returns silently when the sanitizer
yields nil (inert control).

---

## Tier 6 — Swift-idiom and DB hygiene (no criticals)

`swift-reviewer` confirmed: no force unwraps/tries/casts anywhere in `Sources/`,
no retain cycles, sound actor boundaries, everything crossing the detached seam
genuinely `Sendable` with no `@unchecked`.

- **X1** `strerror` returns a **static** (not thread-local) buffer and is called
  from concurrent detached movers (`FileMover.swift:90, 537`) — a formal data race
  that can garble the `failure_detail` sentence persisted to `history.db`.
  Use `strerror_r`.
- **X2** `ForEach(…, id: \.title)` (`HistoryPane.swift:68`) can emit two sections
  titled "Today" — `grouped` merges only *adjacent* runs, and `markUndone`
  rewrites `settled_at` to now without changing the id. Duplicate SwiftUI IDs.
  *(Also found by `code-critic` #5.)*
- **X3** `sqlite3_wal_checkpoint_v2`'s result discarded (`MoveHistoryStore.swift:432`)
  — the one unchecked SQLite return. On `SQLITE_BUSY`, cleared filenames stay
  readable in `history.db-wal` while the UI says cleared. *(Also `database-reviewer` H4.)*
- **X4** The store connection is never closed on quit (`close()` has no caller in
  `Sources/`) — every quit is an unclean close. *(`database-reviewer` H5.)*
- **X5** One undecodable row throws from `readAll` and takes down `recent()`,
  `record(id:)` **and** `inProgressRecords()` — aborting the whole reconcile.
  *(`database-reviewer` H6.)*
- **X6** Swift 6 language-mode blockers added this milestone: `transientBytes`
  C function pointer (`MoveHistoryStore.swift:81`), two non-`Sendable`
  `DateFormatter` statics (`HistoryPane.swift:254, 317`) reachable off-main.
- **X7** `DownloadsWatcher.swift:56` — `urls(...)[0]` traps if empty;
  `MoveHistoryStore.defaultDatabaseURL()` already does this correctly.
- **X8** A collision rung landing on the file's own name writes an undoable row
  for a move that never happened (`FileMover.swift:244-248` +
  `MoveCoordinator.swift:284-291`). *(`code-critic` #8.)*
- **X9** The fallback sentence is printed twice on a fallback row
  (`HistoryRowPresentation.swift:59-75`), and the comment at `:70-72` is now false.
- **X10** Stale comment claims M22 is still open (`MoveHistoryStore.swift:676-677`).
- **X11** `performAccept` is 93 lines, over the ~50-line house bar.
- **X12** **M23 is still open** and is *not* in the fixed list: the folder
  identity cross-check compares leaf display names only, so two registered
  folders both named "Receipts" defeat the risk-#4 mitigation.
- **X13** `docs/product/decisions.md` has no entry for `history.db` (why a separate file,
  journal mode, `synchronous=FULL` vs the index's NORMAL, `secure_delete=ON`,
  and why its corruption policy differs). `docs/product/modules/History-Undo.md` is still
  the pre-M6 stub — which F1 makes the minimum acceptable outcome if the
  cross-volume half of that fix is deferred.
- Consistency nit outside M6: `FolderIndexStore.swift:337, 372` still use v1
  `sqlite3_close` where the history store standardised on `close_v2`.

---

## F13. The suite hangs forever — and the hang is hiding a real bug

**Diagnosed 2026-07-29 by bisecting a streamed test log.** The suite does not
finish. It stops at exactly one test and waits indefinitely:

> `PopupControllerTests.swift:627` —
> *"After a notice the popup offers no Accept — the file has already moved"*

**Why it hangs.** At `:645` the test presses Accept a second time while the popup
sits in the `.completed` state. It then `await`s `waitForActiveMoves()` at `:646`.
`PopupController.accept` (`PopupController.swift:381-407`) guards only on
`activeMoves[current.fileEventID] == nil` — and that entry was **removed** at
`:458` when the first move finished. So the guard passes, a **second move
starts**, and `ControllableAccepting` never completes it because the test never
calls `complete()` for it. `waitForActiveMoves` loops on a task that will never
return. The process parks in `CFRunLoopRun` with an empty main-actor queue and
zero CPU — which is why it looks alive but never progresses.

**The real bug underneath.** The test's own assertion —
`#expect(accepter.accepted.count == 1, "a second move must not be startable")` —
is correct, and the code does not satisfy it. Nothing in `PopupController`
prevents a second Accept in the `.completed` state. The footer hides the Accept
*button* (`PopupContentView.swift:207-215`), but the name field is still rendered
and still editable (`:142-165`), and its `onSubmit` at `:148-153` calls
`onAccept(editedName)` gated only by `canAccept` (name non-empty). Its comment
claims "the controller dedupes, so this and the default-action button can't
double-accept" — **that dedupe does not apply here**, because the first move has
already been removed from `activeMoves`.

So: after a move that succeeded *with a change* (deduped name, or a fallback
rename in place), pressing **Return while the name field has focus** starts a
second move against a path the file no longer occupies. It fails (source gone),
the popup flips to a failure message, and a `failed` history row is written —
for a file that in fact moved correctly. That is a false failure record about a
successful move, in the milestone whose entire purpose is an honest record.

**Fix:** refuse the accept when the popup is in a settled state — guard `accept`
on `activity` being `.quiet`/`.editing`/`.failed` (a retry after a genuine
failure is the one case that must still work), and disable the name field once
`completionNotice != nil`. Then make the test assert instead of hang: give
`waitForActiveMoves()` a bounded wait in tests, or assert `accepter.accepted.count`
directly without awaiting a move that must never have started.

**Note this is the state the founder chose to keep as built (D10, 2026-07-29).**
Keeping the state is fine; the missing guard is a defect either way.

---

## Test-suite note

`swift build` is clean (debug). **`swift test` cannot currently complete** — see
F13. The last recorded green run (231/231) predates the History-pane and
menu-reopen work, so there is no trustworthy green baseline for the current tree.
Everything before the hang point does pass, including the full `MoveCoordinator`
and `MoveHistoryStore` suites.

`docs/milestone-work/m6/m6-status.md` already warns that three tests this
milestone **passed against deliberately broken code**. F3 is a fourth instance
(its fixture is shaped so the bug cannot appear) and F13 is a fifth (it hangs
instead of failing). **A green suite is not evidence in this milestone** —
mutation-check anything that guards user data.
