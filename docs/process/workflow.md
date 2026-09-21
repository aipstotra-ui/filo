# Workflow — how work actually gets done

The founder (CEO) talks only to the **main session**, which acts as tech lead and
orchestrates every agent. Subagents cannot launch other subagents, so there are
no manager agents and never will be — a "team" is an organisational lens, not a
chain of command.

Who each agent is and when it runs: [[agent-roster]]. The picture: [[system-map]].

---

## Session boundaries — run these every time, no exceptions

**Why this exists.** Docs drift silently. On 2026-07-30 an audit found `README`
claiming M6 wasn't built, `ai-engineering` still expecting a model download the
FoundationModels switch had made impossible, and `architecture` describing an
Accept seam that no longer existed — none of it wrong on the day it was written.
Drift happens at session boundaries, and the worst boundary is the one nobody
plans: a `/clear`, a context limit, a closed laptop. **A session that ends badly
must leave the vault no less true than it found it.**

### OPEN — first thing, before any work

1. Read [[open-work]]. It is the state of the world.
2. **Verify it against reality, don't trust it.** Three cheap checks:
   `git status --short` (is the tree what the register implies?), `git log -1`
   (did the last session commit what it said?), and — if the work touches
   `Sources/` — does `swift test` still finish and pass?
3. **If reality and the register disagree, fix the register first**, in its own
   turn, before starting anything. A stale register is worse than no register:
   it gets believed.
4. If **⚡ In flight** below is non-empty, that is a previous session that was
   cut off. Read it, decide whether to finish or abandon that work, and clear
   the section either way.

### DURING — checkpoint at seams, because "the end" may never arrive

Write to disk **when a fact becomes true, not when the session finishes**.

- A reviewer finding gets a row in [[open-work]] **the same turn it arrives**.
- A decision gets a line in [[decisions]] **the turn it is made**.
- Starting anything that would be expensive to re-derive — a multi-file refactor,
  a bisect, a fix round — add one line to **⚡ In flight** in [[open-work]] first:
  what you're doing, and the one thing the next session would otherwise have to
  work out again. Clear it when the work lands.

That last rule is the whole answer to "what if the session dies". Nothing else
survives an abrupt end; a file on disk does.

### CLOSE — whether the work finished, stalled, or was interrupted

Walk this list. It is short and fixed on purpose, so it can't be half-done.

| File | Update it when |
|---|---|
| [[open-work]] | **Always.** Items closed → *Recently closed* with the date and what proved it. Items opened → the right table. **⚡ In flight** → cleared or rewritten to say exactly where you stopped. |
| [[milestones]] | A milestone's status moved (built / reviewed / committed / signed off) |
| [[decisions]] | Anything was decided, or a locked decision was narrowed or superseded — one line, newest at the bottom, with the *why* |
| `docs/product/modules/*.md` | A module's real behaviour changed. The doc describes what the code does **now** — including the limitations, which are the part that rots first |
| `CLAUDE.md` → *Current state* | Its one paragraph is no longer true. This is the file every session reads first; a wrong line here misleads every future session |
| [[learnings]] | Something was learned that would otherwise be relearned the expensive way |
| `.claude/agents/*.md` | A brief states a fact that just changed — a test baseline, a locked decision, a module's behaviour. **The most dangerous stale doc is one an agent reads**: a subagent briefed on the old world applies the old world confidently and never pushes back. `qa-tester` was still told "`swift test` currently does not finish" *after* it had been fixed |

Then say, in the founder-facing summary, **which of those you touched** — so a
skipped one is visible rather than silent.

**Finish with the consistency sweep**, because each doc is only ever read alone
and none of them looks wrong by itself:

```bash
grep -rniE "not committed|not yet|fix round (is )?open|does not finish|current scope|next scheduled" --include="*.md" .
```

Every hit is either still true, correctly marked as history, or a bug. This is
what caught four stale claims at M6 close, in `README`, `architecture`,
`milestones`, and an agent brief.

**Interrupted is not an excuse, it is the case this list is for.** If you are out
of room or being stopped, spend the remaining budget on this list rather than on
one more edit. Half-finished code plus an accurate register is recoverable;
finished code plus a stale register is how the 2026-07-30 audit happened.

---

## Step 0 — the scope gate (decide this FIRST)

The full pipeline is expensive: ten-plus cold-start subagents, each re-reading
context, parallel reviewers multiplying it. Match the process to the change.

| Change | Path |
|---|---|
| A **milestone**, or anything touching **user files**, the **AI prompt/output path**, or **move/undo** | **Full pipeline** below. A missed bug here loses data or breaks the privacy promise. |
| A bug fix, copy tweak, refactor, doc edit, single-file change | **Lightweight path**: main session does it directly (`tdd-guide` first if it guards data), then runs **only the 1–2 reviewers that apply** — an AI-output change → `ai-reviewer`; a file-move change → `code-critic`. Skip the planner/designer/simplifier/docs ceremony. |
| Genuinely unsure | Ask the founder in one plain sentence whether it's "big" or "small". |

---

## The full pipeline

Run this for every milestone. **The founder will not ask for it** — the tech lead
runs it unprompted. Give every agent a self-contained brief naming the specific
files it needs; they all start with zero context.

**1 · Plan** — `planner` breaks the milestone into steps with risks and edge
cases. Product questions go to the founder in plain language, never jargon.

**2 · Design** — `ui-designer` mocks up new UI as self-contained HTML in
`docs/mockups/`. For design-critical UI, add a gstack design pass
(`/design-consultation` or `/design-review`) for look and UX, and `a11y-architect`
for an accessibility spec (VoiceOver, keyboard, focus, motion, contrast).
→ **Founder approves the mockup.** This is the only mid-pipeline founder
touchpoint.

**3 · Build** — `swift-builder` implements against [[engineering-rules]].
`tdd-guide` writes tests **first** for anything guarding user data: watcher and
extraction gates, AI output sanitization, and above all move/undo. If the build
breaks and isn't a quick fix, hand it to `swift-build-resolver` — surgical build
fixes only, never feature work.

**4 · QA** — `qa-tester` builds, runs `swift test` (**hard gate**), and verifies
against the milestone checklist in [[milestones]].

**5 · Review — all in parallel**

| Agent | Lane |
|---|---|
| `code-critic` | app-level correctness, data-loss risk |
| `swift-reviewer` | Swift idiom: force-unwraps, concurrency, ARC |
| `silent-failure-hunter` | swallowed errors, misleading fallbacks |
| `security-auditor` | the privacy promise |
| `ai-reviewer` | **only for AI-touching diffs** — see [[ai-engineering]] |
| `database-reviewer` | **only for diffs touching a SQLite store** |
| `a11y-architect` | **only for UI carrying an accessibility spec** |

Findings go back to `swift-builder` **and onto [[open-work]] the same turn they
arrive**. On each re-review loop, re-run **only the reviewer whose finding was
just fixed** — not the whole round. Loop until clean; usually one or two passes.
Don't pad it.

> **Reviewers earn their cost through independent convergence, not coverage.** A
> finding one reviewer sees is worth checking; one that three see independently
> is real. When reviewers disagree, resolve it against the **locked founder
> decision** in [[decisions]] — never by reviewer seniority.

**6 · Simplify** — `code-simplifier` makes a behaviour-preserving clarity pass.
Build must still pass.

**7 · Verify the build matches the design** — `ui-designer` confirms the built UI
matches the approved mockup; `a11y-architect` audits it against its spec
(report-only). Gaps go back to `swift-builder`.

**8 · Document & commit** — `docs-keeper` updates `docs/`, reconciles
[[open-work]], and appends anything learned to [[learnings]] → tech lead commits.

**Then: stop.** Standing founder rule — check in after every milestone.

### What the founder sees

Only three things: **mockups to approve**, brief progress notes, and a final
plain-language summary. Not the pipeline's internal chatter.

---

## Standing rules that override everything

1. **Privacy is the product.** Zero network calls, ever. No file content in logs.
   Any networking is a critical finding.
2. **Files move only on explicit accept**, and every move must be undoable.
3. **Nothing that costs money or carries security implications proceeds without
   explicit founder approval.**
4. **Stop and check in after every milestone.**
5. **A green test suite is not proof.** Five tests this project have passed
   against deliberately broken code. Mutation-check anything guarding user data:
   break it on purpose and confirm the test goes red.

---

## Where a document goes (enforced)

The M6 mess is why this rule exists — five loose milestone files buried the seven
notes that mattered, and a design doc drifted out of sync with the built UI.

| Kind of note | Home |
|---|---|
| What we're building, how it works, why | `docs/product/` |
| How we work — pipeline, rules, lessons | `docs/process/` |
| Everything currently open | `docs/open-work.md` |
| Scratch for one milestone — plans, findings, specs | `docs/milestone-work/<milestone>/` |
| Mockups | `docs/mockups/` |
| The marketing site and its playbook | `website/` (never mixed with the app) |

- **The root of `docs/` holds only the map and the open-work list.** Never add a
  milestone file there.
- **When a milestone closes, distil its scratch into the permanent homes above**,
  then leave the folder as history. *A fact that exists only in a closed
  milestone's folder is lost.*
- Mark superseded sections **in place** rather than deleting them — the reasoning
  stays worth reading, the instruction does not.
- Obsidian resolves `[[wiki-links]]` by filename anywhere in the vault, so moving
  a note never breaks links. Keep filenames distinctive (`m6-status.md`, not
  `status.md`).

---

## Token hygiene (the founder is watching cost)

- **Start a fresh session (`/clear`) at each milestone boundary**, after a commit.
  One endless session re-processes its whole history every turn. `CLAUDE.md`,
  `docs/`, memory, and git history are the durable memory — nothing is lost.
- **Compact at task seams, never mid-task.** Good seams: after research before
  implementing, after a debugging detour, after a dead end. Bad: mid-implementation,
  where you'd lose the file paths and half-finished state you're holding. A compact
  keeps `CLAUDE.md`, `docs/`, memory, git, and on-disk files; it drops intermediate
  reasoning and file contents. Write anything important to a doc *first*.
- **Tight briefs.** Name the specific files an agent needs — never "read the vault".
  `[[wiki-links]]` are navigation for humans, not a reading list for agents.
- **Re-run one reviewer, not the round.**
- **Don't re-derive.** If it's already in [[decisions]], it's decided.

---

## The two teams

Both are orchestrated by the same main session. They never mix.

**Engineering team** — builds the macOS app. The pipeline above.

**Web team** — builds the marketing site. Lives entirely in `website/`; its own
lean pipeline, scope gate, and approval gates are in
[Web-Team-Playbook](../../website/Web-Team-Playbook.md). Web agents may *read* the
app and `docs/` to keep public claims accurate, but only ever *write* inside
`website/`. Run gstack `/freeze website/` during website sessions to enforce that.

**Cross-team:** `planner`, `code-simplifier`, `docs-keeper` serve both — tell them
which team's work they're on.

---

## Provenance guardrail

The agents and always-on standards were adapted from
[affaan-m/ECC](https://github.com/affaan-m/ECC) (MIT) — every file hand-vetted,
rewritten to this project's scope, project-local only. **ECC's installer, hooks,
MCP servers, and global configs are deliberately NOT installed; adding any
executable or global surface needs fresh founder approval.** The dated adoption
history is in [[decisions]]. A 2026-07-23 re-audit found little new machinery
worth importing — don't re-mine ECC without a specific need.

---

**Related:** [[agent-roster]] · [[system-map]] · [[engineering-rules]] · [[open-work]] · [[decisions]]
