# Milestone working docs

Scratch that outlived its session. Plans, review findings, and specs for a
milestone **while it is being built** — one folder per milestone.

**This is not where knowledge lives.** When a milestone finishes, its durable
facts move out to their permanent homes and the folder here becomes history:

| What it is | Where it belongs when the milestone ends |
|---|---|
| How a module works | `docs/product/modules/<Module>.md` |
| Why we chose something | [[decisions]] |
| What shipped, what's open | [[milestones]] |
| Anything still unresolved | [[open-work]] |
| A lesson worth not relearning | [[learnings]] |
| How it should look | [[design-system]] |

If a fact only exists in here after a milestone closes, it is **lost** — nobody
reads a finished milestone's scratch folder.

## Why this folder exists

M6 produced five working documents that sat loose in the vault root and buried
the notes that actually matter — and while they sat there, [[design-system]]
drifted out of sync with the built UI without anyone noticing. Rule of thumb:
**the root of `docs/` holds only the map and the open-work list.** Anything tied
to one milestone goes in here.

## Naming

Keep filenames distinctive and prefixed with the milestone — `m6-status.md`, not
`status.md`. Obsidian resolves `[[wiki-links]]` by filename anywhere in the
vault, so a generic name collides across milestones and a distinctive one never
breaks when moved.

## What's here

- `m6/` — Log & undo. **Still active** — the fix round hasn't run yet.
  `m6-final-review-findings.md` holds the full technical detail of every finding;
  the tracked, prioritised list of what's actually open is [[open-work]].
