# Folder-Index (built in M4 — 2026-07-18)

Knows what lives where, so a suggestion can name a destination. The user picks target folders in Settings; the app profiles each one (on-device, read-only) and stores the profile in a small local SQLite index. When [[AI-Engine]] produces a suggestion, the file's vectors are compared against the folder profiles and the best-fitting folder — if any clears the bar — rides along as the destination shown in [[Popup-UI]] (the menu for now).

**Nothing here moves a file.** Moving is [[History-Undo]] (M6). This module only ever *reads* target folders and *shows* a suggested destination.

## Files (`Sources/FileOrganizer/Index/`)

- `FolderProfile.swift` — the shared value types: `FolderVector` (a `kind` tag + unit-length `[Float]`), `FolderProfile` (path, name, vectors, sampled names, `totalFileCount`, typed `contentSampleFailures`; `contentReadCount` is derived from the `.content` vectors so it can't drift).
- `FolderProfileBuilder.swift` — scans one folder and builds its profile. Strictly read-only (a before/after snapshot is pinned in tests). Reads file **names** plus **content-samples up to 3 recent files** through the existing [[Extraction]] seam (founder decision 2026-07-18). Embeds name / filenames / content template texts via [[AI-Engine]]'s `EmbeddingProviding`, normalizing each vector once here.
- `FolderMatcher.swift` — pure math, no I/O. Cosine (dot product on unit vectors) of each query vector against each candidate's vectors; a candidate scores as its best pair. Non-unit or dimension-mismatched vectors are **excluded, never renormalized**. Verdict: `.match(folderID, score)` / `.noGoodMatch` / `.noFoldersConfigured`. Threshold **`0.80` (PROVISIONAL** — calibrated 2026-07-19 against real NLEmbedding on a synthetic set; real-folder + real-AI QA is the sign-off gate, see [[milestones]]), ties within `0.02` → earliest-added folder. Pinned by `FolderMatchAcceptanceTests` (live NLEmbedding, no mocks).
- `FolderIndexStore.swift` — the SQLite layer, an `actor` owning one connection (raw `import SQLite3`, no third-party package). WAL, busy-timeout, foreign keys on. Every value is bound (`sqlite3_bind_*`), never interpolated; every return code checked → typed `StoreError`; every statement finalized. Creates its directory `0o700` and file `0o600`. A corrupt or unreadable DB is moved aside intact and a fresh one started (`OpenOutcome.recoveredFromCorruption`); an unknown *future* `user_version` is refused without touching the file.
- `FolderRegistry.swift` — `@MainActor ObservableObject` that the UI binds to. Holds the list of `RegisteredFolder`s with live status, validates and adds folders (`NSOpenPanel`; rejects a duplicate or `~/Downloads` itself), runs scans off-main, persists results, and re-derives honest status at launch from disk (a moved/renamed folder is followed via a stored bookmark; a gone one shows "Folder missing").

## Schema (`user_version = 1`)

```sql
CREATE TABLE folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    canonical_path   TEXT NOT NULL UNIQUE,   -- symlink-resolved absolute path
    display_name     TEXT NOT NULL,
    total_file_count INTEGER NOT NULL,        -- "34 files" in the status line
    bookmark         BLOB,                     -- survives folder rename/move
    status           TEXT NOT NULL DEFAULT 'indexed',
    last_scanned_at  REAL
);
CREATE TABLE folder_vectors (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
    position  INTEGER NOT NULL,               -- preserves a profile's vector order
    kind      TEXT NOT NULL,                  -- FolderVectorKind.rawValue
    dimension INTEGER NOT NULL,               -- validated on read
    embedding BLOB NOT NULL                   -- Float32, little-endian
);
```

The index lives at `~/Library/Application Support/AI File Organizer/index.db`. It stores **only** folder paths, display names, counts, bookmarks, and embedding blobs — never raw file content and never extraction snippets. It is derived data: if it is ever lost or corrupt, the honest recovery is to rescan the folders.

## Folder-matching flow (per file)

1. A successful AI suggestion arrives in `PipelineModel` and is shown immediately; the destination attaches asynchronously (founder decision: **no AI suggestion → no destination**, so matching never runs on the degraded path).
2. Query vectors are built off-main: the suggestion's snippet embedding plus fresh embeddings of the AI summary and of the original filename, each unit-normalized.
3. `FolderMatcher` scores them against `registry.matchCandidates` (only `.indexed` folders — missing/inaccessible ones never match).
4. Above threshold → "→ 📁 *Folder*"; folders exist but none fits → "No folder fits — leaving it in Downloads"; otherwise the row stays quiet. A 10 s backstop keeps a row from hanging on a pending destination; late results are dropped.

## Known issues (deferred from the M4 review round, 2026-07-19)

The 6-reviewer round ran clean on the privacy promise and found no data-loss or injection bug (matching only *suggests*; nothing moves). The contained correctness fixes were applied; these are the ones deliberately deferred, each because it needs founder/design input or belongs to a later milestone:

- **Index-health is not surfaced to the user** (the biggest finding — 3 reviewers). When the DB is corrupt/unreadable at launch the store recovers (moves the bad file aside, rebuilds) and reports `OpenOutcome.recoveredFromCorruption`, but nothing reads that: the user just sees an empty folder list, and "running in memory" mode is invisible. Also, one un-decodable vector row currently fails the *whole* `allProfiles()` load. Proper fix (a published index-health state + a one-line honest notice + per-folder-resilient load) touches UI → **needs a founder-approved mockup** before building.
- **`embeddingUnavailable` → shows "Can't access"** instead of an honest "AI unavailable" status. Rare in practice (NLEmbedding, not FoundationModels, drives profiling and is ~always present on macOS 26), but the label is misleading. Needs a new `FolderStatus` case + founder-approved copy.
- **Migration seam is a stub** — the `CREATE … IF NOT EXISTS` + version-stamp path won't run a real `ALTER`/rebuild on a version bump and isn't transactional; no embedding-model identity is recorded, so the documented MLX-embedding swap could leave mixed-dimension vectors. Also the missing `folder_vectors(folder_id)` index (negligible at this scale) belongs here. Land a real ordered migration before schema v2 or any embedding-model change.
- **Cross-language embedding mixing** — per-text language detection can compare vectors from different NLEmbedding language models (meaningless cosine). Latent for an English-only user; pin to English or tag vectors by language before non-English support.
- **Later-milestone / packaging**: security-scoped bookmarks + narrowest entitlements, an index reset / uninstall-cleanup affordance, and WAL-sidecar perms — all M5 packaging (already on the release checklist). Plus UX polish: re-match a file when its target folders finish scanning; scan-`Task` cancellation on remove.

Full reviewer detail is in the 2026-07-19 review round; the [[decisions]] log records the calibration.

## Status

Built, unit-tested, **live-QA'd and reviewed** (2026-07-19, 66 tests green). Threshold calibrated to **`0.80` (provisional)** against real NLEmbedding; the real on-device AI path was verified end-to-end (`LiveAISmokeTests`). Remaining before full M4 sign-off: the founder's **real-folder acceptance test** (screenshot → Screenshots, invoice → Invoices) in the live app, and a founder decision on the deferred index-health surfacing above. See [[milestones]].
