# Architecture

One pipeline, six modules. Each module is a folder under `Sources/FileOrganizer/` and has its own note in `docs/product/modules/` — the `[[links]]` here match the real code dependencies.

```mermaid
flowchart LR
    W[Watcher] -->|new stable file| E[Extraction]
    E -->|text snippet| A[AI-Engine]
    A -->|summary + name + embedding| F[Folder-Index]
    F -->|suggestion: name + folder| P[Popup-UI]
    P -->|user accepts| H[History-Undo]
    H -->|move + rename, logged| FS[(File System)]
```

## Flow in words

1. [[Watcher]] sees a new file land in `~/Downloads`, waits until it's fully written (size stable, not a `.crdownload` partial), then hands it on.
2. [[Extraction]] pulls a text snippet out of the file (PDF text, OCR for images, plain text; falls back to filename + metadata).
3. [[AI-Engine]] (Apple's built-in on-device model, FoundationModels) turns the snippet into a one-line summary, a suggested filename, and an embedding vector.
4. [[Folder-Index]] compares the embedding to its per-folder profiles and picks the best destination folder.
5. [[Popup-UI]] shows the suggestion. Accept / edit / dismiss. **Nothing happens without accept.**
6. [[History-Undo]] performs the accepted move/rename (collision-safe, atomic) and records it so one click puts everything back.

## Rules that keep it clean

- Modules only talk through small Swift protocols, in pipeline order — no reaching across.
- No network calls anywhere — the AI is built into macOS, nothing to download.
- Only [[History-Undo]] is allowed to actually move or rename files; every mutation goes through it so undo is always complete.

## Status

**All six modules exist and are wired.** [[Watcher]] → [[Extraction]] →
[[AI-Engine]] → [[Folder-Index]] → [[Popup-UI]] → [[History-Undo]];
`PipelineModel` in the UI module is the glue.

M1–M6 are committed, reviewed, and founder-verified (2026-07-30). `App.swift`
injects the real `MoveCoordinator`, so Accept moves real files; the M5 no-move
seam is gone. When `history.db` cannot be opened the seam refuses rather than
degrading silently — founder decision 1, fail closed. `swift test` runs green at
262/262.

Everything open: [[open-work]]. Milestone detail: [[milestones]].
