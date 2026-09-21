# Agent roster — who's who

Every agent that works on this project, what it owns, and when it runs. The
definitions live in `.claude/agents/*.md`. The order they run in: [[workflow]].
The picture: [[system-map]].

**Two facts that shape everything:**

1. **The founder talks only to the main session.** The main session is tech lead
   and the single orchestrator for both teams.
2. **Subagents cannot launch subagents.** There are no manager agents. Every
   agent gets a self-contained brief from the tech lead, starts with zero
   context, and reports back to the tech lead.

**Report-only vs. editing** is the most important distinction below. A
report-only agent has no write tools *by design* — it cannot quietly "fix"
something and hide a judgement call from the founder.

---

## Engineering team — builds the macOS app

### Writes code

| Agent | Owns | Runs at |
|---|---|---|
| `swift-builder` | All feature implementation. The only agent that writes app Swift. | Step 3, and every fix loop |
| `tdd-guide` | Tests **first** for data-guarding logic — watcher/extraction gates, name sanitization, and above all move/undo | Step 3, before `swift-builder` |
| `swift-build-resolver` | **Only** unblocking a broken build. Surgical fixes, never feature work. | On a build failure that isn't a quick fix |
| `code-simplifier` | Behaviour-preserving clarity passes. Bar: *could the founder follow this file with the module note open beside it?* | Step 6, after reviewers pass |

### Reports only — never edits

| Agent | Lane | Runs at |
|---|---|---|
| `planner` | Task breakdown, risks, implementation order | Step 1 |
| `code-critic` | App-level correctness, **data-loss risk** (highest severity) | Step 5, every Swift diff |
| `swift-reviewer` | Swift idiom: force-unwraps, ARC cycles, concurrency/`Sendable` | Step 5, every Swift diff |
| `silent-failure-hunter` | Swallowed errors, empty catches, misleading fallbacks | Step 5, especially on file-touching code |
| `security-auditor` | The privacy promise — zero network, no content in logs, safe file ops | Step 5, and before any release |
| `ai-reviewer` | Prompt construction, injection defense, model lifecycle | Step 5, **only for AI-module diffs** |
| `database-reviewer` | Local SQLite: bound values, checked return codes, schema lifecycle, index privacy | Step 5, **only for diffs touching a store** |
| `a11y-architect` | VoiceOver, keyboard, focus, motion, contrast — macOS/SwiftUI only | Steps 2 and 7, for UI |

### Mixed

| Agent | Owns | Runs at |
|---|---|---|
| `ui-designer` | HTML mockups in `docs/mockups/` (before) and verifying the built UI matches (after). Owns [[design-system]]. | Steps 2 and 7 |
| `qa-tester` | Builds, runs `swift test` as a **hard gate**, exercises real behaviour with synthetic files, verifies the milestone checklist | Step 4 |
| `docs-keeper` | Brings `docs/` and `CLAUDE.md` in line with the code; reconciles [[open-work]]; appends to [[learnings]] | Step 8 |

---

## Web team — builds the marketing site

Charter is **marketing-only**. Playbook:
[Web-Team-Playbook](../../website/Web-Team-Playbook.md).

| Agent | Owns |
|---|---|
| `web-copywriter` | The words, in the app's calm factual voice. Writes only in `website/`. |
| `web-builder` | The static HTML/CSS/JS. Writes only in `website/`. |
| `web-claims-auditor` | Checks every public claim against what the app really does, and the waitlist's handling of real emails. Report-only. |

**Hard boundary:** web agents may *read* `Sources/` and `docs/` to keep claims
accurate; they never *write* outside `website/`. The app pipeline never touches
`website/`.

**Cross-team:** `planner`, `code-simplifier`, `docs-keeper` serve both teams —
their brief must say which team's work it is.

---

## gstack skills (tooling, not agents)

Reused rather than rebuilt. Design and QA heavy lifting:
`/design-consultation`, `/design-html`, `/design-review`, `/qa`, `/browse`,
`/ship`, `/land-and-deploy`, `/canary`, `/freeze`.

`a11y-architect` stays strictly in the accessibility lane — visual and UX
critique belongs to the `/design-*` skills.

---

## Which agents does my change need?

| The diff touches | Reviewers |
|---|---|
| Anything Swift | `code-critic` + `swift-reviewer` |
| User files (move, rename, delete, watch) | + `silent-failure-hunter` + `security-auditor` |
| The AI module or a prompt | + `ai-reviewer` |
| A SQLite store | + `database-reviewer` |
| UI | + `a11y-architect` + `ui-designer` |
| Public claims on the website | `web-claims-auditor` |

A milestone gets all of them, in parallel, once.

---

## Adding or changing an agent

New `.claude/agents/*.md` files **only register at session start** — a
same-session addition needs a general agent instructed to read the definition
file directly.

Any new agent needs: a stated lane, an explicit report-only-or-edits decision,
a named place its findings land ([[open-work]]), and a row in this table.
Adoption of anything from an external framework is a founder decision — see the
provenance guardrail in [[workflow]].

---

**Related:** [[workflow]] · [[system-map]] · [[open-work]] · [[engineering-rules]]
