import Foundation
import Testing
@testable import FileOrganizer

// MARK: - Test doubles

/// A renamer that reports a fixed errno instead of touching the disk — the only
/// honest way to reach the `EXDEV` (cross-volume) branch on a machine with one
/// volume. Records what it was asked to do so the ladder is observable.
private final class StubRenamer: ExclusiveRenaming, @unchecked Sendable {
    /// The errno every call returns (0 = success).
    private let result: Int32
    private let lock = NSLock()
    private var calls: [(from: String, to: String)] = []

    init(alwaysReturning result: Int32) {
        self.result = result
    }

    var attemptedDestinations: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.to)
    }

    func renameExclusive(from sourcePath: String, to destinationPath: String) -> Int32 {
        lock.lock()
        calls.append((sourcePath, destinationPath))
        lock.unlock()
        return result
    }
}

/// A copier that fails a chosen way, or writes a deliberately truncated file,
/// so "the copy failed" and "the copy could not be verified" are both reachable
/// without a second volume. Everything else delegates to the real copier.
private final class FaultyCopier: CrossVolumeCopying, @unchecked Sendable {
    enum Mode: Sendable {
        /// Copy exactly as production does.
        case healthy
        /// Fail every copy — the source must survive untouched.
        case failEveryCopy
        /// Write a shorter file than the source: a copy that cannot be verified.
        /// The source must NOT be deleted.
        case truncateCopy
        /// Copy healthily, then refuse every removal. Two real cases produce
        /// this: the source is unlinked by something else in the microseconds
        /// after the copy is verified, and a source the user locked in Finder
        /// (`uchg`), whose immutable flag `copyfile` faithfully copies. Either
        /// way the verified copy at the destination must SURVIVE (C1).
        case failRemove
    }

    private let mode: Mode
    private let real = SystemCrossVolumeCopy()
    private let lock = NSLock()
    private var removed: [String] = []

    init(_ mode: Mode) { self.mode = mode }

    var removedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return removed
    }

    func copyItem(at source: URL, to destination: URL) throws(CopyFailure) {
        switch mode {
        case .healthy, .failRemove:
            try real.copyItem(at: source, to: destination)
        case .failEveryCopy:
            // Refuse an occupied destination the same way the real copier does,
            // so the collision ladder still behaves in this mode.
            if FileManager.default.fileExists(atPath: destination.path) {
                throw CopyFailure.destinationExists
            }
            throw CopyFailure.failed(detail: "simulated mid-copy failure")
        case .truncateCopy:
            if FileManager.default.fileExists(atPath: destination.path) {
                throw CopyFailure.destinationExists
            }
            guard FileManager.default.createFile(
                atPath: destination.path, contents: Data("tr".utf8)
            ) else {
                throw CopyFailure.failed(detail: "could not create truncated copy")
            }
        }
    }

    func byteCount(at url: URL) throws(CopyFailure) -> Int {
        try real.byteCount(at: url)
    }

    func removeItem(at url: URL) throws(CopyFailure) {
        lock.lock()
        removed.append(url.path)
        lock.unlock()
        guard mode != .failRemove else {
            throw CopyFailure.failed(detail: "simulated removal refusal")
        }
        try real.removeItem(at: url)
    }
}

/// Collects the candidate URLs the mover announces before each attempt. The
/// mover calls the hook synchronously on the calling thread; the lock makes
/// that safe to assert on without pretending about concurrency.
private final class AnnouncementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(url: URL, group: UUID)] = []

    func record(_ url: URL, group: UUID = UUID()) {
        lock.lock(); entries.append((url, group)); lock.unlock()
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.url.lastPathComponent)
    }

    /// The distinct claim groups seen. One move must announce all of its
    /// candidates under a single group, or `releaseUnused` could not retire the
    /// rungs it did not use (M7).
    var groups: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.map(\.group))
    }
}

// MARK: - Suite

/// The move primitive: the single piece of code that touches a user's file.
/// Everything here runs on a real per-test temp directory, because the whole
/// point is what the filesystem actually does. Two doubles exist only for the
/// branches a one-volume machine cannot reach honestly (`EXDEV`) or must not
/// reach destructively (a failed copy).
///
/// The load-bearing assertion in every collision test is that the file already
/// at the destination still has its ORIGINAL bytes afterwards — not merely that
/// an error was thrown.
@Suite("FileMover")
final class FileMoverTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileMoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        // Best-effort cleanup of test scratch only; nothing here guards data.
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    @discardableResult
    private func makeFile(_ name: String, _ contents: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeDirectory(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// True when the volume backing `directory` folds case (the macOS default
    /// on APFS). Probed, not assumed: the clobber assertion differs.
    private func volumeFoldsCase(in directory: URL) -> Bool {
        let probe = directory.appendingPathComponent("case-probe-\(UUID().uuidString)")
        guard (try? Data("x".utf8).write(to: probe)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: probe) }
        let upper = directory.appendingPathComponent(probe.lastPathComponent.uppercased())
        return FileManager.default.fileExists(atPath: upper.path)
    }

    /// Runs a move that is expected to fail and returns the typed error, so
    /// assertions can match the CASE without depending on path spelling
    /// (/var vs /private/var would otherwise make them flaky).
    private func failure(
        _ sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> MoveOutcome
    ) -> MoveError? {
        do {
            let outcome = try body()
            Issue.record(
                "expected a typed MoveError; the move succeeded as \(outcome.finalName)",
                sourceLocation: sourceLocation
            )
            return nil
        } catch let error as MoveError {
            return error
        } catch {
            Issue.record(
                "expected a typed MoveError, got \(error)", sourceLocation: sourceLocation
            )
            return nil
        }
    }

    /// Case name only — keeps assertion output readable ("expected
    /// sourceMissing, got moveFailed") without asserting on payload paths.
    private func name(of error: MoveError?) -> String {
        switch error {
        case .none: "‹no error thrown›"
        case .sourceMissing: "sourceMissing"
        case .sourceNotAFile: "sourceNotAFile"
        case .invalidName: "invalidName"
        case .sourceOutsideWatchedFolder: "sourceOutsideWatchedFolder"
        case .destinationDirectoryMissing: "destinationDirectoryMissing"
        case .destinationNotWritable: "destinationNotWritable"
        case .destinationBlockedByPrivacy: "destinationBlockedByPrivacy"
        case .destinationOutsideAllowedFolders: "destinationOutsideAllowedFolders"
        case .destinationNameUnavailable: "destinationNameUnavailable"
        case .nameTooLong: "nameTooLong"
        case .crossVolumeCopyFailed: "crossVolumeCopyFailed"
        case .moveFailed: "moveFailed"
        }
    }

    // MARK: - 1. The happy path

    @Test("A free destination gets the file, byte-identical, and the source is gone")
    func movesToFreeDestination() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("Scan 2026-07-20 14.33.pdf", "PAYLOAD")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "Chase Statement.pdf"
        )

        #expect(outcome.finalName == "Chase Statement.pdf")
        #expect(outcome.attemptsUsed == 1)
        #expect(outcome.wasNoOp == false)
        #expect(outcome.wasRenamedForCollision == false)
        #expect(!exists(source), "the source must be gone after a move")
        #expect(exists(outcome.finalURL))
        #expect(text(at: outcome.finalURL) == "PAYLOAD", "bytes must survive the move")
    }

    // MARK: - 2. Never overwrite

    @Test("An occupied destination name is NEVER overwritten — the file already there is untouched")
    func occupiedDestinationIsNeverOverwritten() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let precious = try makeFile("report.pdf", "PRECIOUS", in: destination)
        let source = try makeFile("download.pdf", "NEW")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "report.pdf"
        )

        #expect(text(at: precious) == "PRECIOUS",
                "the pre-existing file's BYTES must be unchanged — this is the whole milestone")
        #expect(outcome.finalName == "report 2.pdf", "Finder-style dedup")
        #expect(outcome.attemptsUsed == 2)
        #expect(outcome.wasRenamedForCollision)
        #expect(text(at: outcome.finalURL) == "NEW")
        #expect(!exists(source))
    }

    @Test("Two collisions in a row walk to ' 3'; both existing files keep their bytes")
    func collisionLadderWalksOn() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let first = try makeFile("report.pdf", "FIRST", in: destination)
        let second = try makeFile("report 2.pdf", "SECOND", in: destination)
        let source = try makeFile("download.pdf", "NEW")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "report.pdf"
        )

        #expect(outcome.finalName == "report 3.pdf")
        #expect(text(at: first) == "FIRST")
        #expect(text(at: second) == "SECOND")
        #expect(text(at: outcome.finalURL) == "NEW")
    }

    @Test("A DIRECTORY in the way is stepped around, not into and not over")
    func directoryInTheWayIsSteppedAround() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let blocker = try makeDirectory("report.pdf", in: destination)
        let inside = try makeFile("keep-me.txt", "INSIDE", in: blocker)
        let source = try makeFile("download.pdf", "NEW")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "report.pdf"
        )

        #expect(outcome.finalName == "report 2.pdf")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: blocker.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the directory must still be a directory")
        #expect(text(at: inside) == "INSIDE", "and its contents untouched")
        #expect(text(at: outcome.finalURL) == "NEW")
    }

    @Test("The collision ladder is bounded: 50 taken names fail typed, clobbering nothing")
    func collisionLadderIsBounded() throws {
        #expect(FileMover.maxCollisionAttempts == 50)
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")

        var occupied: [URL: String] = [:]
        for attempt in 1...FileMover.maxCollisionAttempts {
            let name = attempt == 1 ? "report.pdf" : "report \(attempt).pdf"
            let contents = "existing-\(attempt)"
            occupied[try makeFile(name, contents, in: destination)] = contents
        }
        let source = try makeFile("download.pdf", "NEW")

        let error = failure {
            try mover.move(from: source, intoDirectory: destination, preferredName: "report.pdf")
        }

        #expect(name(of: error) == "destinationNameUnavailable")
        if case .destinationNameUnavailable(_, let attempted) = error {
            #expect(attempted == FileMover.maxCollisionAttempts)
        }
        #expect(text(at: source) == "NEW", "the source must be untouched after a bounded failure")
        for (url, contents) in occupied {
            #expect(text(at: url) == contents, "nothing in the folder may be clobbered")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(names.count == FileMover.maxCollisionAttempts,
                "no stray partial file may be left behind")
    }

    // MARK: - 3. The self-rename no-op

    @Test("Source == requested destination is a success NO-OP, decided before any syscall")
    func selfRenameIsANoOp() throws {
        // renamex_np(RENAME_EXCL) returns 0 for a self-rename on APFS (probed
        // 2026-07-27) rather than EEXIST, so relying on the syscall would record
        // an undoable "move" that never happened. The short-circuit must be ours.
        let log = AnnouncementLog()
        let renamer = StubRenamer(alwaysReturning: 0)
        let mover = FileMover(renamer: renamer, announceCandidate: { url, group in log.record(url, group: group) })
        let source = try makeFile("report.pdf", "SAME")

        let outcome = try mover.move(
            from: source, intoDirectory: tempDir, preferredName: "report.pdf"
        )

        #expect(outcome.wasNoOp, "same folder + same name = nothing to do")
        #expect(outcome.finalURL.path == source.path)
        #expect(outcome.attemptsUsed == 1)
        #expect(outcome.wasRenamedForCollision == false)
        #expect(text(at: source) == "SAME")
        #expect(renamer.attemptedDestinations.isEmpty,
                "the no-op must be decided BEFORE the syscall")
        #expect(log.names.isEmpty, "and nothing announced to the watcher")
    }

    @Test("A pure case change is a real rename of the same file, not a ' 2' collision")
    func caseOnlyRenameIsNotACollision() throws {
        let mover = FileMover()
        let source = try makeFile("report.pdf", "SAME")

        let outcome = try mover.move(
            from: source, intoDirectory: tempDir, preferredName: "Report.pdf"
        )

        #expect(outcome.finalName == "Report.pdf",
                "a fileExists() pre-check would wrongly dedup this to 'Report 2.pdf'")
        #expect(outcome.wasNoOp == false, "the name really did change")
        #expect(text(at: outcome.finalURL) == "SAME")
        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        #expect(names.count == 1, "exactly one file, under its new spelling")
    }

    @Test("A normalization-only rename (NFD → NFC) is the same file, not a collision")
    func normalizationOnlyRenameIsNotACollision() throws {
        let mover = FileMover()
        let decomposed = "cafe\u{301}.txt"   // NFD: e + combining acute
        let composed = "caf\u{e9}.txt"       // NFC: é
        let source = try makeFile(decomposed, "SAME")

        let outcome = try mover.move(
            from: source, intoDirectory: tempDir, preferredName: composed
        )

        #expect(outcome.attemptsUsed == 1, "must not become 'café 2.txt'")
        #expect(text(at: outcome.finalURL) == "SAME")
        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        #expect(names.count == 1)
    }

    @Test("On a case-folding volume, a differently-cased existing file is not clobbered")
    func caseInsensitiveVolumeIsNotClobbered() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let precious = try makeFile("invoice.pdf", "PRECIOUS", in: destination)
        let source = try makeFile("download.pdf", "NEW")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "Invoice.pdf"
        )

        // True on either kind of volume: the existing file keeps its bytes and
        // the moved file is somewhere else.
        #expect(text(at: precious) == "PRECIOUS")
        #expect(text(at: outcome.finalURL) == "NEW")
        #expect(outcome.finalURL.path != precious.path)
        if volumeFoldsCase(in: destination) {
            #expect(outcome.finalName == "Invoice 2.pdf",
                    "on a case-folding volume 'Invoice.pdf' collides with 'invoice.pdf'")
        } else {
            #expect(outcome.finalName == "Invoice.pdf")
        }
    }

    // MARK: - 4. Bad sources

    @Test("A source that vanished before the move fails typed, and nothing is created")
    func missingSourceFailsTyped() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let ghost = tempDir.appendingPathComponent("never-existed.pdf")

        let error = failure {
            try mover.move(from: ghost, intoDirectory: destination, preferredName: "report.pdf")
        }

        #expect(name(of: error) == "sourceMissing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("A directory source is refused typed and left completely alone")
    func directorySourceIsRefused() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let folder = try makeDirectory("a-folder")
        let inside = try makeFile("keep-me.txt", "INSIDE", in: folder)

        let error = failure {
            try mover.move(from: folder, intoDirectory: destination, preferredName: "moved.pdf")
        }

        #expect(name(of: error) == "sourceNotAFile")
        #expect(exists(folder))
        #expect(text(at: inside) == "INSIDE")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("A symlink source moves the LINK; its target is never touched")
    func symlinkSourceMovesTheLinkOnly() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let target = try makeFile("real-file.txt", "TARGET")
        let link = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let outcome = try mover.move(
            from: link, intoDirectory: destination, preferredName: "moved-link.txt"
        )

        #expect(exists(target), "the symlink's target must stay exactly where it was")
        #expect(text(at: target) == "TARGET")
        #expect(!FileManager.default.fileExists(atPath: link.path),
                "the link itself moved")
        let movedTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: outcome.finalURL.path
        )
        #expect(movedTarget == target.path, "it is still a symlink, still pointing at the target")
    }

    @Test("A name that is not a single safe path component is refused before any syscall",
          arguments: ["", "   ", ".", "..", "sub/report.pdf", "../escape.pdf", "/etc/passwd"])
    func unsafeNamesAreRefused(unsafeName: String) throws {
        let renamer = StubRenamer(alwaysReturning: 0)
        let mover = FileMover(renamer: renamer)
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("download.pdf", "NEW")

        let error = failure {
            try mover.move(from: source, intoDirectory: destination, preferredName: unsafeName)
        }

        #expect(name(of: error) == "invalidName")
        #expect(renamer.attemptedDestinations.isEmpty,
                "a separator reaching renamex_np would move the file somewhere else entirely")
        #expect(text(at: source) == "NEW")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    // MARK: - 5. Bad destinations

    @Test("A missing destination directory fails typed — we NEVER create it")
    func missingDestinationDirectoryIsNeverCreated() throws {
        let mover = FileMover()
        let missing = tempDir.appendingPathComponent("Not There")
        let source = try makeFile("download.pdf", "NEW")

        let error = failure {
            try mover.move(from: source, intoDirectory: missing, preferredName: "report.pdf")
        }

        #expect(name(of: error) == "destinationDirectoryMissing")
        #expect(!exists(missing), "creating folders on the user's behalf is not this app's job")
        #expect(text(at: source) == "NEW")
    }

    @Test("An unwritable destination fails typed with the source untouched",
          .enabled(if: getuid() != 0, "root can write anywhere, which would void the test"))
    func unwritableDestinationFailsTyped() throws {
        let mover = FileMover()
        let destination = try makeDirectory("Locked")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: destination.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: destination.path
            )
        }
        let source = try makeFile("download.pdf", "NEW")

        let error = failure {
            try mover.move(from: source, intoDirectory: destination, preferredName: "report.pdf")
        }

        // This is also the shape of a macOS TCC denial on ~/Documents/~/Desktop
        // (risk #9): a specific, actionable failure — never a silent no-op.
        #expect(name(of: error) == "destinationNotWritable")
        #expect(error?.message.isEmpty == false)
        #expect(text(at: source) == "NEW")
    }

    // MARK: - 6. Cross-volume (EXDEV) fallback

    @Test("EXDEV falls back to copy-then-delete: the file lands, the source goes")
    func crossVolumeFallbackCompletes() throws {
        // A second volume cannot be assumed on a test machine, so EXDEV is
        // injected through the renamer port. The copy/verify/delete half runs
        // for real on disk.
        let mover = FileMover(
            renamer: StubRenamer(alwaysReturning: EXDEV), copier: FaultyCopier(.healthy)
        )
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("download.pdf", "PAYLOAD")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "report.pdf"
        )

        #expect(outcome.finalName == "report.pdf")
        #expect(text(at: outcome.finalURL) == "PAYLOAD")
        #expect(!exists(source), "the source is deleted only after a verified copy")
    }

    @Test("The EXDEV path dedups too — it never overwrites an occupied name")
    func crossVolumeFallbackDedups() throws {
        let mover = FileMover(
            renamer: StubRenamer(alwaysReturning: EXDEV), copier: FaultyCopier(.healthy)
        )
        let destination = try makeDirectory("Invoices")
        let precious = try makeFile("report.pdf", "PRECIOUS", in: destination)
        let source = try makeFile("download.pdf", "NEW")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "report.pdf"
        )

        #expect(text(at: precious) == "PRECIOUS")
        #expect(outcome.finalName == "report 2.pdf")
        #expect(text(at: outcome.finalURL) == "NEW")
    }

    @Test("A failed cross-volume copy leaves the source intact and no partial file behind")
    func crossVolumeCopyFailureLeavesSourceIntact() throws {
        let copier = FaultyCopier(.failEveryCopy)
        let mover = FileMover(renamer: StubRenamer(alwaysReturning: EXDEV), copier: copier)
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("download.pdf", "PAYLOAD")

        let error = failure {
            try mover.move(from: source, intoDirectory: destination, preferredName: "report.pdf")
        }

        #expect(name(of: error) == "crossVolumeCopyFailed")
        #expect(text(at: source) == "PAYLOAD",
                "an interrupted copy must never leave the file in neither place")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(copier.removedPaths.contains(source.path) == false,
                "the source is deleted ONLY after a verified copy")
    }

    @Test("A copy that cannot be verified is not followed by a delete")
    func unverifiedCopyIsNotFollowedByADelete() throws {
        let copier = FaultyCopier(.truncateCopy)
        let mover = FileMover(renamer: StubRenamer(alwaysReturning: EXDEV), copier: copier)
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("download.pdf", "A MUCH LONGER PAYLOAD")

        let error = failure {
            try mover.move(from: source, intoDirectory: destination, preferredName: "report.pdf")
        }

        #expect(name(of: error) == "crossVolumeCopyFailed")
        #expect(text(at: source) == "A MUCH LONGER PAYLOAD")
        #expect(copier.removedPaths.contains(source.path) == false)
        #expect(!exists(destination.appendingPathComponent("report.pdf")),
                "the unusable partial copy must be cleaned up, not left as a fake success")
    }

    @Test("A VERIFIED cross-volume copy is never discarded, even if the source can't be deleted")
    func verifiedCopySurvivesAFailedSourceDelete() throws {
        // The exact loss this guards: EXDEV → copy succeeds → bytes verified →
        // the source is unlinked by something else (or was locked in Finder all
        // along) → the delete fails. Discarding the verified copy at that point
        // would leave the file in NEITHER place.
        let copier = FaultyCopier(.failRemove)
        let mover = FileMover(renamer: StubRenamer(alwaysReturning: EXDEV), copier: copier)
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("download.pdf", "PAYLOAD")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "report.pdf"
        )

        #expect(text(at: outcome.finalURL) == "PAYLOAD",
                "the verified copy is authoritative and must survive")
        #expect(outcome.originalRemained,
                "and the leftover original is reported, not silently dropped")
        #expect(text(at: source) == "PAYLOAD", "the original is still there — untouched")
        #expect(copier.removedPaths == [source.path],
                "removal was attempted on the SOURCE only, never on the verified copy")
    }

    @Test("A clean cross-volume move reports no leftover original")
    func cleanCrossVolumeMoveReportsNoLeftover() throws {
        let mover = FileMover(
            renamer: StubRenamer(alwaysReturning: EXDEV), copier: FaultyCopier(.healthy)
        )
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("download.pdf", "PAYLOAD")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "report.pdf"
        )

        #expect(outcome.originalRemained == false)
        #expect(!exists(source))
    }

    @Test("The cross-volume copier refuses an occupied destination in the KERNEL")
    func crossVolumeCopyRefusesAnOccupiedDestination() throws {
        // COPYFILE_EXCL rather than a fileExists() pre-check: the refusal has
        // to be atomic with the create, or another process can slip a file in
        // between the check and the copy (M27).
        let copier = SystemCrossVolumeCopy()
        let precious = try makeFile("taken.pdf", "PRECIOUS")
        let source = try makeFile("download.pdf", "NEW")

        var thrown: CopyFailure?
        do throws(CopyFailure) {
            try copier.copyItem(at: source, to: precious)
        } catch {
            thrown = error
        }

        #expect(thrown == .destinationExists)
        #expect(text(at: precious) == "PRECIOUS", "the occupant's bytes are untouched")
        #expect(text(at: source) == "NEW")
    }

    @Test("The cross-volume copier copies a symlink AS a symlink")
    func crossVolumeCopyKeepsASymlinkALink() throws {
        let copier = SystemCrossVolumeCopy()
        let target = try makeFile("real-file.txt", "TARGET")
        let link = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let copied = tempDir.appendingPathComponent("copied-link.txt")

        try copier.copyItem(at: link, to: copied)

        let destinationOfCopy = try FileManager.default.destinationOfSymbolicLink(
            atPath: copied.path
        )
        #expect(destinationOfCopy == target.path, "the link was copied, not its contents")
        #expect(text(at: target) == "TARGET")
    }

    // MARK: - 6b. Self-rename on a deduped rung (M25)

    @Test("A ladder rung that lands on the source's OWN name is a no-op, not a fake move")
    func dedupedRungOntoTheSourcesOwnNameIsANoOp() throws {
        // The file is already "report 2.pdf" and "report.pdf" is taken by
        // something else, so rung 1 collides and rung 2 IS the file's own name.
        // renamex_np returns 0 for that self-rename, which would record an
        // undoable move that never happened.
        let mover = FileMover()
        let precious = try makeFile("report.pdf", "PRECIOUS")
        let source = try makeFile("report 2.pdf", "SAME")

        let outcome = try mover.move(
            from: source, intoDirectory: tempDir, preferredName: "report.pdf"
        )

        #expect(outcome.wasNoOp, "there is nothing to undo, so no history row may be written")
        #expect(outcome.finalURL.path == source.path)
        #expect(outcome.attemptsUsed == 2)
        #expect(text(at: source) == "SAME")
        #expect(text(at: precious) == "PRECIOUS")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tempDir.path).count == 2,
                "no third file may appear")
    }

    @Test("A no-op is still a no-op when the two directory paths spell it differently")
    func noOpSeesThroughASymlinkedDirectory() throws {
        // The registry hands back symlink-resolved URLs and the watcher does
        // not, so the same folder can arrive spelled two ways. Comparing the
        // literal paths would miss the no-op and record a phantom move (M26).
        let real = try makeDirectory("real-folder")
        let link = tempDir.appendingPathComponent("link-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let source = try makeFile("report.pdf", "SAME", in: real)

        #expect(FileMover.isNoOp(
            source: link.appendingPathComponent("report.pdf"),
            directory: real,
            preferredName: "report.pdf"
        ), "the same folder reached by two spellings is one folder")
    }

    // MARK: - 7. Names: Unicode and the byte budget

    @Test("Non-ASCII names move and keep their bytes",
          arguments: [
            "発注書 2026年6月.pdf",
            "facture café \u{301}été.pdf",
            "receipt 🧾💸 june.pdf",
            "فاتورة يونيو.pdf",
            "Ünïcödé — em–dash 'quotes'.pdf",
          ])
    func nonASCIINamesSurvive(preferred: String) throws {
        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("download.pdf", "PAYLOAD")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: preferred
        )

        #expect(exists(outcome.finalURL))
        #expect(text(at: outcome.finalURL) == "PAYLOAD")
        #expect(!exists(source))
        // Round-trippable: the name the mover reports is the name on disk, so
        // undo can find the file again by path.
        let listed = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(listed.count == 1)
        #expect(exists(outcome.finalURL), "the reported path must be the real one")
    }

    @Test("A name of 100 family emoji is trimmed to the 255-BYTE budget, extension kept")
    func hugeEmojiNameIsTrimmedToByteBudget() throws {
        // FilenameSanitizer caps at 100 grapheme clusters; one family emoji is
        // 25 UTF-8 bytes, so a "valid" sanitized name can be 2500 bytes and hit
        // ENAMETOOLONG (risk #10).
        let family = "👨‍👩‍👧‍👦"
        let preferred = String(repeating: family, count: 100) + ".pdf"
        #expect(preferred.utf8.count > 255)

        let mover = FileMover()
        let destination = try makeDirectory("Invoices")
        let source = try makeFile("download.pdf", "PAYLOAD")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: preferred
        )

        let final = outcome.finalName
        #expect(final.utf8.count <= FileMover.maxNameBytes)
        #expect(final.hasSuffix(".pdf"), "the extension must survive trimming")
        let stem = String(final.dropLast(4))
        #expect(!stem.isEmpty)
        #expect(stem.allSatisfy { String($0) == family },
                "no grapheme cluster may be split — that would produce mojibake")
        #expect(exists(outcome.finalURL))
        #expect(text(at: outcome.finalURL) == "PAYLOAD")
    }

    @Test("trimmedToByteBudget keeps names inside 255 UTF-8 bytes, extension intact",
          arguments: [
            "report.pdf",
            String(repeating: "a", count: 251) + ".pdf",          // exactly 255
            String(repeating: "a", count: 300) + ".pdf",          // over by 49
            String(repeating: "発", count: 200) + ".pdf",          // 3 bytes each
            String(repeating: "👨‍👩‍👧‍👦", count: 100) + ".pdf",       // 25 bytes each
            String(repeating: "b", count: 400),                    // no extension
          ])
    func byteBudgetTrimming(name: String) {
        let trimmed = FileMover.trimmedToByteBudget(name)

        #expect(trimmed.utf8.count <= FileMover.maxNameBytes)
        #expect(!trimmed.isEmpty)
        if name.utf8.count <= FileMover.maxNameBytes {
            #expect(trimmed == name, "a name that already fits must come back unchanged")
        }
        let originalExtension = (name as NSString).pathExtension
        if !originalExtension.isEmpty {
            #expect((trimmed as NSString).pathExtension == originalExtension,
                    "the extension is what tells macOS how to open the file")
        }
        // Never split a grapheme: the trimmed stem must be a prefix of the
        // original stem, character for character.
        let stem = (trimmed as NSString).deletingPathExtension
        let originalStem = (name as NSString).deletingPathExtension
        #expect(originalStem.hasPrefix(stem))
    }

    @Test("candidateName produces Finder-style names and stays inside the byte budget",
          arguments: [
            (preferred: "report.pdf", attempt: 1, expected: "report.pdf"),
            (preferred: "report.pdf", attempt: 2, expected: "report 2.pdf"),
            (preferred: "report.pdf", attempt: 10, expected: "report 10.pdf"),
            (preferred: "report", attempt: 2, expected: "report 2"),
            (preferred: "archive.tar.gz", attempt: 2, expected: "archive.tar 2.gz"),
            (preferred: "caf\u{e9}.txt", attempt: 2, expected: "caf\u{e9} 2.txt"),
          ])
    func candidateNaming(preferred: String, attempt: Int, expected: String) {
        #expect(FileMover.candidateName(for: preferred, attempt: attempt) == expected)
    }

    @Test("A 255-byte name still fits after the collision suffix is added")
    func candidateNameRespectsTheByteBudget() {
        let full = String(repeating: "a", count: 251) + ".pdf"
        #expect(full.utf8.count == 255)

        let candidate = FileMover.candidateName(for: full, attempt: 2)

        #expect(candidate.utf8.count <= FileMover.maxNameBytes)
        #expect(candidate.hasSuffix(" 2.pdf"), "the suffix survives; the stem is what gives way")
    }

    // MARK: - 8. The watcher hand-off

    @Test("Every candidate is announced BEFORE it is attempted, in ladder order")
    func candidatesAreAnnouncedBeforeEachAttempt() throws {
        // The watcher diffs ~/Downloads by NAME, so a rename in place (or an
        // undo restore) looks like a brand-new download unless the name is
        // pre-registered before it appears (risk #8).
        let log = AnnouncementLog()
        let mover = FileMover(announceCandidate: { url, group in log.record(url, group: group) })
        let destination = try makeDirectory("Invoices")
        try makeFile("report.pdf", "PRECIOUS", in: destination)
        let source = try makeFile("download.pdf", "NEW")

        let outcome = try mover.move(
            from: source, intoDirectory: destination, preferredName: "report.pdf"
        )

        #expect(outcome.finalName == "report 2.pdf")
        #expect(log.names == ["report.pdf", "report 2.pdf"],
                "each candidate is announced before its attempt, including ones not used")
        // The unused rung ("report.pdf") is only retirable if it shares a claim
        // group with the one that landed — otherwise it would linger and swallow
        // a real download of that name (M7).
        #expect(log.groups.count == 1, "one move announces all its candidates under one group")
    }
}
