# History-Undo

The **only** module allowed to touch the file system. It performs the move or
rename that [[Popup-UI]]'s Accept asks for, records it before it happens, and
offers one-click undo afterwards. Nothing else in the app writes, moves, or
deletes a user's file.

Built in M6. See [[milestones]] for status.

## The files

| File | What it does |
|---|---|
| `FileMover.swift` | The syscalls. Moves or renames one file, never overwriting anything. |
| `MoveDestinationResolver.swift` | Turns "folder #7" into a real, still-valid, still-writable directory — or an honest refusal. |
| `MoveHistoryStore.swift` | `history.db`. The record of every move, and the only thing that makes undo possible. |
| `MoveCoordinator.swift` | The order of operations: record → move → settle. Also undo, launch reconcile, prune, clear. |
| `MoveRecord.swift` | The row shape, the typed failures, and every user-facing sentence. |
| `HistoryRowPresentation.swift` | Turns a row into the three lines the History pane shows. Pure, and unit-tested. |

The UI lives in `UI/HistoryPane.swift` (the History tab in Settings), not here.

## The one rule that shapes everything

**Write the intent first, then move.** A move that happened but wasn't recorded
is a move the user can't undo — so the row is written *before* the syscall, and
if the row can't be written the file is not touched at all (founder decision 1).
The cost is a possible orphan row when the app dies mid-move; that is repaired
by the launch reconcile, and an orphan row is a far cheaper failure than an
unrecorded move.

## How a file actually gets moved

1. **Resolve** the destination. The folder must still exist, still be registered,
   still be a directory, and still be writable. If it's *gone* → rename in place
   in Downloads and say why (decision 2). If it's **blocked by macOS privacy** →
   hard failure with an "Open System Settings" route; no move, no rename
   (decision 7).
2. **Record intent** — an `inProgress` row carrying where the file is, where it's
   going, and the source's `(device, inode)` identity.
3. **Move** — `renamex_np` with `RENAME_EXCL`, so the kernel itself refuses to
   overwrite an existing file. Across volumes, `copyfile` with `COPYFILE_EXCL`,
   then delete the source **only after the copy is verified**.
4. **Settle** the row with the name the file *actually* got — which may differ
   from the one requested, if the name was taken.

### Things that were learned the hard way here

- `renamex_np(RENAME_EXCL)` returns **0**, not `EEXIST`, for a self-rename.
- A pure case change (`report.pdf` → `Report.pdf`) or an NFD→NFC change also
  returns 0 — so the mover must **not** pre-check with `FileManager.fileExists`,
  which is case- and normalization-insensitive on APFS, or a legitimate case-only
  rename gets deduped into `Report 2.pdf`.
- `errno` must be captured **inside** the `withCString` closure. Read after the
  closure unwinds it can come back 0, turning a failed move into a reported success.
- A verified cross-volume copy must never be deleted because the *source* delete
  failed — that leaves the file in neither place.

## Collisions

The app never overwrites. If the chosen name is taken it walks a Finder-style
ladder — `report.pdf`, `report 2.pdf`, `report 3.pdf` — bounded at 50 attempts,
then fails typed rather than guessing forever. Names are held to a 255-**byte**
budget (not characters), with the extension preserved and emoji grapheme clusters
never split.

## Undo

Undo runs the same mover backwards, so it inherits the same no-overwrite
guarantee: if something has since taken the original name, undo dedupes rather
than clobbering, and says so.

Undo is offered only on rows whose state proves it's safe. A row whose outcome
the app can't establish says so in words and offers no button — a greyed-out
button that never explains itself is worse than a sentence.

### Identity, and the half of it that is deferred

Undo checks that the file at the remembered path is **the same file**, not merely
something with the same name. Without that check, deleting a moved file and later
filing an unrelated `report.pdf` into that folder by hand — ordinary housekeeping
— left the row still offering Undo, and Undo relocated the stranger's file into
Downloads and renamed it. Retention is 200 rows, not 200 hours, so the row is
still there months later. (F1, fixed and mutation-checked.)

**The check closes the same-volume case only, and that is deliberate.** A row
stores the *source's* `(device, inode)`, read a moment before the move. A
same-volume move keeps both numbers, so a mismatch proves the file is a stranger
and Undo refuses. A **cross-volume** move is a copy, so the file legitimately has
a new inode — refusing on that basis would break every cross-volume undo. The
rule is therefore: refuse only when the device matches and the inode does not.

> **Deferred to schema v3:** closing the cross-volume half needs `final_device`
> and `final_inode` columns, written at `finalize` time. Until then, a
> cross-volume undo trusts the path alone. Tracked in [[open-work]] under
> *deferred on purpose*.

### Deliberate limitations — chosen, not overlooked

Three things undo does *not* do. Each was a considered call during M6; none is a
bug report waiting to be filed.

- **Undo is not intent-first.** The forward move writes its row before touching
  the file; undo does the reverse — it moves, then records. No data is lost
  either way, but the crash-consistency guarantee described above covers the
  forward path only. A crash mid-undo can leave the row saying `moved` when the
  file is already back in Downloads; the launch reconcile is what catches it.
- **An undone row cannot name the filename it had while it was filed away.**
  `markUndone` overwrites `final_name` with the restored name, so a row reads
  "had been in Invoices" rather than "had been *2026-05 Chase statement.pdf* in
  Invoices". Fixing it properly needs a new column and a schema migration — worth
  doing eventually, not worth doing inside M6.
- **No per-row "can't undo, that file moved" notice before you click.** Detecting
  it would mean a disk probe for every visible row on every redraw, which is
  exactly the main-thread file I/O the review flagged. Instead the undo is
  attempted and the honest failure lands on that row.

## The launch reconcile

Rows left `inProgress` by a crash or a force-quit are checked against the disk at
launch. Only one disk combination is conclusive enough to justify offering undo,
and identity is proved by `(device, inode)` — **never by filename**. A file that
merely shares a name is a stranger and is refused. (This is why the same check is
so conspicuously missing from undo itself, above.)

## `history.db`

Separate from the folder index's `index.db` on purpose — see [[decisions]]. WAL,
`synchronous=FULL`, `secure_delete=ON`, single connection owned by one actor,
every value bound. Created `0600` inside a `0700` directory.

It stores paths, names, state, reasons, timestamps, and device/inode numbers.
**It stores no file content, no summary, and no embedding**, and there is no
column that could hold one.

Retention is 200 rows. "Clear history" deletes them, then compacts the file so
the names are actually gone rather than merely unlinked — a plain `DELETE` in WAL
mode leaves them readable on disk.

## When the history is unavailable

If `history.db` cannot be opened, the app **fails closed and says so**:
suggestions still appear, nothing moves, and pressing Accept leaves the popup
open with "The undo history couldn't be saved, so nothing was moved. Your file is
untouched." Settings › History explains it too, and its advice is specific —
"restarting usually fixes this" is true of a locked file and false of a history
written by a newer version of the app, so the two say different things.

The seam that does this is `RefusingAccepting`. It replaced `NoMoveAccepting`,
which returned `.unchanged` — a *success* — so every Accept closed the popup
exactly as a real move does while the file sat untouched in Downloads, with no
row and no message anywhere (F2). `NoMoveAccepting` still exists as a test double
and is pinned as one; a test asserts that the type the app injects refuses.

## Related

[[Popup-UI]] · [[Watcher]] · [[milestones]] · [[decisions]] · [[architecture]]
