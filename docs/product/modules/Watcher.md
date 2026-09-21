# Watcher

Notices new files landing in `~/Downloads` and only announces them once they're **complete** — a browser writes a download over many seconds, and grabbing it early would mean reading half a file.

## How it works

1. Keeps a directory event source (`DispatchSource`) open on `~/Downloads` — macOS pings it whenever the folder's contents change.
2. On each ping, diffs the folder against the last known file list to find newcomers.
3. Ignores hidden files and in-progress partials (`.crdownload`, `.download`, `.part`, `.tmp`).
4. Puts newcomers in a "pending" list and checks their size every second; only when the size has stopped changing for 2 checks is the file declared **stable** and announced.

## Code

- `Sources/FileOrganizer/Watcher/DownloadsWatcher.swift` — event source, diffing, stability debounce. Exposes an `onNewFile` hook: each announced file is handed to `PipelineModel` (see [[Popup-UI]]), which starts [[Extraction]]. Dev/QA only: the `FILE_ORGANIZER_WATCH_DIR` env variable points the watcher at a sandbox folder instead of the real Downloads (on the M6 release checklist — see [[milestones]]).
- `Sources/FileOrganizer/Watcher/FileEvent.swift` — the record it emits (name, path, size, date)
- `Sources/FileOrganizer/Watcher/LogSanitizer.swift` — shared dev-log sanitizer: strips control characters (ANSI escape tricks) and folds line breaks before any filename or snippet preview is printed. Filenames are as attacker-controlled as file contents. Lives here so both Watcher and [[Extraction]] can use it in pipeline order.

## Known limits — ⚠️ these are now LIVE, not theoretical

These were accepted in M1 with the note "revisit before files are moved".
**Files are moved now** (M6 wires the real mover into Accept), so the condition
that deferred them has arrived. Tracked in [[open-work]] › *Deferred on purpose*.

- **Stalled downloads can be announced early.** Stability = "size unchanged for 2 seconds". A download that merely pauses that long (slow server, paused transfer) with no `.crdownload` safety net (curl, wget) is announced while incomplete. Any module that *moves* a file must re-verify stability or check for open write handles first.
- **Files are identified by name only.** A file overwritten in place under the same name is not re-announced; renaming an old file inside Downloads announces it as "new". Harmless while the app only displays names — but the app no longer only displays names. Switch to (name, size, modified-date) or inode identity.
- Partly mitigated downstream: the mover re-stats the source and checks it is a regular file before touching it, and `renamex_np(RENAME_EXCL)` makes the kernel refuse to overwrite anything. That narrows the blast radius; it does not close either limit.
- If the watched folder itself is deleted or renamed, the app stops watching and shows "Lost access — restart the app" rather than trying to re-attach.

## Talks to

- Emits stable-file events consumed by [[Popup-UI]] (listed in the menu) and, via its `onNewFile` hook, by [[Extraction]] (since M2).
