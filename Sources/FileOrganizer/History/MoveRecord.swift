import Foundation

// MARK: - State

/// Where one accepted move stands. Raw values are persisted in `history.db`'s
/// `state` column, so they are part of the on-disk contract — never rename one
/// without a schema migration.
enum MoveState: String, Sendable, Equatable, CaseIterable {
    /// The intent row is written and the file is about to be (or is being)
    /// moved. Only ever seen after a crash/quit mid-move; resolved at launch
    /// by `MoveHistoryStore.reconcileInProgress`.
    case inProgress
    /// The file is at the recorded final path. The ONLY undoable state.
    case moved
    /// The move was undone: the file is back at its original path.
    case undone
    /// The move did not happen; the file is still where it was.
    case failed
    /// A stranded row the launch reconcile could not resolve from disk.
    /// Shown honestly in the menu, with **no** Undo offered — we do not
    /// guess where the user's file is.
    case unknown
}

/// Why a move that was aimed at a destination folder ended up renaming the
/// file in place in Downloads instead (founder decision 2: fall back, say so
/// honestly, never stop and ask). `nil` everywhere means "no fallback
/// happened" — including the ordinary "leave it in Downloads" case, which is
/// the user's intent, not a failure.
enum MoveFallbackReason: String, Sendable, Equatable, CaseIterable {
    /// The destination folder id is no longer registered at all (the folder
    /// was removed from Settings, or the index was rebuilt).
    case folderNotRegistered
    /// The id resolves, but to a folder whose display name no longer matches
    /// what the popup showed. A rebuilt index resets SQLite's AUTOINCREMENT,
    /// so id 3 can be a *different* folder — moving there would put the user's
    /// file somewhere they never chose (risk #4).
    case folderIdentityChanged
    /// The folder is registered but no longer on disk.
    case folderMissing
    /// Something is at the folder's path, but it is not a directory.
    case folderNotADirectory
    /// **No longer produced.** A folder we cannot write into used to fall back
    /// to renaming in place; founder decision 2026-07-28 (M24) made "blocked"
    /// an honest failure instead, because a file quietly left in Downloads
    /// after the user chose Invoices is indistinguishable from the app not
    /// working. The case stays so a row written by an earlier build still
    /// decodes — one unreadable row would make the whole history unreadable.
    case folderNotWritable

    /// The same clause with the folder named, for the history row: "Receipts
    /// isn't there any more" rather than "that folder isn't there any more".
    /// Falls back to the generic wording when the row has no folder name (a
    /// rename in place never had one).
    func explanation(namingFolder folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return explanation }
        switch self {
        case .folderNotRegistered: return "\(folder) is no longer in your list"
        case .folderIdentityChanged: return "\(folder) isn't the one you picked any more"
        case .folderMissing: return "\(folder) isn't there any more"
        case .folderNotADirectory: return "\(folder) isn't a folder any more"
        case .folderNotWritable: return "\(folder) can't be written to"
        }
    }

    /// One honest clause for the menu/history line, e.g.
    /// "Invoices wasn't available, so it was renamed where it is."
    var explanation: String {
        switch self {
        case .folderNotRegistered: "that folder is no longer in your list"
        case .folderIdentityChanged: "that folder isn't the one you picked any more"
        case .folderMissing: "that folder isn't there any more"
        case .folderNotADirectory: "that folder isn't a folder any more"
        case .folderNotWritable: "that folder can't be written to"
        }
    }
}

// MARK: - Records

/// The filesystem's own identity for one file: which volume it is on, and its
/// inode number within that volume.
///
/// Captured BEFORE a move so the launch reconcile can *prove* that the file
/// sitting at a stranded row's target path is the one we moved, rather than an
/// unrelated file that happens to have the same name (C2). A same-volume rename
/// keeps both numbers; a cross-volume copy does not, and neither does a
/// stranger — so anything we cannot prove is reported as `unknown` and offered
/// no undo, rather than guessed.
struct FileIdentity: Sendable, Equatable {
    /// `st_dev`: which volume the file lives on.
    let deviceID: Int64
    /// `st_ino`: the file's identity within that volume.
    let inode: Int64

    /// Reads the identity of whatever is at `path`, or nil when it cannot be
    /// read. `lstat`, not `stat`: the mover moves a symlink as the link, so the
    /// link — not its target — is the file whose identity matters.
    static func ofItem(atPath path: String) -> FileIdentity? {
        var info = stat()
        let succeeded = path.withCString { lstat($0, &info) == 0 }
        guard succeeded else { return nil }
        return FileIdentity(
            deviceID: Int64(info.st_dev), inode: Int64(bitPattern: UInt64(info.st_ino))
        )
    }
}

/// Phase 1 of the two-phase write: everything known BEFORE the file is
/// touched. Persisted as an `inProgress` row; if the app dies mid-move this
/// row is what the launch reconcile probes disk against.
struct MoveIntent: Sendable, Equatable {
    /// Identity of the originating `FileEvent` — also the dedup key that stops
    /// a popup Accept and a menu Accept from both moving the same file.
    let fileEventID: UUID
    /// Where the file is right now (normally ~/Downloads).
    let originalDirectory: URL
    /// Its current on-disk name.
    let originalName: String
    /// The directory we are about to try to move it into. Equal to
    /// `originalDirectory` for a rename in place.
    let intendedDirectory: URL
    /// The name we are about to try to give it. The name actually used may
    /// differ (collision dedup, byte-budget trim) — `finalize` records that.
    let intendedName: String
    /// The destination folder's display name, or nil when the file is staying
    /// where it is.
    let destinationFolderName: String?
    /// Non-nil only when a requested destination folder turned out to be
    /// unusable and we fell back to renaming in place.
    let fallbackReason: MoveFallbackReason?
    /// The source file's `(volume, inode)` as read a moment before the move.
    /// nil when it could not be read — which the reconcile treats as "cannot
    /// prove", never as "matches".
    let sourceIdentity: FileIdentity?
    let acceptedAt: Date
}

/// One row of the move history, as read back from `history.db`.
///
/// Directory URLs are compared by `path`, never by `URL ==` (a file URL for an
/// existing directory carries a trailing slash, one for a not-yet-existing
/// path does not — they are unequal as URLs but the same directory).
struct MoveRecord: Sendable, Equatable, Identifiable {
    /// `history.db` row id. Used to *address* a record; never used to find the
    /// file — undo is purely path-based so it survives a relaunch.
    let id: Int64
    let fileEventID: UUID
    let originalDirectory: URL
    let originalName: String
    /// Where the file ended up. While `inProgress` this holds the *intended*
    /// target (that is what makes the launch reconcile possible).
    let finalDirectory: URL
    let finalName: String
    /// Display name of the destination folder, nil for a rename in place.
    let destinationFolderName: String?
    let state: MoveState
    let fallbackReason: MoveFallbackReason?
    /// The honest one-line note this row needs, or nil when it needs none: why
    /// a `failed` row failed, why a reconciled row is `unknown` — or, on a
    /// `moved` row, a caveat such as a cross-volume copy whose original could
    /// not be removed afterwards.
    let failureDetail: String?
    /// The source file's `(volume, inode)` at intent time, when it could be
    /// read. The launch reconcile refuses to call a row `moved` unless the file
    /// at the target path still carries this identity.
    let sourceIdentity: FileIdentity?
    let acceptedAt: Date
    /// When the row left `inProgress` (moved / failed / undone); nil while
    /// still in progress.
    let settledAt: Date?

    /// Where the file was before the move — and where undo puts it back.
    var originalURL: URL { originalDirectory.appendingPathComponent(originalName) }
    /// Where the file is now, if `state == .moved`.
    var finalURL: URL { finalDirectory.appendingPathComponent(finalName) }

    /// False when the file ended up in exactly the folder it started in, under
    /// exactly the name it started with.
    ///
    /// The mover's collision ladder can land on the file's own name — a file
    /// already called `report 2.pdf`, asked for `report.pdf`, finds rung 1 taken
    /// by something else and rung 2 *is* itself. It reports that honestly as a
    /// no-op, but the intent row was written before the ladder ran, so the row
    /// settles as `moved` regardless (X8). Comparing the two ends of the row is
    /// what tells them apart, and it needs no extra column.
    var changedAnythingOnDisk: Bool {
        originalDirectory.path != finalDirectory.path || originalName != finalName
    }

    /// Undo is offered for exactly one state, and only when there is something
    /// to undo. `unknown` deliberately does not qualify: we will not guess where
    /// a stranded file went.
    var isUndoable: Bool { state == .moved && changedAnythingOnDisk }
}

// MARK: - Failures

/// Everything that can go wrong performing one move. Typed (engineering-rules:
/// typed throws on the M6 move path) so every caller and reviewer sees the
/// complete failure set.
enum MoveError: Error, Sendable, Equatable {
    /// The file is not at `sourceURL` any more — it moved, was renamed, or was
    /// deleted between the popup being shown and Accept being pressed.
    case sourceMissing(path: String)
    /// Something is there, but it is not a regular file (a directory, a socket).
    /// A symlink to a file is fine: the link itself is what gets moved.
    case sourceNotAFile(path: String)
    /// The requested name is not a usable single path component: empty or
    /// whitespace-only, "." or "..", or containing a path separator. Defense in
    /// depth behind `FilenameSanitizer` — a "/" reaching `renamex_np` would
    /// move the user's file to a completely different place.
    case invalidName(name: String)
    /// The file is not in the folder this app watches. Nothing outside that
    /// folder is ours to move, whatever a stale popup or an edited history row
    /// claims (M14).
    case sourceOutsideWatchedFolder(path: String)
    /// The destination directory is not there. We never create it — creating
    /// folders on the user's behalf is not this app's job.
    case destinationDirectoryMissing(path: String)
    /// The destination directory exists but its POSIX permissions refuse our
    /// write (or it is on a read-only volume).
    case destinationNotWritable(path: String, detail: String)
    /// macOS privacy (TCC) is blocking this app from writing into the folder —
    /// the ~/Documents and ~/Desktop case (risk #9).
    ///
    /// Its own case, not a message variant, for two reasons. `access(W_OK)`
    /// returns TRUE for a TCC-blocked directory, so this can only ever be
    /// discovered at write time, never by the resolver's pre-check; and the UI
    /// needs to recognise exactly this failure to offer an "Open System
    /// Settings" button (founder decision 2026-07-28). Blocked is a FAILURE,
    /// never a quiet fallback: the file is not moved and not renamed in place.
    case destinationBlockedByPrivacy(path: String)
    /// The destination is not the watched folder and not a folder the user
    /// registered. Undo reads its destination from a database column, and a
    /// database column is not a promise (M14).
    case destinationOutsideAllowedFolders(path: String)
    /// Every deduped candidate name was taken (bounded at
    /// `FileMover.maxCollisionAttempts`). Nothing was overwritten.
    case destinationNameUnavailable(directory: String, attempted: Int)
    /// Even after trimming to the 255-byte budget the name was rejected.
    case nameTooLong(name: String)
    /// The cross-volume (EXDEV) copy failed. The source is still intact — the
    /// fallback copies first and only deletes after a verified copy.
    ///
    /// `incompleteCopyRemained` is the part the user has to act on: a partial
    /// file sitting in the destination folder that this app could not clear up.
    /// A flag rather than a phrase spliced into `detail`, because `detail` is
    /// dev-only text and this has to reach the screen (C1/M13/D4).
    case crossVolumeCopyFailed(detail: String, incompleteCopyRemained: Bool)
    /// Any other errno from the rename/copy, carried verbatim.
    case moveFailed(code: Int32, detail: String)

    /// One honest sentence for the popup/menu. Never empty, never a bare errno.
    ///
    /// `folder` is the destination's display name, so the sentence can say
    /// "…into Invoices" rather than "…into that folder" (D5). It is optional
    /// because a rename in place has no folder to name.
    func message(namingFolder folder: String?) -> String {
        // The folder mid-sentence, and the same thing capitalised for the two
        // sentences that open with it.
        let named = folder ?? "that folder"
        let namedLeading = folder ?? "That folder"

        switch self {
        case .sourceMissing:
            return "That file isn't in Downloads any more, so there was nothing to move."
        case .sourceNotAFile:
            return "That isn't a file this app can move."
        case .invalidName:
            return "That name can't be used as a filename, so nothing was moved."
        case .sourceOutsideWatchedFolder:
            return "That file isn't in the folder this app watches, so it wasn't touched."
        case .destinationDirectoryMissing:
            return "\(namedLeading) isn't there any more, so nothing was moved."
        case .destinationNotWritable:
            return "This app isn't allowed to write into \(named), so nothing was moved."
        case .destinationBlockedByPrivacy:
            // The "how to fix it" half lives in `userDetail` and, in the popup,
            // in the "Open System Settings" button next to this line.
            return "macOS is blocking this app from writing into \(named), "
                + "so nothing was moved."
        case .destinationOutsideAllowedFolders:
            return "\(namedLeading) isn't a folder this app manages, so nothing was moved."
        case .destinationNameUnavailable:
            let place = folder.map { "in \($0)" } ?? "there"
            return "Too many files \(place) already have that name, so nothing was moved."
        case .nameTooLong:
            return "That name is too long for the disk, even after shortening it."
        case .crossVolumeCopyFailed:
            return "Copying to that disk failed, so the file was left where it is."
        case .moveFailed:
            return "The move failed, so the file was left where it is."
        }
    }

    /// The generic sentence, for callers with no folder to name.
    var message: String { message(namingFolder: nil) }

    /// A second plain-language sentence when there is something more the user
    /// needs to know or do — nil when the first sentence said it all.
    ///
    /// Deliberately NOT the typed payload. That payload carries errnos, POSIX
    /// strings and full paths; this reaches a History row the user reads weeks
    /// later, and "(errno 28: No space left on device)" is not something to put
    /// in front of them (D4). What survives is the part they can act on.
    var userDetail: String? {
        switch self {
        case .destinationBlockedByPrivacy:
            "You can allow it in System Settings › Privacy & Security › Files and Folders."
        case .destinationNameUnavailable(_, let attempted):
            "\(attempted) different names were tried, and every one was taken."
        case .crossVolumeCopyFailed(_, let incompleteCopyRemained)
            where incompleteCopyRemained:
            // The one that must never be lost: a stray partial file is sitting
            // in the destination folder and only the user can clear it (C1/M13).
            "An incomplete copy was left in that folder and couldn't be removed."
        default:
            nil
        }
    }

    /// True for the one failure the user can fix themselves without leaving
    /// their Mac: macOS privacy (TCC) refusing the destination folder. Founder
    /// decision 7 gives it its own button.
    var isBlockedByPrivacy: Bool {
        if case .destinationBlockedByPrivacy = self { return true }
        return false
    }

    /// What the history row stores. Plain language only — paths and filenames
    /// appear elsewhere in `history.db`, but never an error code or a POSIX
    /// name, because this column is read straight onto the screen.
    func historyDetail(namingFolder folder: String?) -> String {
        guard let userDetail else { return message(namingFolder: folder) }
        return message(namingFolder: folder) + " " + userDetail
    }
}

/// Everything that can go wrong undoing one recorded move.
enum UndoError: Error, Sendable, Equatable {
    /// No history row with that id (cleared history, pruned, or a stale menu).
    case unknownRecord(id: Int64)
    /// The row is not in an undoable state. Carries the state so the UI can be
    /// specific rather than saying "something went wrong".
    case notUndoable(state: MoveState)
    /// An undo of this same record is already running.
    case alreadyInFlight
    /// The file is not at the path we recorded. It may have been moved,
    /// renamed, or deleted by the user, or the whole folder may be gone — we
    /// cannot tell those apart, and we never search the disk or guess.
    case fileNotWhereWeLeftIt(expectedPath: String)
    /// The directory the file came from is gone. We never recreate directories.
    case originalDirectoryMissing(path: String)
    /// The row's original directory is not the watched folder and not a folder
    /// the user registered. Undo takes that directory straight from a database
    /// column, so it goes through the same bounds gate as an accept (M14).
    case destinationOutsideAllowedFolders(path: String)
    /// The restore move itself failed. The file is still at its moved path.
    case restoreFailed(MoveError)
    /// The file was restored but the history row could not be updated, so the
    /// entry still shows as moved. Surfaced rather than swallowed.
    case historyUnavailable(detail: String)

    /// One honest sentence for the menu. Never empty.
    var message: String {
        switch self {
        case .unknownRecord:
            "That entry is no longer in the history."
        case .notUndoable(let state) where state == .undone:
            "That one has already been undone."
        case .notUndoable:
            "That entry can't be undone."
        case .alreadyInFlight:
            "That undo is already running."
        case .fileNotWhereWeLeftIt:
            "Can't undo — that file isn't where the app left it."
        case .originalDirectoryMissing:
            "Can't undo — the folder it came from isn't there any more."
        case .destinationOutsideAllowedFolders:
            "Can't undo — that entry points at a folder this app doesn't manage."
        case .restoreFailed(let error):
            "Can't undo — " + error.message
        case .historyUnavailable:
            "The file was put back, but the history couldn't be updated."
        }
    }
}

/// Why an Accept did not move the file. The popup stays open on every one of
/// these (never close-as-success).
enum MoveFailure: Error, Sendable, Equatable {
    /// The history row could not be written. Founder decision 1: we FAIL
    /// CLOSED — the file was not touched at all.
    case historyUnavailable(detail: String)
    /// The move itself failed; the source is still where it was.
    case moveFailed(MoveError)
    /// Another Accept for this same file is already running (popup Accept and
    /// menu Accept racing). The loser never touches the file.
    case alreadyInFlight

    /// One honest sentence for the popup, naming the destination folder where
    /// there is one to name (D5).
    func message(namingFolder folder: String?) -> String {
        switch self {
        case .historyUnavailable:
            "The undo history couldn't be saved, so nothing was moved. "
            + "Your file is untouched."
        case .moveFailed(let error):
            error.message(namingFolder: folder)
        case .alreadyInFlight:
            "That file is already being moved."
        }
    }

    /// The generic sentence, for callers with no folder to name.
    var message: String { message(namingFolder: nil) }

    /// True when the popup should offer "Open System Settings" beside the
    /// message (founder decision 7) — macOS privacy blocking the destination is
    /// the one failure the user can put right from here.
    var isBlockedByPrivacy: Bool {
        if case .moveFailed(let error) = self { return error.isBlockedByPrivacy }
        return false
    }
}

// MARK: - Outcomes

/// What one completed move looks like to the UI.
struct MoveSummary: Sendable, Equatable {
    /// The history row this move wrote — the handle Undo is offered against.
    let recordID: Int64
    /// Where the file actually ended up.
    let finalURL: URL
    /// The destination folder's display name, or nil when the file stayed put.
    let destinationFolderName: String?
    /// Non-nil when the chosen folder was unusable and we renamed in place.
    let fallbackReason: MoveFallbackReason?
    /// True when the preferred name was taken and a " 2"-style name was used.
    let wasRenamedForCollision: Bool
    /// True when the accept produced no change on disk at all: the file already
    /// had the chosen name in the folder it was already in. Only ever true
    /// alongside a `fallbackReason` — the requested folder was unusable, so
    /// "success" here means "nothing happened", and the UI has to say so rather
    /// than let the user believe the file went where they asked (M4).
    let nothingChangedOnDisk: Bool
    /// True when a cross-volume copy was verified complete but the ORIGINAL
    /// could not be deleted, so a duplicate is still sitting in the source
    /// folder. The move succeeded — the destination holds the file, byte for
    /// byte — but the leftover is something the user must hear about (C1).
    let originalRemained: Bool

    /// The name the user actually asked for. Kept so the app can say *which*
    /// name was taken when it had to use a different one — "it was renamed"
    /// without naming either name is not much better than saying nothing.
    let requestedName: String

    init(
        recordID: Int64,
        finalURL: URL,
        destinationFolderName: String?,
        fallbackReason: MoveFallbackReason?,
        wasRenamedForCollision: Bool,
        requestedName: String,
        nothingChangedOnDisk: Bool = false,
        originalRemained: Bool = false
    ) {
        self.recordID = recordID
        self.finalURL = finalURL
        self.destinationFolderName = destinationFolderName
        self.fallbackReason = fallbackReason
        self.wasRenamedForCollision = wasRenamedForCollision
        self.requestedName = requestedName
        self.nothingChangedOnDisk = nothingChangedOnDisk
        self.originalRemained = originalRemained
    }

    var finalName: String { finalURL.lastPathComponent }

    /// What the user must be told about a move that SUCCEEDED but not exactly
    /// as they asked — or nil when it went exactly as asked.
    ///
    /// The popup used to close on any success, which meant asking for
    /// `Invoice.pdf`, silently getting `Invoice 2.pdf`, and only finding out by
    /// opening the folder (M5). A success the user is misled about is still a
    /// success worth reporting honestly.
    var notice: String? {
        Self.sentence(from: [fallbackClause] + clausesAHistoryRowCannotDerive)
    }

    /// What the history row stores.
    ///
    /// Everything `notice` says EXCEPT the fallback clause: the row has its own
    /// `fallback_reason` column and renders that sentence itself, so storing it
    /// here printed it twice (X9). The rest has no column of its own and would
    /// be lost.
    var historyNote: String? {
        Self.sentence(from: clausesAHistoryRowCannotDerive)
    }

    /// M4/founder decision 2: the folder they chose was unusable, so the file
    /// was renamed where it is. Saying nothing would leave them believing it
    /// reached that folder.
    private var fallbackClause: String? {
        fallbackReason.map {
            "The file stayed in Downloads because "
            + $0.explanation(namingFolder: destinationFolderName) + "."
        }
    }

    private var clausesAHistoryRowCannotDerive: [String?] {
        var parts: [String?] = []
        if wasRenamedForCollision {
            let place = destinationFolderName.map { "in \($0)" } ?? "there"
            parts.append(
                "\(requestedName) was already \(place), so this was saved as "
                + "\(finalName) instead. Nothing was overwritten."
            )
        }
        if originalRemained {
            parts.append(
                "The copy in the new folder is complete, but the original "
                + "couldn't be removed — it's still in Downloads."
            )
        }
        if nothingChangedOnDisk && fallbackReason != nil {
            parts.append("Its name was already what you chose, so nothing changed.")
        }
        return parts
    }

    private static func sentence(from parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }
}

/// The result of the Accept seam. Step 6 widens `SuggestionAccepting.accept`
/// to return this, which is what finally gives the popup a failure channel:
/// it closes on `.moved`/`.unchanged` and STAYS OPEN on `.failed`.
enum AcceptOutcome: Sendable, Equatable {
    /// The file was moved (or renamed in place) and a history row exists.
    case moved(MoveSummary)
    /// Nothing on disk changed. The popup must stay open and show `message`.
    case failed(MoveFailure)
    /// The user accepted the name the file already has, in the folder it is
    /// already in. Nothing was touched, nothing was written, nothing to undo —
    /// but this is success, so the popup closes.
    case unchanged
}

/// Why "Clear history" did not clear. Typed rather than a bare store error,
/// because two of the three have nothing to do with SQLite.
enum ClearHistoryFailure: Error, Sendable, Equatable {
    /// A move or an undo is running right now, and its history row is about to
    /// be written. Clearing would delete the row out from under it and leave a
    /// moved file with no record at all (M17) — so the button says "try again
    /// in a moment" instead.
    case busyWithAMove
    /// The history database refused the delete. Nothing was cleared.
    case historyUnavailable(detail: String)
    /// The delete ran but left rows behind because they were still in progress.
    /// The user asked for everything to go, so a partial sweep is reported.
    case someRowsKept(count: Int)
    /// The rows are gone, but the database file could not be rewritten
    /// afterwards. Not a failed clear — the history really is cleared — so the
    /// sentence leads with that and only then mentions the tidying (F5).
    case clearedButNotCompacted

    /// One honest sentence for Settings. Never empty.
    var message: String {
        switch self {
        case .busyWithAMove:
            "A move is finishing right now. Try clearing again in a moment."
        case .historyUnavailable:
            "The history couldn't be cleared — the app can't write to it right now. "
            + "Nothing was removed."
        case .someRowsKept:
            "Almost everything was cleared. A move that was still finishing was kept."
        case .clearedButNotCompacted:
            "Your history was cleared. The file it lives in couldn't be tidied up "
            + "afterwards — the app will tidy it the next time it can."
        }
    }
}

/// The result of one Undo.
enum UndoOutcome: Sendable, Equatable {
    /// The file is back. `restoredURL` may carry a deduped name ("report 2.pdf")
    /// when the original name had been taken again — never an overwrite.
    case restored(restoredURL: URL, wasRenamedForCollision: Bool)
    /// Nothing changed; the history row keeps its state and Undo stays offered.
    case failed(UndoError)
}
