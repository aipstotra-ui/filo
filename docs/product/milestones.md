# Milestones (Phase 1 — the demo build)

Goal: a working app on the founder's Mac, polished enough for the demo video. Each milestone is independently testable.

## M1 — Skeleton & watcher ✅ done

Menu-bar app + [[Watcher]] for `~/Downloads`.

Checklist:
- [x] Build succeeds (`./build.sh` — originally via the swiftc fallback; since 2026-07-17 Xcode is installed and the script builds with SwiftPM)
- [x] App appears in the menu bar (no Dock icon) — verified in M2 QA runs and the 2026-07-17 full regression
- [x] New file announced within ~5s (verified in sandbox: instant file, slow-growing file, emoji filename)
- [x] Half-downloaded files NOT picked up early (`.crdownload` ignored until renamed; growing file announced only at final size)
- [x] Hidden files ignored; pre-existing files ignored; 0% idle CPU; survives the watched folder being deleted
- [x] code-critic review: 2 major + 4 minor findings — all fixed same day (timer paused while menu open; unreadable-size files no longer treated as 0 bytes; folder-loss handling; build script globs sources)
- [x] security-auditor: **PASS** (no networking at all, no file reads/writes, no dependencies; 2 dev-only `print` lines flagged for removal before any release build)

## M2 — File understanding ✅ done — built, QA'd, reviewed, regression-passed 2026-07-17

[[Extraction]]: PDF text (PDFKit, scanned PDFs → page-1 OCR), image OCR (Vision), plain text; filename+metadata fallback with a typed reason for everything else. `PipelineModel` wires [[Watcher]] → [[Extraction]] and the menu now shows a per-file status line.

Founder decisions this milestone: **scanned-PDF OCR — yes** (in scope); **.docx support — deferred** (later milestone); **debug snippet flag — approved** (`FILE_ORGANIZER_DEBUG_SNIPPETS=1`, dev-only, 2026-07-17).

Checklist:
- [x] Drop a PDF → accurate snippet extracted, status shows "PDF text · N words"
- [x] Scanned (no-text-layer) PDF → page 1 rendered and OCR'd
- [x] Screenshot → OCR text; plain text/markdown/csv → first 64 KB read
- [x] Unsupported files (zip, video) → clean "Using name & type" fallback, never an error
- [x] Hung/huge file → "Took too long to read" after 60 s, late result dropped
- [x] qa-tester caught: a binary file named `.txt` slipped past a too-weak printability check — fixed (stricter text-likeness ratio)
- [x] Review round (4 reviewers, 3 majors found & fixed): UTF-16 files falsely rejected by the NUL-byte binary gate; image decompression bombs unbounded (now capped-thumbnail decode); `isEncrypted` over-rejected owner-password PDFs (now `isLocked` only)
- [x] security-auditor: **PASS**, conditional on sanitizing filenames in logs — done (`LogSanitizer`, shared with [[Watcher]])
- [x] code-simplifier pass (e.g. renamed `notReadableText` → `binaryContent`); build green
- [x] Full regression of M1+M2 behavior passed 2026-07-17

## M3 — Local AI ✅ done — built, tested, reviewed 2026-07-18

[[AI-Engine]]: **Apple FoundationModels** (macOS 26 built-in on-device model — founder decision 2026-07-17, superseding the MLX+Qwen plan; zero downloads, zero third-party AI dependencies). Structured output (`@Generable`) → one-line summary + suggested filename; snippet embedding via built-in NLEmbedding for M4. Three-layer prompt-injection defense: session instructions → fenced prompt ([[ai-engineering]]) → output sanitizers (`FilenameSanitizer` + `SummarySanitizer`, both test-pinned).

Founder decisions this milestone: **FoundationModels over MLX+Qwen** (no 2 GB download; `AIProviding` protocol keeps the swap-back path); everything stayed cost-free as instructed.

Checklist:
- [x] Extraction snippet → AI → menu shows summary-and-name suggestion state (`Thinking…` → suggestion or honest reason)
- [x] Apple Intelligence off / device ineligible / model not ready → honest per-reason status line, pipeline degrades to name & type (fallback verified on real hardware)
- [x] Injection attempt in file content ("IGNORE YOUR INSTRUCTIONS…") → cannot redefine the prompt or produce an unsafe filename (fenced prompt + sanitizer tests)
- [x] Suggested filenames sanitized in code: path separators, control + bidi/invisible Unicode stripped, lookalike separators folded, real extension re-applied only when itself safe, 100-char cap
- [x] Hung generation → "AI took too long" after 60 s; hung embedding → suggestion ships without one after 10 s; burst of 5 files → every row resolves, none stick on "Thinking…"
- [x] `swift test` green (28 tests: filename sanitizer, summary sanitizer, prompt fencing)
- [x] Review round (5 reviewers incl. ai-reviewer): 1 critical + 2 majors found & fixed — stateful session reuse (now fresh session per generation: prevents cross-file content leakage, context overflow, busy-session errors), pointless greedy retry (now retries only decoding failures, once, non-greedy), unbounded embedding call (now 10 s bound). Targeted re-review: **PASS**
- [x] security-auditor: **PASS** — no networking anywhere in the AI module; logs carry outcome labels only, never content

**At this checkpoint, a real suggestion had not yet been seen live.** Only the honest-fallback path had run on real hardware. The next M3 sign-off step was to enable Apple Intelligence and test a representative document in Downloads.

## M4 — Folder index & matching ✅ built, live-QA'd & reviewed 2026-07-19 — one founder acceptance test remains for sign-off

[[Folder-Index]]: a Settings "Folders" pane where the user picks target folders; each is profiled on-device (file names + up to 3 content samples — founder decision) and stored in a local SQLite index; a new file's vectors are matched against folder profiles to attach a destination to the menu suggestion. **No file is moved (that's M6).**

Founder decisions this milestone: **content sampling** (peek inside a few files, not names-only) — privacy copy rewritten to say so honestly; **stay quiet when Apple Intelligence is off** (no name-only guessing — matching runs only after a successful AI suggestion); acceptance test uses the founder's **real** Screenshots + Invoices folders.

Pre-M4 system adopted: ECC's `database-reviewer`, rewritten from cloud-Postgres to local-SQLite scope (`.claude/agents/database-reviewer.md`).

Checklist:
- [x] Settings "Folders" pane built to the founder-approved mockup (`docs/mockups/m4-folders-settings.html`): add via folder picker, per-folder status (Indexed · N files, M read / Scanning… / Can't access / Folder missing), Rescan, Remove, empty state, verbatim privacy sentence
- [x] Raw-SQLite index (`import SQLite3`, no third-party package): actor-owned single connection, WAL, every value bound, typed errors, `0700`/`0600` perms, corrupt-file → move-aside-and-rebuild, future-`user_version` refusal
- [x] Read-only profiling: file names + ≤3 content samples via [[Extraction]]; embeddings normalized once; before/after snapshot proves no writes to target folders
- [x] Matcher: cosine over unit vectors, non-unit/mismatched vectors excluded, threshold 0.6 (QA-tunable), deterministic ties; honest `.noGoodMatch` / `.noFoldersConfigured` — never a forced destination
- [x] Pipeline integration: destination attaches after a successful AI suggestion, 10 s backstop, late results dropped; menu shows "→ Folder" / "No folder fits" / zero-folders hint; folder rename/move survives via stored bookmark; launch re-derives honest status from disk
- [x] `swift test` green (66 tests: matcher, profile builder incl. read-only + sampling, SQLite store incl. corruption/permissions, registry validation, plus the new `FolderMatchAcceptanceTests`)
- [x] **Threshold calibrated 0.6 → 0.80 (provisional)** — 2026-07-19, Apple Intelligence now enabled. Measured real NLEmbedding: real-home files score 0.84–0.94, strays (incl. near-misses like a bank statement vs Tax Documents) top out at 0.78; 0.6 force-matched strays. Pinned by `FolderMatchAcceptanceTests` (live NLEmbedding + extraction, 4 positives + 7 negatives). Recorded in [[decisions]]. **Provisional** because calibrated on a *synthetic* set with stand-in AI summaries.
- [x] **Live AI path verified end-to-end** — `LiveAISmokeTests` (env-gated) drives the real FoundationModels engine: a snippet → real suggestion (summary + sanitized filename + 512-d embedding) in ~2 s. Closes M3's "never seen live" gap too.
- [x] **Formal review round run** — all six reviewers (`code-critic`, `swift-reviewer`, `silent-failure-hunter`, `security-auditor`, `ai-reviewer`, `database-reviewer`) in parallel. **security-auditor: PASS** on "no content leaves the machine" (zero networking, read-only profiling, owner-only index storing only derived vectors/paths). No data-loss or injection bug. Contained correctness fixes applied & re-reviewed clean (orphan-row-on-remove compensating delete; broken-bookmark → stored-path fallback not "missing"; empty-query → quiet not false "No folder fits"; dimension sanity-guard; `sqlite3_close_v2`; release-gated the store-open log).
- [ ] **Remaining for sign-off (1): founder real-folder acceptance test** — in the live app, drop a real screenshot (→ Screenshots) and a real invoice (→ Invoices) against the founder's *own* folders with real AI summaries. This is the one thing the synthetic calibration can't prove; it's the founder's ~2-minute manual test.
- [ ] **Remaining for sign-off (2): founder decision on deferred index-health surfacing** — the review's top finding (app silently shows an empty folder list if the index is corrupt/rebuilt; needs a user-facing notice) is UI work that needs a founder-approved mockup. Full deferred list in [[Folder-Index]] › Known issues.

> **2026-07-19 update:** The live AI path became available, unblocking the two items deferred on 2026-07-18. Both are now done: threshold calibrated against real NLEmbedding (0.80, provisional) and the full 6-reviewer round run with fixes applied. What's left is the real-folder acceptance test and a product decision on the deferred index-health UI.

## M5 — The popup ✅ built + reviewed (2026-07-23) · ⏳ founder live-QA open

[[Popup-UI]]: floating non-activating panel, Accept / edit / Dismiss, auto-dismiss does nothing. HTML mockup founder-approved; built and put through the full independent review round (`code-critic`, `swift-reviewer`, `silent-failure-hunter`, `security-auditor`, `database-reviewer`, `a11y-architect` — `ai-reviewer` N/A, no AI-path change; `ui-designer` verify done in-session after a usage-limit cutoff). **94 tests green; `swift build` debug + release clean.** security-auditor **PASS** (zero network, zero content in logs); the "Accept moves no file" boundary is pinned by a zero-I/O test.

**Fixes applied from the round:** identity-guarded every popup callback (a stale Return can't act on the next queued popup); sanitized the folder name in the debug accept-log; compiled the whole extraction dev-log path out of release builds (`#if DEBUG`, so `FILE_ORGANIZER_DEBUG_SNIPPETS` content previews can no longer exist in a shipped binary); added tests for the quiet-destination pop and the stale-callback guard.

**Open before M5 sign-off:** (1) **founder live-VoiceOver check** (~5 min — does macOS speak the arrival announcement from the quiet corner popup); (2) **M6 hand-off requirements** captured in [[Popup-UI]] (seam failure channel + close-only-on-success; re-validate file/folder at move time; a way to act on menu-only overflow files).

## M6 — Log & undo ✅ built, reviewed, fix round complete

**Everything is written and the whole app is wired.** `App.swift` injects the
real `MoveCoordinator`, so **the app moves real files on Accept.**

**Fix round closed 2026-07-30.** Every blocking item from round 2 — data safety
F1–F4 and F13, honesty F5–F12, accessibility A2–A8, design D2–D8, Swift/DB
hygiene X1–X11 — is fixed. `swift test` **finishes**: 262/262, the first
trustworthy baseline since the History pane landed, and fourteen of the guards
were mutation-checked (broken on purpose, each confirmed to go red). Two things
remain open and both are the founder's: a live click-through on a real Mac, and
whether one extra dropdown line per file is acceptable (D7). One item is
deliberately deferred: X12, two registered folders sharing a leaf name. See
[[open-work]].

**Working docs live in `docs/milestone-work/m6/`** (moved out of the vault root
2026-07-29). The one to read is
[[m6-final-review-findings]] — the open work list. Supporting: [[m6-working-plan]]
(the approved plan), [[m6-accessibility-spec]] (build to this, audit against §L),
[[m6-status]] (how the build got here), [[m6-review-findings]] (round 1, historical).
Mockup: `docs/mockups/m6-history-undo.html`.

**Seven founder decisions are locked** and recorded in [[decisions]] — do not
re-litigate them. In short: fail closed; a folder that's *gone* → rename in place;
200 rows + Clear history; the dropdown keeps its `.menu` style and history lives
in Settings; during a move Dismiss becomes "Hide" and Esc is never inert; a
TCC-blocked folder is a failure, not a fallback.

### Round 1 review — done, fixed, mutation-verified

Three criticals (a cross-volume copy that could leave a file in neither place; a
launch reconcile that could adopt a stranger's file; an `errno` read that could
report a failed move as success) plus every assigned major and minor were fixed,
each **verified by deliberately breaking the code and confirming the test failed**.
Details in [[m6-status]].

### Round 2 review (2026-07-29) — seven reviewers, **verdict at the time: not committable**

*(Everything below was the state on 2026-07-29. It was all fixed on 2026-07-30 —
kept here because the shape of what went wrong is the useful part.)*

> **The tracked, prioritised list of what is actually open is [[open-work]].**
> Full technical detail — file, line, failing sequence, fix direction — stays in
> [[m6-final-review-findings]]. Don't work from this section; work from
> [[open-work]].

The shape of it:

- **Security: PASS.** Zero-network verified five ways — source, imports,
  `Package.swift`, `otool -L`, and `nm -u` against the release binary. No
  dependencies. No content column in `history.db`. Kernel-enforced no-overwrite.
- **Four Tier-1 defects**, three of them found by two or three reviewers
  independently: undo trusts a path and not the file's identity (**can relocate a
  file the app never touched**); the no-history fallback closes Accept as a success
  while moving nothing; the popup never resizes so a failure message is drawn
  outside the window; a failed row leads with a filename the file doesn't have.
- **Accessibility: BLOCK.** VoiceOver is silent at four moments that matter, and
  Return in the Clear History dialog probably fires the destructive button.
- **Design: BLOCK on five items**, incl. the failure rendering as a system-alert
  warning triangle and raw `errno` text reaching History rows.

### The test suite — resolved 2026-07-30

`swift test` used to **hang**, diagnosed to a single test
(`PopupControllerTests.swift:627`) that started a second move nothing ever
completed and then awaited it forever. The hang was concealing a real defect:
nothing stopped a second Accept after a move that succeeded *with a change*, so
Return in the name field could start a move against a path the file had already
left — writing a `failed` row about a move that in fact worked (F13).

Both are fixed. The guard refuses an Accept in a settled state, and the test
asserts the count directly instead of awaiting a move that must never exist.
**262/262, in under a second.**

**Five tests this milestone were caught passing — or hanging — against broken
code**, which is why fourteen guards were then mutation-checked: broken on
purpose, each confirmed to go red, restored. That list is in [[open-work]].
Outside those fourteen, a green suite still is not evidence.

### Closed 2026-07-30

1. ✅ The Tier 1–2 fix round — every `F##`, `A##`, `D##`, `X##` and `T##` item,
   with the affected reviewers' concerns addressed. Committed as `9b45df0`.
2. ✅ **Founder live QA** — the founder exercised M6 end-to-end in the running
   app on a real Mac and confirmed it works: a file is moved and renamed on
   Accept, and the move can be undone.

**Still founder-owned, and not blocking:** the VoiceOver pass (announcements
cannot be verified from inside the app, only heard) and the D7 call (one extra
"Review…" line per file in the dropdown). Both in [[open-work]].

**Two live-syscall findings that corrected the plan** (probed on Darwin 25.5/APFS): `renamex_np(RENAME_EXCL)` returns **0**, not `EEXIST`, for a self-rename — unhandled, the app would write an undoable history row for a move that never happened; and a pure case change (`report.pdf` → `Report.pdf`) or an NFD→NFC change also returns 0, so the mover must **not** pre-check occupancy with `FileManager.fileExists` (case- and normalization-insensitive on APFS) or a legitimate case-only rename gets deduped into `Report 2.pdf`. Both pinned by tests.

### Original M6 scope

[[History-Undo]]: history of accepted moves in the menu, one-click undo restores file and name.

**Release checklist (before any build leaves the founder's Mac):** the extraction dev-log path (filenames + the `FILE_ORGANIZER_DEBUG_SNIPPETS` snippet preview) is now compiled out of release via `#if DEBUG` (done in M5), so that flag has **no effect** in a release build. Still to do at release: verify no other dev `print` remains in release paths, and disable — or get fresh founder approval for — the dev env flag `FILE_ORGANIZER_WATCH_DIR` (QA sandbox folder override).

## After M6

**Phase 1 was scoped as six milestones. M6 was the last one — there is no M7.**
If more app work should happen before Phase 2, the founder scopes and names it;
until then, the next step is not code:

1. **One week of founder dogfooding.** Use the app daily on the real Downloads
   folder. Gate: **≥70% of suggestions accepted unedited**, undo always restores
   perfectly, near-zero idle CPU. Real usage is also what generates authentic
   demo footage.
2. **Then Phase 2 — demo video + waitlist.** The landing page is already built
   (`website/`, brand "Filo") and waiting on the founder's go-live approval.

Candidates if the founder does want a coded M7 first, all already tracked in
[[open-work]] — the release-hardening items marked *before the next release
build*, the index-health notice (founder check 2, needs a mockup), and `.docx`
support (deferred in M2).
