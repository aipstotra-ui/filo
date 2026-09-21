# AI File Organizer — Overview

A macOS menu-bar app that watches your Downloads folder, understands each new
file with **AI that runs entirely on your Mac**, and quietly suggests a better
name and the right folder. You accept, edit, or dismiss — nothing moves without
your say-so, and everything is undoable.

**The promise:** your file contents never leave your machine. Ever. The app makes
**zero network calls**.

---

## Start here

| If you want to know… | Read |
|---|---|
| **What's open right now** | [[open-work]] — the one list |
| What already works | [[milestones]] |
| Why it's built this way | [[decisions]] |
| How the pieces fit | [[architecture]] |
| How the agent team works | [[workflow]] · [[agent-roster]] · [[system-map]] |

---

## The vault, in four folders

```
docs/
├── 00-Overview.md      ← you are here: the map
├── open-work.md        ← every open item, one list
├── product/            ← WHAT we're building
│   ├── architecture.md · milestones.md · decisions.md · design-system.md
│   └── modules/        ← one note per code folder
├── process/            ← HOW we build it
│   ├── workflow.md · agent-roster.md · system-map.md
│   └── engineering-rules.md · ai-engineering.md · learnings.md
├── milestone-work/     ← scratch, one folder per milestone
└── mockups/            ← HTML the founder approves before anything is built
```

**The rule:** the root of `docs/` holds the map and the open list — nothing else.
Milestone scratch lives in `milestone-work/<milestone>/` and is **distilled into
the permanent notes when that milestone closes**. A fact that survives only in a
closed milestone's folder is lost.

---

## Modules

Each mirrors a folder under `Sources/FileOrganizer/`, one-to-one.

- [[Watcher]] — notices new files in Downloads, waits until they're really finished
- [[Extraction]] — reads what's inside a file (PDF text, screenshot OCR…)
- [[AI-Engine]] — local model: summary + suggested filename + embedding
- [[Folder-Index]] — knows what lives in each target folder, picks the best destination
- [[Popup-UI]] — the floating suggestion panel and menu-bar UI
- [[History-Undo]] — the **only** code that moves files; logs every move, one-click undo

---

## The business plan

Full roadmap (build → demo video → waitlist → downloadable MVP → paid launch)
lives outside the repo: `~/.claude/plans/you-are-a-technical-rippling-lemon.md`.

The **marketing website** is a separate track with its own team and playbook:
[Web-Team-Playbook](../website/Web-Team-Playbook.md). Its code lives isolated in
`website/`, never mixed with the app.
