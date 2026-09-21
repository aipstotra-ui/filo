# AI File Organizer

A macOS menu-bar app that watches `~/Downloads`, understands each new file with **AI that runs entirely on-device**, and suggests a better filename + destination folder. The user accepts, edits, or dismisses — files only ever move on explicit accept, and every move is undoable.

**The product promise: no file content ever leaves the machine.** The app makes zero network calls. This is enforced by review (see `security-auditor` below), not just intended.

## Requirements

- macOS 26+ (the AI uses Apple's built-in FoundationModels on-device model)
- Apple Intelligence enabled in System Settings (without it the app still runs and degrades honestly to name-and-type handling)
- Xcode (for the Swift toolchain; the project is plain SwiftPM — no `.xcodeproj`)

## Build, run, test

```bash
./build.sh                        # swift build -c release
./.build/release/FileOrganizer    # runs the menu-bar app (Ctrl-C to quit)
swift test                        # full test suite
```

Smoke test: drop a PDF into `~/Downloads` → it appears in the menu-bar dropdown within ~5 s, shows "Reading…" → "Thinking…" → a suggested name (or an honest reason why not).

## Repo map

| Path | What it is |
|---|---|
| `Sources/FileOrganizer/Watcher/` | Detects new files in Downloads (debounced; ignores partial downloads) |
| `Sources/FileOrganizer/Extraction/` | Pulls a text snippet from a file: PDF text, image OCR, plain text, typed fallbacks |
| `Sources/FileOrganizer/AI/` | On-device model → summary + suggested filename + embedding; output sanitizers (injection defense) |
| `Sources/FileOrganizer/Index/` | SQLite index of user-chosen target folders; embedding match picks a destination (M4) |
| `Sources/FileOrganizer/UI/` | Menu-bar app, per-file pipeline state (`PipelineModel`), Settings |
| `Sources/FileOrganizer/History/` | The ONLY code allowed to move/rename files; powers undo (M6) |
| `Tests/FileOrganizerTests/` | Swift Testing suite — sanitizers, prompt fencing, matcher, folder scan, SQLite store, move/undo |
| `docs/` | All project documentation — **start at [docs/00-Overview.md](docs/00-Overview.md)** |
| `website/` | The marketing site. Separate track, never mixed with the app. |
| `.claude/agents/` | The Claude Code agent team that builds/reviews this repo (see CLAUDE.md) |
| `CLAUDE.md` | Working brief for AI-assisted sessions: locked decisions, current status, dev workflow |

## Architecture in one paragraph

One pipeline, module per folder, connected only through small Swift protocols in pipeline order: **Watcher → Extraction → AI-Engine → Folder-Index → Popup-UI → History-Undo**. `PipelineModel` (UI module) is the glue that carries a file through the stages and publishes per-file state to the menu. Every stage has a timeout and an honest degraded state — the UI never lies about what happened. Full picture with diagram: [docs/product/architecture.md](docs/product/architecture.md).

## Where things stand

M1–M6 are complete, tested, and multi-agent-reviewed: watcher, extraction, local AI, folder index, suggestion popup, and **log & undo**. Accepting a suggestion moves a real file, records it before it happens, and offers one-click undo. The suite runs green at 262/262, and the guards protecting user files were mutation-checked — deliberately broken, each confirmed to fail, then restored. The founder verified M6 end-to-end on a real Mac on 2026-07-30.

- Everything open, in one list: **[docs/open-work.md](docs/open-work.md)**
- Milestone-by-milestone detail: [docs/product/milestones.md](docs/product/milestones.md)

## How this repo is developed

- The code is developed with Claude Code through a pipelined agent team (`.claude/agents/`): planner → designer mockup (founder approves) → TDD-first builder → QA → parallel specialist reviewers → simplifier → docs. The pipeline is documented in [docs/process/workflow.md](docs/process/workflow.md); who's who is in [docs/process/agent-roster.md](docs/process/agent-roster.md); a one-page picture of both is [docs/process/system-map.md](docs/process/system-map.md).
- `docs/` doubles as the founder's Obsidian vault — plain Markdown with `[[wiki-links]]`, one note per code module. `product/` is what we're building, `process/` is how we build it. **Update docs in place; there is no separate copy.**
- Engineering standards (error handling, concurrency, security, testing) are codified in [docs/process/engineering-rules.md](docs/process/engineering-rules.md); every decision that shaped the code is one line in [docs/product/decisions.md](docs/product/decisions.md); debugging lessons live in [docs/process/learnings.md](docs/process/learnings.md).
