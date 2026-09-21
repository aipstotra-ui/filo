# Open work — the one list

**Every open item in the project lives here.** Reviewer findings, failing tests,
things waiting on the founder. If it isn't on this list, nobody is tracking it.

Read this at the start of every session. Update it at the end of every review
round. It is the only status document that is allowed to be *incomplete* —
because the moment something is found, it gets a line here before anything else.

**How an item gets here:** reviewers and QA agents report findings; they don't
write files. The **tech lead (main session)** files each finding as a row below
within the same turn it receives the report, then links to the full detail.
`docs-keeper` reconciles this list at the end of each milestone.

**How an item leaves:** it is fixed and verified, or the founder decides it isn't
happening. Deleted rows should leave a trace — move them to *Recently closed* at
the bottom rather than vanishing.

**Legend** — ⚡ a session was cut off mid-work · 🔴 blocks the current milestone ·
🟡 waiting on the founder · ⚪ deferred, deliberately

---

## ⚡ In flight right now

*Empty means no session is part-way through anything.*

A session writes here **before** starting work that would be expensive to
re-derive — a multi-file refactor, a bisect, a fix round — and clears it when
that work lands. If you are reading a non-empty section here, a previous session
ended before it finished: read the line, decide whether to finish or abandon it,
and clear the section either way.

This is the only thing that survives a `/clear`, a context limit, or a closed
laptop. See *Session boundaries* in [[workflow]].

| Started | What is part-way done | What the next session would otherwise have to work out again |
|---|---|---|
| — | *nothing in flight* | — |

---

## 🔴 Blocking

**Nothing is blocking, and M6 is closed.** The fix round cleared every `F##`,
`A##`, `D##`, `X##` and `T##` item below; `swift test` finishes at **262/262**;
fourteen guards were mutation-checked — broken on purpose, each confirmed to go
red; and the **founder verified M6 end-to-end on a real Mac on 2026-07-30**.

Two M6 items remain founder-owned and neither blocks: the VoiceOver pass (check
7) and the D7 dropdown call (check 6). One is deliberately deferred: X12.

**M6 was the last Phase-1 milestone — there is no M7 scoped.** Next per the
roadmap is the dogfooding week, then Phase 2. See [[milestones]] › *After M6*.
(An earlier version of this line said "next milestone is M7"; it was a
placeholder for a milestone that was never scoped.)

<details>
<summary>The register as it stood before the fix round (2026-07-29 → 30)</summary>

### Was blocking — M6 could not be committed until these were done

Full detail for every `F##` / `A##` / `D##`:
[[m6-final-review-findings]]. Locked founder decisions that constrain the fixes:
[[decisions]].

> **Only two M6 scratch files are still live:** `m6-final-review-findings.md`
> (the detail behind this list) and `m6-accessibility-spec.md` (what the A-items
> are graded against). `m6-status.md`, `m6-review-findings.md` and
> `m6-working-plan.md` are closed history — each is marked as such at its top.
> They can be deleted once M6 commits; nothing durable lives only in them.

### Data safety — a user could lose or misplace a file

| ID | In plain words | Where |
|---|---|---|
| F1 | **Undo can move a stranger's file.** Undo checks only that *something* sits at the remembered path, not that it's the same file. Delete a moved file, later put a different file with that name in the folder, and Undo relocates the wrong one. | `History/MoveCoordinator.swift:177-202` |
| F2 | **Accept says "done" while moving nothing.** If the history database won't open, the app falls back to a do-nothing accepter that reports success — the popup closes exactly as if the file moved. Breaks founder decision 1 (fail closed). | `UI/App.swift:84` |
| F3 | **A failed move shows the name the file doesn't have.** The row leads with the *intended* new name, so the user looks in Downloads for a file that is still under its old name. | `History/HistoryRowPresentation.swift:47` |
| F4 | **The failure message is drawn outside the popup.** The panel measures itself once and never resizes, so the longest error text — and sometimes the buttons under it — render off-window. Found independently by design and accessibility. | `UI/SuggestionPanel.swift:78-95` |
| F13 | **Nothing stops a second Accept after a move already succeeded**, so Return can start a move against a path the file has already left. This is the defect the hanging test was concealing. | `UI/PopupController.swift` |

### Honesty — the app tells the user something untrue

| ID | In plain words | Where |
|---|---|---|
| F5 | **"Clear history" wipes the history, then reports that it failed.** The delete commits, the compaction step throws, and the user is told nothing was cleared while the rows are gone. | `History/MoveHistoryStore.swift:418-434` |
| F6 | The launch cleanup can settle a history row belonging to a move that is still running. | `History/MoveCoordinator.swift:92-113` |
| F7 | A refresh wipes every honest message the move paths just wrote. | `History/MoveCoordinator.swift` |
| F8 | A successful undo whose history write fails leaves the row permanently wrong. | `History/MoveCoordinator.swift` |
| F9 | Claims are keyed by filename only, so one move retires another move's live claim. | `Watcher/AppCreatedFileClaims.swift` |
| F10 | Quitting during a move is unguarded. | `UI/App.swift` |
| F11 | "Moving…" is shown only in the cases where it is false. | `UI/PopupContentView.swift` |
| F12 | A `try?` swallows the error that decides whether the app moves files at all. | `UI/App.swift` |

### Accessibility — `a11y-architect` verdict: **BLOCK**

| ID | In plain words | Where |
|---|---|---|
| A2 | **Return probably fires the destructive button** in the Clear History dialog, wiping up to 200 undo records. Cancel is not marked as the default. | `UI/HistoryPane.swift:55-56` |
| A3 | Clear History announces nothing, and removing the footer on success destroys keyboard focus. | `UI/HistoryPane.swift:41-46` |
| A4 | Undo announces nothing either way, and the failure text isn't in the row's label — a VoiceOver user concludes the file went back when it did not. | `UI/HistoryPane.swift:220-222` |
| A5 | A move that *succeeds* announces nothing; the popup simply vanishes. | `UI/PopupController.swift:468-477` |
| A6 | **Esc is inert** in the completed state — violates locked founder decision 5. | `UI/PopupContentView.swift:207-215` |
| A7 | Five Undo buttons all read "Undo this move". | `UI/HistoryPane.swift:213` |
| A8 | Reduce Motion is ignored — two spinners that never stop. | `UI/PopupContentView.swift:199` |

### Design — `ui-designer` verdict: **BLOCK** (D1–D5 before commit)

| ID | In plain words | Where |
|---|---|---|
| D2 | Failure renders as an orange warning triangle; the design system says red on the sentence only, no icon. | `UI/PopupContentView.swift:258-267` |
| D3 | **"Open System Settings" button is missing** — locked founder decision 7. The failure state carries only a string, so the view can't tell the permission case apart. | `UI/PopupController.swift:481` |
| D4 | **Raw error codes reach the user.** A full disk reads "(errno 28: No space left on device)". | `History/HistoryRowPresentation.swift:95` |
| D5 | Failure sentences say "that folder", never its name. | `History/MoveRecord.swift` |
| D6 | A moved file stays in the dropdown and still offers to reopen a file that is gone. | `Watcher/DownloadsWatcher.swift` |
| D7 | The dropdown gained a visible second row per file, contradicting the mockup's promise that "nothing here looks different". | `UI/MenuContentView.swift:38-42` |
| D8 | Outcome lines render at ~3.9:1 contrast where the design system names them primary. | `UI/PopupContentView.swift` |

### The test suite

| ID | In plain words | Where |
|---|---|---|
| T1 | **`swift test` does not finish.** One test starts a second move that nothing ever completes, then waits for it forever. There is **no trustworthy green baseline** for this tree — the last recorded 231/231 predates the History pane. | `Tests/…/PopupControllerTests.swift:627` |
| T2 | **Five tests this milestone passed (or hung) against deliberately broken code.** A green suite is not evidence here. Mutation-check anything guarding user data: break it on purpose, confirm the test goes red. | project-wide |

</details>

---

## 🟡 Waiting on the founder

These cannot be closed by writing code. Each is a short manual check.

| # | What we need from you | Why only you can do it | Milestone |
|---|---|---|---|
| 1 | **Drop a real screenshot and a real invoice** into Downloads, against your *own* Screenshots and Invoices folders, and see whether the right destination is suggested. ~2 minutes. | The folder-matching threshold (0.80) was tuned on made-up files with stand-in summaries. Only your real files can prove it. Until then the number is **provisional**. | M4 |
| 2 | **Decide whether the app should tell you when its folder index is broken.** Today, if the index is corrupt it silently rebuilds and you just see an empty folder list. Fixing it means new UI, so it needs your approval on a mockup first. | It's a product call about how much to interrupt you. | M4 |
| 3 | **Turn on VoiceOver and check the popup speaks.** ~5 minutes. | Apple makes announcements from a non-activating panel unreliable, and code cannot prove your Mac actually spoke. If it's silent, the fix is a design change — **not** making the panel steal focus. | M5 |
| ~~4~~ | ~~**Accept one suggestion in the running app and watch a real file move, then undo it.**~~ | **Done 2026-07-30** — founder exercised M6 end-to-end and confirmed it works. | M6 |
| 5 | **D9/D10 — already decided, recorded for the trail.** You kept "Try again" on the failure button and the hold-open "OK" state after a changed move. No action needed; the missing second-Accept guard (F13) was a defect regardless, and is now fixed and mutation-checked. | — | M6 |
| 6 | **D7 — is one extra line per file in the dropdown acceptable?** The approved mockup promised "nothing here looks different", but the menu's plain text lines render as *disabled* menu items that keyboard and VoiceOver skip entirely — so an enabled "Review…" item is the only way those users can act on a file at all. It has been **narrowed** to appear only for files whose popup will *not* show on its own (dismissed, or overflowed the queue), which is where it is genuinely the only route. Your call whether that is close enough to the mockup, or whether you want it gone and the accessibility route solved another way. | It is a visible-design divergence, and you own those. | M6 |
| 7 | **Turn on VoiceOver and walk the History pane.** ~5 minutes. Undo now speaks on success *and* failure, Clear History announces, Esc works in every popup state, and the spinners stop under Reduce Motion — but none of that can be proved by code, only heard. | Same reason as check 3: macOS announcements can't be verified from inside the app. | M6 |
| ~~8~~ | ~~**The waitlist form says "you're on the list" and stores nothing.**~~ **Decided 2026-07-30: option C — deploy as-is.** The founder is using the Vercel URL to share the idea with people, not to acquire users, and is not treating signups as a list. The stub stays. **This decision is scoped to that use.** The moment the URL is promoted publicly, put in a launch announcement, or expected to collect anyone — it reverts to a blocker, and the fix is option A (honest "coming soon" copy, ten minutes) or B (a real vendor, needs approval and money). | Founder call, made. | Website |
| 9 | **Vercel plan.** Hobby is free but reserved for non-commercial use in Vercel's terms; Pro is $20/month. A pre-launch site with nothing for sale is a grey area. Flagged, not decided. A custom domain is a separate ~$10–40/yr spend. | Costs money. | Website |

---

## ⚪ Deferred on purpose

Not bugs to fix now — decisions to revisit when the trigger arrives.

| What | Trigger to revisit | Detail |
|---|---|---|
| **Stalled downloads can be announced early.** Stability means "size unchanged for 2 seconds"; a paused download with no `.crdownload` marker looks finished. **Files now actually move, so this limit is live, not theoretical.** | Before the next release build | [[Watcher]] |
| **Files are identified by name only** in the watcher — a file overwritten in place isn't re-announced. | Same as above | [[Watcher]] |
| **Cross-volume undo identity** needs `final_device`/`final_inode` columns (schema v3). F1's fix closes the same-volume case: a mismatched inode on the *same* device proves a stranger and Undo refuses. A cross-volume move legitimately changes the inode, so that half still trusts the path alone. | Schema v3 | [[History-Undo]] |
| **X12 / M23 — two registered folders sharing a leaf name defeat the risk-#4 identity cross-check.** The resolver verifies a folder id by comparing display names, so if the index is rebuilt and id 3 now points at a *different* "Receipts", the name still matches and the file goes to the wrong one. Closing it means carrying the folder's path (not just its name) from suggestion through to Accept — four files. Not blocking: it needs two same-named registered folders *and* an index rebuild. | Before the next release build, or the first time a user registers two folders with the same name | [[Folder-Index]] |
| Folder index: migration seam is a stub; no real ordered migration exists. | Before schema v2 or any embedding-model change | [[Folder-Index]] |
| Cross-language embedding mixing produces meaningless comparisons. | Before non-English support | [[Folder-Index]] |
| `embeddingUnavailable` shows "Can't access" instead of an honest "AI unavailable". | Needs founder-approved copy | [[Folder-Index]] |
| S1 deleted embeddings stay readable in `index.db` until next launch; S2 `*.corrupt-<uuid>` files are never cleaned up. | Release hardening | [[m6-final-review-findings]] |
| Security-scoped bookmarks, narrowest entitlements, index reset / uninstall cleanup. | Packaging | [[Folder-Index]] |

---

## 📦 Release checklist

Before any build leaves the founder's Mac:

- [ ] Verify no dev `print` remains on a release path (9 sites are `#if DEBUG` today — re-verify).
- [ ] Disable, or get fresh founder approval for, `FILE_ORGANIZER_WATCH_DIR` (the QA sandbox override).
- [x] Extraction dev-logging compiled out of release via `#if DEBUG` (done M5).
- [ ] Apple Developer account ($99/yr) for notarization — **costs money, needs founder approval**.

---

## Recently closed

| Date | What | Outcome |
|---|---|---|
| 2026-07-30 | **M6 signed off by the founder.** Founder check 4 — accept a suggestion in the running app, watch a real file move, then undo it. | Verified end-to-end on a real Mac: it works. M6 is closed. |
| 2026-07-30 | **M6 fix round — the whole blocking register.** Data safety F1–F4 + F13; honesty F5–F12; accessibility A2–A8; design D2–D8 (D7 narrowed, see founder check 6); Swift/DB hygiene X1–X11 (X12 deferred, X13 done). | Fixed. `swift test` **finishes** at 262/262 — the hang is gone and this is the first trustworthy baseline since the History pane landed. Release build clean; zero-network re-verified on the binary (`otool -L`, `nm -u`), and no dev prints or test seams in it. |
| 2026-07-30 | **T2 answered: 13 guards mutation-checked.** Each one broken on purpose, the test confirmed to go red, the code restored. F1 undo identity · F2 fail-closed seam · F3 failed-row name · F5 clear commit point · F6 reconcile cutoff · F7 problem ownership · F8 undo truth · F9 claim groups · F11 liveness · F13 second-accept guard · X8 no-op undo · D4 no error codes · D5 name the folder · A5 success announcement. | A green suite is now evidence for these fourteen. It still is not for anything else. |
| 2026-07-30 | F3's own fixture was masking F3 (it passed `originalName` and `finalName` identical — a rename that renames nothing, which a failed accept never produces) | Fixture re-pointed at differing names; the test now fails against the old code |
| 2026-07-30 | Duplicate copy of the "original couldn't be removed" warning sentence, and an unused folder-database status helper | Removed with founder approval; build green |
| 2026-07-29 | M6 round 1: three criticals (cross-volume copy could leave a file nowhere; launch reconcile could adopt a stranger's file; an `errno` read could report a failed move as success) | Fixed, each mutation-verified |

---

**Related:** [[milestones]] (what shipped) · [[decisions]] (why) · [[workflow]] (how we work) · [[learnings]] (what we won't relearn)
