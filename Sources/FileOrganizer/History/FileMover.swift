import Foundation

// MARK: - Ports

/// The `renamex_np(2)` + `RENAME_EXCL` primitive: atomic **and** no-clobber in
/// one syscall, so there is no test-then-move TOCTOU window where another
/// process could create the destination between the check and the move.
///
/// Behind a port for exactly one reason: a second volume cannot be assumed on
/// a test machine, so `EXDEV` (the cross-volume fallback trigger) is otherwise
/// an untestable branch on the path that moves the user's files.
protocol ExclusiveRenaming: Sendable {
    /// Returns 0 on success, or the `errno` of the failure. Never throws, never
    /// leaves the caller reading a stale global.
    func renameExclusive(from sourcePath: String, to destinationPath: String) -> Int32
}

/// Why a cross-volume copy step did not happen. Typed so "the destination is
/// already taken" (retry the next candidate name) is never confused with "the
/// copy failed" (give up, source untouched).
enum CopyFailure: Error, Sendable, Equatable {
    /// Something is already at the destination and the copier refused to
    /// overwrite it. The mover treats this exactly like the syscall's EEXIST.
    case destinationExists
    /// Anything else. The source is untouched.
    case failed(detail: String)
}

/// The cross-volume fallback: copy, verify, then delete the source. Never
/// `replaceItem`, never remove-then-move — a half-finished copy must leave the
/// user's file exactly where it was (risk #3).
protocol CrossVolumeCopying: Sendable {
    /// Copies `source` to `destination`. MUST refuse to overwrite an existing
    /// destination — in the kernel, not by a test-then-write pre-check — and
    /// MUST leave `source` untouched on any failure.
    func copyItem(at source: URL, to destination: URL) throws(CopyFailure)
    /// Size in bytes of the item at `url`, for the post-copy verification.
    /// Throws if it cannot be read — an unverifiable copy is never followed by
    /// a delete.
    func byteCount(at url: URL) throws(CopyFailure) -> Int
    /// Removes an item. Only ever called on a source whose copy has been
    /// verified, or on a partial copy this mover itself just created.
    func removeItem(at url: URL) throws(CopyFailure)
}

/// Production renamer: the real syscall, nothing else.
struct SystemExclusiveRename: ExclusiveRenaming {
    init() {}

    func renameExclusive(from sourcePath: String, to destinationPath: String) -> Int32 {
        // `errno` is captured INSIDE both `withCString` bodies, while the C
        // buffers are still alive. Reading it after they unwind would read it
        // after `free()`, which is not guaranteed to preserve `errno` — and a
        // failed rename that reported 0 would be recorded as a completed move
        // (C3).
        sourcePath.withCString { source in
            destinationPath.withCString { destination in
                renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
    }
}

/// Production cross-volume copier: `copyfile(3)` with `COPYFILE_EXCL`.
///
/// Not `FileManager.copyItem`, which pre-checks for an existing destination and
/// then calls `copyfile()` without the exclusive flag — a real test-then-write
/// window where another process can create the destination in between.
/// `COPYFILE_EXCL` puts the refusal in the kernel, matching what
/// `RENAME_EXCL` does on the primary path (M27).
struct SystemCrossVolumeCopy: CrossVolumeCopying {
    init() {}

    func copyItem(at source: URL, to destination: URL) throws(CopyFailure) {
        // COPYFILE_NOFOLLOW copies a symlink AS a symlink, matching the primary
        // path (the mover moves the link, never its target).
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        // Same errno discipline as the renamer: captured inside the buffers.
        let code = source.path.withCString { from in
            destination.path.withCString { to in
                copyfile(from, to, nil, flags) == 0 ? 0 : errno
            }
        }
        switch code {
        case 0:
            return
        case EEXIST:
            throw CopyFailure.destinationExists
        default:
            throw CopyFailure.failed(detail: describeErrno(code))
        }
    }

    func byteCount(at url: URL) throws(CopyFailure) -> Int {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes[.size] as? NSNumber)?.intValue else {
                throw CopyFailure.failed(detail: "no size attribute")
            }
            return size
        } catch let failure as CopyFailure {
            throw failure
        } catch {
            throw CopyFailure.failed(detail: error.localizedDescription)
        }
    }

    func removeItem(at url: URL) throws(CopyFailure) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CopyFailure.failed(detail: error.localizedDescription)
        }
    }
}

// MARK: - Outcome

/// What one successful move did. Value type: it crosses back to the main actor.
struct MoveOutcome: Sendable, Equatable {
    /// Where the file actually ended up.
    let finalURL: URL
    /// 1 when the preferred name was free; 2 when " 2" was needed, and so on.
    let attemptsUsed: Int
    /// True when the source already WAS the requested destination: nothing was
    /// touched, and there is nothing to undo (so no history row is written).
    let wasNoOp: Bool
    /// True only on the cross-volume path, when the copy was verified complete
    /// but the ORIGINAL could not be deleted afterwards. The file is at
    /// `finalURL` — that copy is verified and authoritative — but a duplicate
    /// is still sitting at the source (C1).
    let originalRemained: Bool

    init(finalURL: URL, attemptsUsed: Int, wasNoOp: Bool, originalRemained: Bool = false) {
        self.finalURL = finalURL
        self.attemptsUsed = attemptsUsed
        self.wasNoOp = wasNoOp
        self.originalRemained = originalRemained
    }

    var finalName: String { finalURL.lastPathComponent }
    /// Drives "restored as report 2.pdf" in the UI.
    var wasRenamedForCollision: Bool { attemptsUsed > 1 }
}

// MARK: - The mover

/// The one and only primitive that moves a user's file — used identically for
/// the forward move and for undo, so undo can never overwrite something the
/// forward move would have refused to.
///
/// Contract pinned by `FileMoverTests`:
/// - never overwrites anything: the no-clobber flag is in the syscall
///   (`RENAME_EXCL`), and the cross-volume fallback uses `COPYFILE_EXCL` — both
///   kernel-enforced, so neither has a test-then-write window
/// - on collision, walks Finder-style " 2", " 3"… candidates, bounded at
///   `maxCollisionAttempts`, then fails typed with nothing clobbered
/// - source == requested destination is a success no-op decided BEFORE the
///   syscall, for EVERY candidate the ladder reaches (`renamex_np` returns 0
///   for a self-rename on APFS, so relying on the syscall would silently record
///   an undoable "move" that never happened)
/// - a pure case change ("report.pdf" → "Report.pdf") and a normalization
///   change (NFD → NFC) are real renames of the same file and must NOT be
///   deduped into "Report 2.pdf" — which is why occupancy is decided by the
///   syscall, never by a `FileManager.fileExists` pre-check
/// - names are trimmed to a 255-**byte** UTF-8 budget with the extension kept
/// - never creates a destination directory, never deletes anything except a
///   source whose cross-volume copy has been verified
///
/// Not main-actor: it does blocking file I/O and is called off the main queue.
struct FileMover: Sendable {

    /// Longest single path component macOS allows, in UTF-8 **bytes**.
    /// `FilenameSanitizer` caps at 100 *grapheme clusters*, which is up to
    /// ~400 bytes of emoji — this is the byte-level backstop (risk #10).
    static let maxNameBytes = 255

    /// How many candidate names to try before giving up (candidate 1 is the
    /// preferred name itself). Bounded so a pathological folder cannot spin.
    static let maxCollisionAttempts = 50

    /// Called with each candidate destination URL BEFORE it is attempted, so
    /// `DownloadsWatcher` can pre-register names this app is about to create
    /// and not re-announce our own rename (or an undo restore) as a brand-new
    /// download (risk #8). The caller filters by directory; the mover just
    /// reports.
    ///
    /// It fires for candidates that end up unused too, which is why it carries
    /// the move's `claimGroup`: unused rungs are not harmless — one left lying
    /// around would swallow a real download that happens to share the name — so
    /// the caller retires the group's leftovers once the move settles (M7).
    typealias CandidateAnnouncing = @Sendable (URL, UUID) -> Void

    private let renamer: ExclusiveRenaming
    private let copier: CrossVolumeCopying
    private let announceCandidate: CandidateAnnouncing

    init(
        renamer: ExclusiveRenaming = SystemExclusiveRename(),
        copier: CrossVolumeCopying = SystemCrossVolumeCopy(),
        announceCandidate: @escaping CandidateAnnouncing = { _, _ in }
    ) {
        self.renamer = renamer
        self.copier = copier
        self.announceCandidate = announceCandidate
    }

    /// Moves `source` into `directory` under `preferredName`, or as close to
    /// that name as it can get without ever overwriting anything.
    /// `claimGroup` ties every candidate this call announces together, so the
    /// caller can retire the ones it did not use as soon as the move settles.
    /// It defaults to a fresh id, which is right for callers that do not claim
    /// at all (every test that passes no announcer).
    func move(
        from source: URL,
        intoDirectory directory: URL,
        preferredName: String,
        claimGroup: UUID = UUID()
    ) throws(MoveError) -> MoveOutcome {
        try Self.validate(name: preferredName)
        try Self.validateSource(source)

        let baseName = Self.trimmedToByteBudget(preferredName)
        guard !baseName.isEmpty else { throw .nameTooLong(name: preferredName) }

        // The destination directory is checked once, before the ladder — except
        // for a no-op, which needs no destination at all because it is the
        // source's own folder. Rung 1 therefore runs its identity check first
        // (below) and never reaches the syscall.
        if !Self.isNoOp(source: source, directory: directory, preferredName: baseName) {
            try Self.validateDestination(directory: directory)
        }

        for attemptNumber in 1...Self.maxCollisionAttempts {
            let candidate = Self.candidateName(for: baseName, attempt: attemptNumber)
            // Decided BEFORE any syscall, for every rung and not just the
            // preferred name (M25): `renamex_np(RENAME_EXCL)` returns 0 for a
            // self-rename on APFS rather than EEXIST, so letting the syscall
            // decide would report a successful move for a move that never
            // happened — and the coordinator would write an undoable history
            // row for it. A deduped rung reaches the source's own name whenever
            // the file is already called "report 2.pdf" and "report.pdf" is
            // taken by something else.
            if Self.isNoOp(source: source, directory: directory, preferredName: candidate) {
                return MoveOutcome(
                    finalURL: source, attemptsUsed: attemptNumber, wasNoOp: true
                )
            }

            let destination = directory.appendingPathComponent(candidate)
            // Announced before the attempt, so the watcher has the name
            // registered before the file can appear under it.
            announceCandidate(destination, claimGroup)
            switch try attemptMove(from: source, to: destination) {
            case .moved(let originalRemained):
                return MoveOutcome(
                    finalURL: destination,
                    attemptsUsed: attemptNumber,
                    wasNoOp: false,
                    originalRemained: originalRemained
                )
            case .nameTaken:
                continue
            }
        }

        throw .destinationNameUnavailable(
            directory: directory.path, attempted: Self.maxCollisionAttempts
        )
    }

    /// True when moving `source` into `directory` under `preferredName` would
    /// leave the file exactly where it already is, under exactly the name it
    /// already has. Static and shared, because `MoveCoordinator` has to ask the
    /// same question BEFORE it writes a history row: a no-op has nothing to undo.
    static func isNoOp(source: URL, directory: URL, preferredName: String) -> Bool {
        // Symlinks resolved on BOTH sides (M26): registry folder URLs are
        // already symlink-resolved and the watcher's are not, so on a symlinked
        // home `standardizedFileURL` alone would call the same folder two
        // different places and miss the no-op.
        guard Self.canonicalDirectoryPath(source.deletingLastPathComponent())
                == Self.canonicalDirectoryPath(directory) else {
            return false
        }
        // Compared scalar by scalar, NOT with Swift's `==`: `==` treats "café"
        // spelled NFD and NFC as equal, but rewriting the name from one to the
        // other is a real rename of the file on disk, and so is a pure case
        // change. Neither is a no-op.
        let name = trimmedToByteBudget(preferredName)
        return source.lastPathComponent.unicodeScalars.elementsEqual(name.unicodeScalars)
    }

    /// One spelling for one directory: symlinks resolved and `..` collapsed.
    /// Applied to the DIRECTORY only — never to the filename, whose exact bytes
    /// are what a rename is about.
    static func canonicalDirectoryPath(_ directory: URL) -> String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Finder-style dedup. `attempt` 1 is `preferredName` unchanged; attempt 2
    /// is "report 2.pdf", attempt 3 "report 3.pdf". Pure, extension-preserving,
    /// and byte-budget-aware (the suffix must not push the name over 255 bytes).
    static func candidateName(for preferredName: String, attempt: Int) -> String {
        let base = trimmedToByteBudget(preferredName)
        guard attempt > 1 else { return base }

        let fileExtension = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        let tail = fileExtension.isEmpty ? " \(attempt)" : " \(attempt).\(fileExtension)"
        // The suffix is what makes the name unique, so the stem is what gives
        // way when the two together would not fit.
        let trimmedStem = trimmed(stem, toBytes: maxNameBytes - tail.utf8.count)
        guard !trimmedStem.isEmpty else { return trimmed(base + " \(attempt)", toBytes: maxNameBytes) }
        return trimmedStem + tail
    }

    /// Trims `name` to at most `maxNameBytes` UTF-8 bytes, keeping the
    /// extension and never splitting a grapheme cluster. Returns `name`
    /// unchanged when it already fits.
    static func trimmedToByteBudget(_ name: String) -> String {
        guard name.utf8.count > maxNameBytes else { return name }

        let fileExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let tail = fileExtension.isEmpty ? "" : "." + fileExtension
        let trimmedStem = trimmed(stem, toBytes: maxNameBytes - tail.utf8.count)
        // A stem that trims away to nothing would leave a name that is all
        // extension (".pdf" — a hidden file). Trim the whole name instead and
        // let the filesystem have the last word.
        guard !trimmedStem.isEmpty else { return trimmed(name, toBytes: maxNameBytes) }
        return trimmedStem + tail
    }

    /// The longest prefix of `text` that fits in `budget` UTF-8 bytes, cut on
    /// grapheme-cluster boundaries — half an emoji is mojibake, not a filename.
    private static func trimmed(_ text: String, toBytes budget: Int) -> String {
        guard budget > 0 else { return "" }
        guard text.utf8.count > budget else { return text }

        var result = ""
        var usedBytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard usedBytes + size <= budget else { break }
            result.append(character)
            usedBytes += size
        }
        return result
    }

    // MARK: - Validation

    /// The name has to be one safe path component. Defense in depth behind
    /// `FilenameSanitizer`: a "/" reaching `renamex_np` would move the user's
    /// file somewhere else entirely.
    private static func validate(name: String) throws(MoveError) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..",
              !name.contains("/"),
              !name.unicodeScalars.contains("\u{0}") else {
            throw .invalidName(name: name)
        }
    }

    /// `lstat`, not `stat`: a symlink is moved as the link, so its own kind is
    /// what matters and its target is never touched.
    private static func validateSource(_ source: URL) throws(MoveError) {
        let probe = fileInfo(atPath: source.path, followingSymlinks: false)
        guard probe.code == 0 else {
            guard probe.code == ENOENT || probe.code == ENOTDIR else {
                throw .moveFailed(code: probe.code, detail: describe(probe.code))
            }
            throw .sourceMissing(path: source.path)
        }
        let kind = probe.info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFLNK else {
            throw .sourceNotAFile(path: source.path)
        }
    }

    /// The destination directory must already exist — this app never creates a
    /// folder the user did not create.
    private static func validateDestination(directory: URL) throws(MoveError) {
        let probe = fileInfo(atPath: directory.path, followingSymlinks: true)
        guard probe.code == 0 else {
            switch probe.code {
            case ENOENT, ENOTDIR:
                throw .destinationDirectoryMissing(path: directory.path)
            case EPERM:
                throw .destinationBlockedByPrivacy(path: directory.path)
            default:
                throw .destinationNotWritable(
                    path: directory.path, detail: describe(probe.code)
                )
            }
        }
        guard probe.info.st_mode & S_IFMT == S_IFDIR else {
            throw .destinationDirectoryMissing(path: directory.path)
        }
    }

    /// `stat`/`lstat` with the errno captured INSIDE the C string's lifetime.
    /// Reading `errno` after the temporary buffer is released reads it after a
    /// `free()`, which is not guaranteed to preserve it — a failure that read
    /// back as 0 would be reported as success (C3).
    ///
    /// - Returns: the populated `stat` and 0, or an untouched `stat` and the
    ///   errno of the failure.
    private static func fileInfo(
        atPath path: String, followingSymlinks follow: Bool
    ) -> (info: stat, code: Int32) {
        var info = stat()
        let code = path.withCString { cPath -> Int32 in
            let result = follow ? stat(cPath, &info) : lstat(cPath, &info)
            return result == 0 ? 0 : errno
        }
        return (info, code)
    }

    // MARK: - One attempt

    /// What one candidate name produced.
    private enum Attempt {
        /// The file is now at the candidate name. `originalRemained` is true
        /// only for a verified cross-volume copy whose source could not be
        /// deleted afterwards.
        case moved(originalRemained: Bool)
        /// That name is taken. Nothing was touched, nothing was inspected; the
        /// ladder walks on to the next candidate.
        case nameTaken
    }

    /// One candidate name, one syscall.
    private func attemptMove(from source: URL, to destination: URL) throws(MoveError) -> Attempt {
        let code = renamer.renameExclusive(from: source.path, to: destination.path)
        switch code {
        case 0:
            return .moved(originalRemained: false)
        case EEXIST, ENOTEMPTY:
            // Something is already there — a file OR a directory. Never
            // touched, never inspected: the no-clobber flag is in the syscall.
            return .nameTaken
        case EXDEV:
            return try copyAcrossVolumes(from: source, to: destination)
        case EPERM:
            // The shape of a macOS TCC denial writing into ~/Documents or
            // ~/Desktop (risk #9). `access(W_OK)` says yes for such a folder, so
            // the resolver's pre-check cannot see it: this is where it surfaces,
            // and founder decision 2026-07-28 makes it an honest failure rather
            // than a quiet rename in place (M24).
            throw .destinationBlockedByPrivacy(
                path: destination.deletingLastPathComponent().path
            )
        case EACCES, EROFS:
            // Ordinary POSIX refusal: the folder's own permissions, or a
            // read-only volume.
            throw .destinationNotWritable(
                path: destination.deletingLastPathComponent().path, detail: Self.describe(code)
            )
        case ENAMETOOLONG:
            throw .nameTooLong(name: destination.lastPathComponent)
        default:
            throw .moveFailed(code: code, detail: Self.describe(code))
        }
    }

    /// The cross-volume fallback, which `rename` cannot do: copy, verify, then
    /// delete. The source is deleted ONLY after the copy is verified, so an
    /// interrupted move can never leave the user's file in neither place.
    private func copyAcrossVolumes(
        from source: URL, to destination: URL
    ) throws(MoveError) -> Attempt {
        do throws(CopyFailure) {
            try copier.copyItem(at: source, to: destination)
        } catch {
            switch error {
            case .destinationExists:
                return .nameTaken
            case .failed(let detail):
                // `copyfile` can fail partway and leave a partial file sitting
                // at the destination. Nothing has been verified yet, so this is
                // still inside the one window where a copy may be discarded —
                // and a partial left behind looks, in the folder, exactly like a
                // move that worked.
                throw .crossVolumeCopyFailed(
                    detail: detail, incompleteCopyRemained: discardingCopy(at: destination)
                )
            }
        }

        // Step 1 — a copy now exists but is NOT yet known to be complete. This
        // is the ONLY window in which the copy may be discarded, and the only
        // thing that happens in it is verification.
        do throws(CopyFailure) {
            let copiedBytes = try copier.byteCount(at: destination)
            let originalBytes = try copier.byteCount(at: source)
            guard copiedBytes == originalBytes else {
                throw CopyFailure.failed(
                    detail: "the copy is \(copiedBytes) bytes, the original \(originalBytes)"
                )
            }
        } catch {
            throw .crossVolumeCopyFailed(
                detail: Self.describe(error),
                incompleteCopyRemained: discardingCopy(at: destination)
            )
        }

        // Step 2 — the copy is verified byte-for-byte, so the DESTINATION is now
        // the authoritative copy of the user's file and is never discarded from
        // here on (C1). Deleting the source is a separate step with its own
        // outcome: a source we cannot remove leaves a duplicate, which is
        // untidy but keeps the file; discarding a verified copy because the
        // source vanished under us would lose it from both places.
        do throws(CopyFailure) {
            try copier.removeItem(at: source)
            return .moved(originalRemained: false)
        } catch {
            return .moved(originalRemained: true)
        }
    }

    /// Removes a copy this mover made and could **not verify**, so a failed
    /// cross-volume move never leaves a half file sitting there looking like a
    /// success. Never called on a verified copy (C1).
    ///
    /// - Returns: true when a file is still at `destination` afterwards — the
    ///   leftover the user has to be told about. A removal that fails because
    ///   nothing was ever created is not a leftover, so the answer is checked
    ///   rather than assumed from the error.
    private func discardingCopy(at destination: URL) -> Bool {
        do throws(CopyFailure) {
            try copier.removeItem(at: destination)
            return false
        } catch {
            return (try? copier.byteCount(at: destination)) != nil
        }
    }

    private static func describe(_ failure: CopyFailure) -> String {
        switch failure {
        case .destinationExists: "the destination name was taken"
        case .failed(let detail): detail
        }
    }

    private static func describe(_ code: Int32) -> String {
        describeErrno(code)
    }
}

/// The system's sentence for an errno, read into a buffer owned by this call.
///
/// `strerror_r`, not `strerror`: moves run on concurrent detached tasks, and
/// `strerror` hands every caller the same static buffer — two failures landing
/// together could each read the other's text (X1). Dev-facing only: nothing
/// here reaches the user, whose sentences come from `MoveError` (D4).
private func describeErrno(_ code: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard strerror_r(code, &buffer, buffer.count) == 0 else { return "error \(code)" }
    return String(cString: buffer)
}
