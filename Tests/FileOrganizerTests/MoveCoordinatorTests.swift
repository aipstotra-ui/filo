import Foundation
import Testing
@testable import FileOrganizer

// MARK: - Test doubles

/// A renamer that always reports the same errno without touching the disk —
/// used to make the MOVE fail after the resolver has already approved the
/// destination (the real-world race: permissions change between the two).
private struct FailingRenamer: ExclusiveRenaming {
    let code: Int32
    func renameExclusive(from sourcePath: String, to destinationPath: String) -> Int32 { code }
}

/// Stands in for `FolderRegistry`, pointing at REAL temp directories so the
/// mover does real work.
@MainActor
private final class FakeFolderRegistry: DestinationResolving {
    var destinations: [Int64: LiveDestination] = [:]

    func liveDestination(forStoreID storeID: Int64) -> LiveDestination? {
        destinations[storeID]
    }

    func registeredFolderURLs() -> [URL] {
        destinations.values.map(\.url)
    }
}

// MARK: - Suite

/// The orchestration that turns one Accept into a moved file plus an undoable
/// history row. These tests use a real history database and a real filesystem
/// in a per-test temp directory, because the ordering between the two IS the
/// thing under test: a history row that says a move happened when it did not
/// (or a move with no row) is the failure this milestone exists to prevent.
@MainActor
@Suite("MoveCoordinator")
final class MoveCoordinatorTests {

    private let tempDir: URL
    private let downloads: URL
    private let invoices: URL
    private let databaseURL: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoveCoordinatorTests-\(UUID().uuidString)")
        downloads = tempDir.appendingPathComponent("Downloads")
        invoices = tempDir.appendingPathComponent("Invoices")
        databaseURL = tempDir.appendingPathComponent("container").appendingPathComponent("history.db")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invoices, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    private func store() throws -> MoveHistoryStore {
        try MoveHistoryStore(databaseURL: databaseURL)
    }

    private func coordinator(
        store: MoveHistoryStore,
        mover: FileMover = FileMover(),
        registeredFolders: [Int64: LiveDestination]? = nil,
        claims: AppCreatedFileClaims? = nil
    ) -> MoveCoordinator {
        let registry = FakeFolderRegistry()
        registry.destinations = registeredFolders
            ?? [7: LiveDestination(url: invoices, displayName: "Invoices")]
        return MoveCoordinator(
            store: store,
            resolver: MoveDestinationResolver(
                registry: registry, watchedDirectory: downloads
            ),
            mover: mover,
            claims: claims
        )
    }

    @discardableResult
    private func makeDownload(_ name: String, _ contents: String) throws -> URL {
        let url = downloads.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func decision(
        source: URL,
        chosen: String,
        folderID: Int64? = 7,
        folderName: String? = "Invoices",
        fileEventID: UUID = UUID()
    ) -> AcceptedSuggestion {
        AcceptedSuggestion(
            fileEventID: fileEventID,
            sourceURL: source,
            originalName: source.lastPathComponent,
            chosenFilename: chosen,
            destinationFolderID: folderID,
            destinationFolderName: folderName
        )
    }

    private func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Name → bytes for everything under the two user-visible directories.
    /// The history database lives elsewhere in the temp tree, so this snapshot
    /// answers exactly one question: did any of the user's files change?
    private func userFilesSnapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for directory in [downloads, invoices] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                let url = directory.appendingPathComponent(name)
                result[directory.lastPathComponent + "/" + name] = (try? Data(contentsOf: url)) ?? Data()
            }
        }
        return result
    }

    private func describe(_ outcome: AcceptOutcome) -> String {
        switch outcome {
        case .moved: "moved"
        case .unchanged: "unchanged"
        case .failed(.historyUnavailable): "failed(historyUnavailable)"
        case .failed(.moveFailed(let error)): "failed(moveFailed:\(errorName(error)))"
        case .failed(.alreadyInFlight): "failed(alreadyInFlight)"
        }
    }

    private func describe(_ outcome: UndoOutcome) -> String {
        switch outcome {
        case .restored: "restored"
        case .failed(.unknownRecord): "failed(unknownRecord)"
        case .failed(.notUndoable(let state)): "failed(notUndoable:\(state.rawValue))"
        case .failed(.alreadyInFlight): "failed(alreadyInFlight)"
        case .failed(.fileNotWhereWeLeftIt): "failed(fileNotWhereWeLeftIt)"
        case .failed(.originalDirectoryMissing): "failed(originalDirectoryMissing)"
        case .failed(.destinationOutsideAllowedFolders): "failed(destinationOutsideAllowedFolders)"
        case .failed(.restoreFailed(let error)): "failed(restoreFailed:\(errorName(error)))"
        case .failed(.historyUnavailable): "failed(historyUnavailable)"
        }
    }

    private func errorName(_ error: MoveError) -> String {
        switch error {
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

    private func summary(_ outcome: AcceptOutcome) -> MoveSummary? {
        if case .moved(let summary) = outcome { return summary }
        return nil
    }

    // MARK: - 1. Fail closed (founder decision 1)

    @Test("If the intent row can't be written, the file is NOT touched")
    func failsClosedWhenHistoryIsUnavailable() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan 2026-07-20 14.33.pdf", "PAYLOAD")
        let before = try userFilesSnapshot()
        // The history database is unusable — the exact situation founder
        // decision 1 covers.
        await store.close()

        let outcome = await coordinator.accept(
            decision(source: source, chosen: "Chase Statement.pdf")
        )

        #expect(describe(outcome) == "failed(historyUnavailable)")
        #expect(try userFilesSnapshot() == before,
                "no move, no rename, no creation — an unrecorded move is worse than no move")
        #expect(text(at: source) == "PAYLOAD")
        #expect(coordinator.recent.isEmpty)
    }

    // MARK: - 2. The happy path

    @Test("A successful accept moves the file and leaves an undoable row")
    func successfulAcceptMovesAndRecords() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan 2026-07-20 14.33.pdf", "PAYLOAD")
        let decision = decision(source: source, chosen: "Chase Statement.pdf")

        let outcome = await coordinator.accept(decision)

        #expect(describe(outcome) == "moved")
        let summary = try #require(self.summary(outcome))
        #expect(summary.finalName == "Chase Statement.pdf")
        #expect(summary.destinationFolderName == "Invoices")
        #expect(summary.fallbackReason == nil)
        #expect(!exists(source))
        #expect(text(at: invoices.appendingPathComponent("Chase Statement.pdf")) == "PAYLOAD")

        let row = try #require(try await store.record(id: summary.recordID))
        #expect(row.state == .moved)
        #expect(row.isUndoable)
        #expect(row.finalDirectory.path == invoices.path,
                "the RESOLVED path is persisted, never the folder's store id")
        #expect(row.originalName == "Scan 2026-07-20 14.33.pdf")
        #expect(coordinator.recent.first?.id == summary.recordID)
        #expect(describe(coordinator.outcomes[decision.fileEventID] ?? .unchanged) == "moved",
                "the menu row needs the outcome too — it has no popup to hold open")
        await store.close()
    }

    @Test("A failed move marks the row failed and reports it — the popup must stay open")
    func failedMoveMarksTheRowAndReports() async throws {
        let store = try store()
        // Permissions changed between the resolver's check and the move: the
        // move fails even though the destination looked fine.
        let coordinator = coordinator(
            store: store, mover: FileMover(renamer: FailingRenamer(code: EACCES))
        )
        let source = try makeDownload("Scan.pdf", "PAYLOAD")

        let outcome = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))

        #expect(describe(outcome) == "failed(moveFailed:destinationNotWritable)")
        #expect(text(at: source) == "PAYLOAD", "the source must be exactly where it was")
        let rows = try await store.recent(limit: 10)
        #expect(rows.count == 1, "the intent row stays as evidence, marked failed")
        #expect(rows.first?.state == .failed)
        #expect(rows.first?.isUndoable == false)
        #expect(rows.first?.failureDetail?.isEmpty == false, "a failed row says why")
        if case .failed(let failure) = outcome {
            #expect(!failure.message.isEmpty, "the popup needs something honest to show")
        }
        await store.close()
    }

    // MARK: - 3. The no-op

    @Test("Accepting the name a file already has writes NO history row")
    func selfRenameWritesNoHistoryRow() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("report.pdf", "SAME")

        let outcome = await coordinator.accept(decision(
            source: source, chosen: "report.pdf", folderID: nil, folderName: nil
        ))

        #expect(describe(outcome) == "unchanged")
        #expect(text(at: source) == "SAME")
        #expect(try await store.recent(limit: 10).isEmpty,
                "there is nothing to undo, so there must be nothing to offer undo for")
        #expect(coordinator.recent.isEmpty)
        await store.close()
    }

    // MARK: - 4. Fallback (founder decision 2)

    @Test("A destination folder that is gone renames in place and says why")
    func missingFolderRenamesInPlace() async throws {
        let store = try store()
        // Nothing registered: the folder id the popup captured is stale.
        let coordinator = coordinator(store: store, registeredFolders: [:])
        let source = try makeDownload("Scan.pdf", "PAYLOAD")

        let outcome = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))

        #expect(describe(outcome) == "moved")
        let summary = try #require(self.summary(outcome))
        #expect(summary.fallbackReason == .folderNotRegistered)
        #expect(summary.destinationFolderName == nil)
        #expect(summary.finalURL.deletingLastPathComponent().path == downloads.path)
        #expect(text(at: downloads.appendingPathComponent("Statement.pdf")) == "PAYLOAD")
        #expect(try await store.recent(limit: 1).first?.fallbackReason == .folderNotRegistered,
                "the history has to remember why, or the menu line would be a guess")
        await store.close()
    }

    @Test("A fallback that happens to change nothing is still recorded, and still says why")
    func fallbackThatChangesNothingIsStillRecorded() async throws {
        // The user accepted "call it report.pdf, put it in Invoices". Invoices
        // is gone, so the destination falls back to the file's own folder — and
        // the name it already has. Nothing happens on disk. Closing as a silent
        // success would leave the user believing the file is in Invoices, with
        // no row and no message anywhere saying otherwise (M4).
        let store = try store()
        let coordinator = coordinator(store: store, registeredFolders: [:])
        let source = try makeDownload("report.pdf", "PAYLOAD")

        let outcome = await coordinator.accept(decision(source: source, chosen: "report.pdf"))

        #expect(describe(outcome) == "moved", "not 'unchanged' — that closes as success")
        let summary = try #require(self.summary(outcome))
        #expect(summary.fallbackReason == .folderNotRegistered)
        #expect(summary.nothingChangedOnDisk, "the UI has to be able to say nothing happened")
        #expect(text(at: source) == "PAYLOAD", "and nothing did happen")
        let rows = try await store.recent(limit: 10)
        #expect(rows.count == 1, "there IS something to record: what the user asked for failed")
        #expect(rows.first?.fallbackReason == .folderNotRegistered)
        await store.close()
    }

    // MARK: - 5. Double accept (risk #11)

    @Test("Two accepts racing the same file move it exactly once")
    func concurrentAcceptsMoveTheFileOnce() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan.pdf", "PAYLOAD")
        let eventID = UUID()
        let first = decision(source: source, chosen: "Statement.pdf", fileEventID: eventID)
        let second = decision(source: source, chosen: "Statement.pdf", fileEventID: eventID)

        // The popup's Accept and the menu row's Accept, pressed together. The
        // in-flight claim has to be taken BEFORE the first suspension point,
        // or both calls sail past it.
        async let firstOutcome = coordinator.accept(first)
        async let secondOutcome = coordinator.accept(second)
        let outcomes = await [firstOutcome, secondOutcome].map(describe)

        #expect(outcomes.filter { $0 == "moved" }.count == 1)
        #expect(outcomes.filter { $0 == "failed(alreadyInFlight)" }.count == 1)
        #expect(try await store.recent(limit: 10).count == 1, "exactly one history row")
        #expect(try FileManager.default.contentsOfDirectory(atPath: invoices.path).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
        #expect(coordinator.inFlight.isEmpty, "the claim is released when the move settles")
        await store.close()
    }

    // MARK: - 5a. Two files, one suggested name (founder-reported, 2026-07-28)

    @Test("Two different files accepted under the SAME name: neither is overwritten")
    func twoFilesWithTheSameSuggestedNameBothSurvive() async throws {
        // Reported from live use: two downloads were both suggested
        // "Aiden_Chung.pdf" into the same folder. macOS would normally refuse a
        // duplicate name, so the question was whether this app had bypassed that
        // and clobbered the first file. It must not: the second lands on a
        // deduped name and the first keeps its bytes.
        let store = try store()
        let coordinator = coordinator(store: store)
        let first = try makeDownload("certificate-rdg3w7j23w9n.pdf", "FIRST FILE")
        let second = try makeDownload("213523412342.pdf", "SECOND FILE")

        let firstOutcome = await coordinator.accept(
            decision(source: first, chosen: "Aiden_Chung.pdf")
        )
        let secondOutcome = await coordinator.accept(
            decision(source: second, chosen: "Aiden_Chung.pdf")
        )

        let firstSummary = try #require(self.summary(firstOutcome))
        let secondSummary = try #require(self.summary(secondOutcome))

        #expect(firstSummary.finalURL.lastPathComponent == "Aiden_Chung.pdf")
        #expect(secondSummary.finalURL.lastPathComponent == "Aiden_Chung 2.pdf",
                "the second file must be deduped, never written over the first")
        #expect(secondSummary.wasRenamedForCollision,
                "and the summary must say so, so the popup can tell the user")

        // The load-bearing assertion: the first file's BYTES are still there.
        #expect(text(at: invoices.appendingPathComponent("Aiden_Chung.pdf")) == "FIRST FILE")
        #expect(text(at: invoices.appendingPathComponent("Aiden_Chung 2.pdf")) == "SECOND FILE")
        #expect(try FileManager.default.contentsOfDirectory(atPath: invoices.path).count == 2,
                "two files in, two files out — nothing vanished")

        // And the history must record where each file REALLY went, or undo
        // would put the wrong one back.
        let rows = try await store.recent(limit: 10)
        #expect(Set(rows.map(\.finalName)) == ["Aiden_Chung.pdf", "Aiden_Chung 2.pdf"])
        await store.close()
    }

    @Test("Re-accepting the SAME file after it was put back reuses the freed name")
    func reacceptingTheSameFileReusesTheName() async throws {
        // The other reading of the same live report: one file moved, undone, and
        // accepted again. The name is free by then, so both history rows legitimately
        // say "Aiden_Chung.pdf" — and that is not a duplicate on disk.
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("certificate.pdf", "PAYLOAD")

        let first = await coordinator.accept(decision(source: source, chosen: "Aiden_Chung.pdf"))
        let firstSummary = try #require(self.summary(first))
        _ = await coordinator.undo(recordID: firstSummary.recordID)

        let restored = downloads.appendingPathComponent("certificate.pdf")
        let second = await coordinator.accept(decision(source: restored, chosen: "Aiden_Chung.pdf"))
        let secondSummary = try #require(self.summary(second))

        #expect(secondSummary.finalURL.lastPathComponent == "Aiden_Chung.pdf",
                "the name was freed by the undo, so no dedupe is needed")
        #expect(secondSummary.wasRenamedForCollision == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: invoices.path).count == 1,
                "still exactly one file — two history rows, one file")
        await store.close()
    }

    // MARK: - 5b. Watcher claims (M7)

    /// A mover wired to a claim box exactly the way `App.swift` wires the real
    /// one: the announcer is set on the mover, the coordinator holds the box so
    /// it can retire unused rungs when a move settles.
    private func claimingMover(_ claims: AppCreatedFileClaims) -> FileMover {
        FileMover(announceCandidate: { url, group in claims.claim(url, group: group) })
    }

    @Test("M7: a move into another folder claims nothing in the watched folder")
    func movingOutOfDownloadsClaimsNothing() async throws {
        let claims = AppCreatedFileClaims(watching: downloads)
        let store = try store()
        let coordinator = coordinator(store: store, mover: claimingMover(claims), claims: claims)
        let source = try makeDownload("scan.pdf", "PAYLOAD")

        _ = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))

        #expect(claims.count == 0,
                "the file landed in Invoices; the watcher will never see that name")
        await store.close()
    }

    @Test("M7: an undo's unused collision rungs are released, so a real download still gets seen")
    func undoReleasesTheRungsItDidNotUse() async throws {
        let claims = AppCreatedFileClaims(watching: downloads)
        let store = try store()
        let coordinator = coordinator(store: store, mover: claimingMover(claims), claims: claims)
        let source = try makeDownload("scan.pdf", "PAYLOAD")
        let accepted = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))
        let summary = try #require(self.summary(accepted))
        // Something else has taken the original name in the meantime, so the
        // restore has to walk its collision ladder — claiming "scan.pdf" (which
        // it cannot use) before landing on "scan 2.pdf".
        try makeDownload("scan.pdf", "A DIFFERENT FILE")

        let undone = await coordinator.undo(recordID: summary.recordID)

        #expect(describe(undone) == "restored")
        #expect(claims.count == 1, "only the name the file actually landed under stays claimed")

        // The user now downloads a real file called scan.pdf. It must still be
        // announced — the released rung must not have swallowed it (M7).
        let adopted = claims.consumeAppeared(presentNames: ["scan.pdf", "scan 2.pdf"])
        #expect(adopted == ["scan 2.pdf"],
                "our restored file is adopted; the user's own scan.pdf is not")
        await store.close()
    }

    @Test("M7: a failed move leaves no claim behind at all")
    func failedMoveLeavesNoClaims() async throws {
        let claims = AppCreatedFileClaims(watching: downloads)
        let store = try store()
        // Every rename fails with a plain permissions error, so the move cannot
        // land anywhere — but the candidates were still announced first.
        let mover = FileMover(
            renamer: FailingRenamer(code: EACCES),
            announceCandidate: { url, group in claims.claim(url, group: group) }
        )
        let coordinator = coordinator(store: store, mover: mover, claims: claims)
        let source = try makeDownload("scan.pdf", "PAYLOAD")

        // No destination folder, so this is a rename in place — the destination
        // IS the watched folder, which is the only case where a leftover claim
        // could shadow a real download.
        let outcome = await coordinator.accept(
            decision(source: source, chosen: "Statement.pdf", folderID: nil, folderName: nil)
        )

        #expect(describe(outcome).hasPrefix("failed"), "the move must not have succeeded")
        #expect(claims.count == 0, "nothing was created, so nothing may stay claimed")
        #expect(claims.consumeAppeared(presentNames: ["scan.pdf"]).isEmpty,
                "a file of that name is now a genuine download, not our output")
        await store.close()
    }

    // MARK: - 6. Undo

    @Test("Undo puts the file back under its original name")
    func undoRestoresTheOriginalName() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan 2026-07-20 14.33.pdf", "PAYLOAD")
        let accepted = await coordinator.accept(
            decision(source: source, chosen: "Chase Statement.pdf")
        )
        let summary = try #require(self.summary(accepted))

        let undone = await coordinator.undo(recordID: summary.recordID)

        #expect(describe(undone) == "restored")
        if case .restored(let url, let renamed) = undone {
            #expect(url.path == source.path)
            #expect(renamed == false)
        }
        #expect(text(at: source) == "PAYLOAD", "same bytes, same name, same folder")
        #expect(try FileManager.default.contentsOfDirectory(atPath: invoices.path).isEmpty)
        let row = try #require(try await store.record(id: summary.recordID))
        #expect(row.state == .undone)
        #expect(row.isUndoable == false)
        await store.close()
    }

    @Test("Undo NEVER overwrites a newer file that took the original name")
    func undoNeverOverwritesANewerFile() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("report.pdf", "ORIGINAL")
        let accepted = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))
        let summary = try #require(self.summary(accepted))
        // The user downloaded another report.pdf in the meantime.
        try makeDownload("report.pdf", "NEWER")

        let undone = await coordinator.undo(recordID: summary.recordID)

        #expect(describe(undone) == "restored")
        #expect(text(at: downloads.appendingPathComponent("report.pdf")) == "NEWER",
                "the newer file's BYTES must be untouched — undo uses the same no-clobber mover")
        #expect(text(at: downloads.appendingPathComponent("report 2.pdf")) == "ORIGINAL")
        if case .restored(let url, let renamed) = undone {
            #expect(url.lastPathComponent == "report 2.pdf")
            #expect(renamed, "the UI has to be able to say 'restored as report 2.pdf'")
        }
        let row = try #require(try await store.record(id: summary.recordID))
        #expect(row.state == .undone)
        #expect(row.finalName == "report 2.pdf", "the row records where the file actually IS")
        await store.close()
    }

    @Test("Undo of a file the user has since moved fails honestly and stays undoable")
    func undoOfAMovedFileFailsHonestly() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan.pdf", "PAYLOAD")
        let accepted = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))
        let summary = try #require(self.summary(accepted))
        // The user moved it somewhere of their own choosing.
        let userChosen = tempDir.appendingPathComponent("Statement.pdf")
        try FileManager.default.moveItem(at: summary.finalURL, to: userChosen)

        let undone = await coordinator.undo(recordID: summary.recordID)

        #expect(describe(undone) == "failed(fileNotWhereWeLeftIt)")
        #expect(text(at: userChosen) == "PAYLOAD",
                "we never search the disk and never guess — the user's file is left alone")
        #expect(!exists(source))
        let row = try #require(try await store.record(id: summary.recordID))
        #expect(row.state == .moved, "the row keeps its state")
        #expect(row.isUndoable, "so Undo stays offered — the user may put the file back")
        if case .failed(let error) = undone {
            #expect(!error.message.isEmpty)
        }
        await store.close()
    }

    @Test("Undo when the original folder is gone fails typed — we never recreate directories")
    func undoNeverRecreatesTheOriginalDirectory() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan.pdf", "PAYLOAD")
        let accepted = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))
        let summary = try #require(self.summary(accepted))
        try FileManager.default.removeItem(at: downloads)

        let undone = await coordinator.undo(recordID: summary.recordID)

        #expect(describe(undone) == "failed(originalDirectoryMissing)")
        #expect(!exists(downloads), "creating folders on the user's behalf is not this app's job")
        #expect(text(at: summary.finalURL) == "PAYLOAD", "the file stays where it is")
        await store.close()
    }

    @Test("A second undo of the same entry does nothing")
    func doubleUndoIsRefused() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan.pdf", "PAYLOAD")
        let accepted = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))
        let summary = try #require(self.summary(accepted))

        let first = await coordinator.undo(recordID: summary.recordID)
        let second = await coordinator.undo(recordID: summary.recordID)

        #expect(describe(first) == "restored")
        #expect(describe(second) == "failed(notUndoable:undone)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path) == ["Scan.pdf"])
        #expect(text(at: source) == "PAYLOAD")
        await store.close()
    }

    @Test("Undo of an id that is not in the history fails typed")
    func undoOfUnknownRecordFails() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)

        let undone = await coordinator.undo(recordID: 4242)

        #expect(describe(undone) == "failed(unknownRecord)")
        await store.close()
    }

    @Test("Undo works after a relaunch: it is path-based, never store-id-based")
    func undoSurvivesRelaunch() async throws {
        let firstRun = try store()
        let firstCoordinator = coordinator(store: firstRun)
        let source = try makeDownload("Scan.pdf", "PAYLOAD")
        let accepted = await firstCoordinator.accept(
            decision(source: source, chosen: "Statement.pdf")
        )
        let summary = try #require(self.summary(accepted))
        await firstRun.close()

        // Quit and relaunch: a brand-new store and coordinator over the same file.
        let secondRun = try store()
        let secondCoordinator = coordinator(store: secondRun)
        await secondCoordinator.start()
        let undone = await secondCoordinator.undo(recordID: summary.recordID)

        #expect(describe(undone) == "restored")
        #expect(text(at: source) == "PAYLOAD")
        #expect(secondCoordinator.recent.contains { $0.id == summary.recordID },
                "the history survives a relaunch")
        await secondRun.close()
    }

    // MARK: - 7. Launch and retention

    /// One stranded `inProgress` row, exactly as a crash mid-move leaves it:
    /// the intent is written (with the source file's identity) and the file is
    /// then moved for real, with no `finalize`.
    @discardableResult
    private func strandARow(
        sourceName: String,
        contents: String,
        intendedName: String,
        actuallyLandingAt landedName: String?,
        in store: MoveHistoryStore
    ) async throws -> Int64 {
        let source = try makeDownload(sourceName, contents)
        let id = try await store.recordIntent(MoveIntent(
            fileEventID: UUID(),
            originalDirectory: downloads,
            originalName: sourceName,
            intendedDirectory: invoices,
            intendedName: intendedName,
            destinationFolderName: "Invoices",
            fallbackReason: nil,
            sourceIdentity: FileIdentity.ofItem(atPath: source.path),
            acceptedAt: Date()
        ))
        if let landedName {
            // A real same-volume move: the file keeps its inode, which is what
            // the reconcile proves identity with.
            try FileManager.default.moveItem(
                at: source, to: invoices.appendingPathComponent(landedName)
            )
        }
        return id
    }

    @Test("start() reconciles stranded rows and publishes the retained history")
    func startReconcilesAndPublishesHistory() async throws {
        // Founder decision 3 set retention at 200; founder decision 6 then moved
        // the list from the menu (which showed 5) into Settings, where the whole
        // retained history fits in a scrolling window.
        #expect(MoveCoordinator.historyLimit == MoveHistoryStore.retentionLimit)
        #expect(MoveHistoryStore.retentionLimit == 200)

        let store = try store()
        // Seven finished moves plus one row stranded by a crash mid-move.
        for index in 1...7 {
            let id = try await store.recordIntent(MoveIntent(
                fileEventID: UUID(),
                originalDirectory: downloads,
                originalName: "old-\(index).pdf",
                intendedDirectory: invoices,
                intendedName: "new-\(index).pdf",
                destinationFolderName: "Invoices",
                fallbackReason: nil,
                sourceIdentity: nil,
                acceptedAt: Date()
            ))
            try await store.finalize(
                id: id, finalDirectory: invoices, finalName: "new-\(index).pdf", at: Date()
            )
        }
        // On disk it is clear what happened: the source is gone, and the file at
        // the target is the very file the row is about.
        let strandedID = try await strandARow(
            sourceName: "stranded.pdf",
            contents: "PAYLOAD",
            intendedName: "stranded.pdf",
            actuallyLandingAt: "stranded.pdf",
            in: store
        )

        let coordinator = coordinator(store: store)
        await coordinator.start()

        #expect(try await store.record(id: strandedID)?.state == .moved,
                "a crash mid-move must resolve to the truth on disk, not stay stranded")
        #expect(coordinator.recent.count == 8, "all eight rows are published, none dropped")
        #expect(coordinator.recent.first?.id == strandedID, "newest first")
        #expect(try await store.inProgressRecords().isEmpty)
        #expect(coordinator.historyProblem == nil, "a clean launch has nothing to complain about")
        await store.close()
    }

    @Test("A stranded row NEVER adopts a stranger's file that happens to share its name")
    func reconcileNeverAdoptsAStrangersFile() async throws {
        // The row records the name the mover INTENDED. The collision ladder (or
        // the 255-byte trim) can land the file somewhere else, and then the file
        // at the intended name belongs to someone else entirely. Adopting it
        // would offer the user an Undo that moves a file this app never touched,
        // and orphan the file that really did move (C2).
        let store = try store()
        let stranger = invoices.appendingPathComponent("report.pdf")
        try Data("STRANGER".utf8).write(to: stranger)
        let strandedID = try await strandARow(
            sourceName: "scan.pdf",
            contents: "OURS",
            intendedName: "report.pdf",          // what the row says
            actuallyLandingAt: "report 2.pdf",   // where the ladder actually put it
            in: store
        )

        let coordinator = coordinator(store: store)
        await coordinator.start()

        let row = try #require(try await store.record(id: strandedID))
        #expect(row.state == .unknown,
                "the source is gone and a file IS at the target — but it is not ours")
        #expect(row.isUndoable == false, "so no Undo may be offered")
        #expect(text(at: stranger) == "STRANGER", "the stranger's file is untouched")

        // And Undo is refused even if something calls it anyway.
        let undone = await coordinator.undo(recordID: strandedID)
        #expect(describe(undone) == "failed(notUndoable:unknown)")
        #expect(text(at: stranger) == "STRANGER")
        #expect(text(at: invoices.appendingPathComponent("report 2.pdf")) == "OURS")
        await store.close()
    }

    @Test("A stranded row whose file really is at the target reconciles to moved")
    func reconcileAdoptsOurOwnFile() async throws {
        // The control for the test above: same shape, but the file at the
        // target IS the one the row is about, proven by identity.
        let store = try store()
        let strandedID = try await strandARow(
            sourceName: "scan.pdf",
            contents: "OURS",
            intendedName: "report.pdf",
            actuallyLandingAt: "report.pdf",
            in: store
        )

        let coordinator = coordinator(store: store)
        await coordinator.start()

        let row = try #require(try await store.record(id: strandedID))
        #expect(row.state == .moved)
        #expect(row.isUndoable, "a crash must not cost the user their undo")
        await store.close()
    }

    @Test("A row with no recorded identity is never adopted — nil is 'cannot prove'")
    func reconcileWillNotProveAnythingWithoutAnIdentity() async throws {
        // Rows written before the identity columns existed, or whose source
        // could not be stat'ed. "We do not know" must not read as "yes".
        let store = try store()
        let id = try await store.recordIntent(MoveIntent(
            fileEventID: UUID(),
            originalDirectory: downloads,
            originalName: "scan.pdf",
            intendedDirectory: invoices,
            intendedName: "report.pdf",
            destinationFolderName: "Invoices",
            fallbackReason: nil,
            sourceIdentity: nil,
            acceptedAt: Date()
        ))
        try Data("SOMETHING".utf8).write(to: invoices.appendingPathComponent("report.pdf"))

        let coordinator = coordinator(store: store)
        await coordinator.start()

        #expect(try await store.record(id: id)?.state == .unknown)
        await store.close()
    }

    @Test("Clear history empties the log without touching a single file")
    func clearHistoryTouchesNoFiles() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan.pdf", "PAYLOAD")
        _ = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))
        let filesBefore = try userFilesSnapshot()

        let error = await coordinator.clearHistory()

        #expect(error == nil)
        #expect(coordinator.recent.isEmpty)
        #expect(try await store.recent(limit: 10).isEmpty)
        #expect(try userFilesSnapshot() == filesBefore,
                "clearing the log is not deleting the user's files")
        await store.close()
    }

    // MARK: - F1: undo must not relocate a stranger's file

    @Test("F1: undo REFUSES when a different file now sits at the recorded path")
    func undoRefusesAStrangerAtTheRecordedPath() async throws {
        // The reachable version of C2's harm. Retention is 200 rows, not 200
        // hours, so months later the row is still here offering Undo:
        //   1. Accept moves Downloads/scan.pdf → Invoices/report.pdf.
        //   2. The user deletes it and later files an UNRELATED report.pdf into
        //      Invoices by hand. Ordinary housekeeping.
        //   3. Undo used to check only that *something* was at that path, so it
        //      moved the stranger's file into Downloads and renamed it scan.pdf.
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("scan.pdf", "MINE")
        let outcome = await coordinator.accept(decision(source: source, chosen: "report.pdf"))
        guard case .moved(let summary) = outcome else {
            Issue.record("guard: the move itself must succeed, got \(describe(outcome))")
            return
        }

        // The user deletes our file and puts a different one at that exact path.
        try FileManager.default.removeItem(at: summary.finalURL)
        try Data("SOMEBODY ELSE'S FILE".utf8).write(to: summary.finalURL)

        let undo = await coordinator.undo(recordID: summary.recordID)

        guard case .failed(.fileNotWhereWeLeftIt) = undo else {
            Issue.record("undo must refuse a file it cannot prove is ours, got \(undo)")
            return
        }
        #expect(text(at: summary.finalURL) == "SOMEBODY ELSE'S FILE",
                "the stranger's file is exactly where its owner left it")
        #expect(!exists(downloads.appendingPathComponent("scan.pdf")),
                "and nothing was moved into Downloads")
        await store.close()
    }

    @Test("F1: an ordinary undo of our own file still works")
    func undoStillWorksForOurOwnFile() async throws {
        // The other half of F1: the identity check must not break the everyday
        // case. Without this, "refuse everything" would pass the test above.
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("scan.pdf", "MINE")
        guard case .moved(let summary) = await coordinator.accept(
            decision(source: source, chosen: "report.pdf")
        ) else {
            Issue.record("guard: the move itself must succeed")
            return
        }

        let undo = await coordinator.undo(recordID: summary.recordID)

        guard case .restored = undo else {
            Issue.record("an untouched file must still be undoable, got \(undo)")
            return
        }
        #expect(text(at: downloads.appendingPathComponent("scan.pdf")) == "MINE")
        await store.close()
    }

    // MARK: - F7: an honest message must survive the refresh that follows it

    @Test("F7: 'that move happened but couldn't be recorded' is not wiped microseconds later")
    func moveProblemSurvivesTheRefresh() async throws {
        // The single most important sentence in this milestone — *the move
        // happened and cannot be undone* — was written by `settle`'s catch and
        // then erased by the `refreshRecent()` on the very next line, which used
        // to clear `historyProblem` unconditionally. In practice the only
        // message that could ever reach a screen was "your undo history couldn't
        // be read".
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("Scan.pdf", "PAYLOAD")

        // The intent row lands, the file really moves, and THEN the row cannot
        // be settled — the one ordering this milestone exists to be honest about.
        await store.failNextWrite()
        let outcome = await coordinator.accept(decision(source: source, chosen: "Statement.pdf"))

        guard case .moved = outcome else {
            Issue.record("the file did move, so that is what must be reported, got \(describe(outcome))")
            return
        }
        #expect(exists(invoices.appendingPathComponent("Statement.pdf")),
                "guard: the file genuinely moved")
        let problem = try #require(coordinator.historyProblem,
                                   "the user must be told the move can't be undone")
        #expect(problem.contains("can't be undone"))

        // The rule itself: a later successful read must NOT clear it. `start()`
        // ends in `refreshRecent()`, which is the exact call that used to wipe it.
        await coordinator.start()
        #expect(coordinator.historyProblem == problem,
                "re-reading the table does not un-happen an unrecorded move")
        await store.close()
    }

    @Test("F7: a problem that only describes the table IS cleared by a good read")
    func readProblemIsClearedByAGoodRead() async throws {
        // The other half. Without this, "never clear anything" would pass the
        // test above and leave a stale banner on screen forever.
        let store = try store()
        let coordinator = coordinator(store: store)
        await store.close()

        await coordinator.start()
        #expect(coordinator.historyProblem != nil, "guard: an unreadable table is reported")

        let reopened = try self.store()
        let healthy = self.coordinator(store: reopened)
        await healthy.start()
        #expect(healthy.historyProblem == nil, "a table that reads fine says nothing")
        await reopened.close()
    }

    // MARK: - F8: an undo that moved the file but could not record it

    @Test("F8: an undo whose history write fails still reports the file as restored")
    func undoThatCannotRecordStillTellsTheTruthAboutTheFile() async throws {
        let store = try store()
        let coordinator = coordinator(store: store)
        let source = try makeDownload("scan.pdf", "MINE")
        guard case .moved(let summary) = await coordinator.accept(
            decision(source: source, chosen: "report.pdf")
        ) else {
            Issue.record("guard: the move itself must succeed")
            return
        }

        // The row is read fine and the file moves back fine; only the flip to
        // `undone` fails. The file IS back — the record is what is wrong.
        await store.failNextWrite()
        let undo = await coordinator.undo(recordID: summary.recordID)

        // Before the fix this returned `.failed`, which is a lie about the disk.
        guard case .restored = undo else {
            Issue.record("the file really is back, so that is what must be reported, got \(undo)")
            return
        }
        #expect(text(at: downloads.appendingPathComponent("scan.pdf")) == "MINE",
                "and the file genuinely is back")
        #expect(coordinator.undoWithdrawn.contains(summary.recordID),
                "Undo is withdrawn — pressing it again could only accuse the user")
        #expect(coordinator.historyProblem != nil, "and the stale record is admitted")
    }

    // MARK: - X8: a move that changed nothing is not undoable

    @Test("X8: a collision rung landing on the file's own name writes no undoable row")
    func aMoveThatChangedNothingOffersNoUndo() async throws {
        // The ladder can land on the file's own name: the file is already
        // `report 2.pdf`, `report.pdf` is taken by something else, so rung 2 is
        // itself. The mover reports that honestly — but the intent row was
        // written before the ladder ran, so the row settles as `moved` and used
        // to offer an Undo that would "put back" a file that never left.
        let store = try store()
        let coordinator = coordinator(store: store)
        try makeDownload("report.pdf", "SOMETHING ELSE")
        let source = try makeDownload("report 2.pdf", "MINE")

        let outcome = await coordinator.accept(decision(
            source: source, chosen: "report.pdf", folderID: nil, folderName: nil
        ))

        switch outcome {
        case .unchanged:
            break   // resolved before a row was ever written — also correct
        case .moved(let summary):
            let row = try #require(try await store.record(id: summary.recordID))
            #expect(!row.isUndoable,
                    "nothing moved, so there is nothing to put back")
            #expect(!HistoryRowPresentation(record: row).showsUndo)
        case .failed(let failure):
            Issue.record("nothing should have failed here: \(failure)")
        }
        #expect(text(at: source) == "MINE", "the file is untouched")
        #expect(text(at: downloads.appendingPathComponent("report.pdf")) == "SOMETHING ELSE",
                "and the other file was never overwritten")
        await store.close()
    }

    // MARK: - D6: a filed file leaves the "recently detected" list

    @Test("D6: a successful move tells the watcher to drop the file from the dropdown")
    func aFiledFileIsForgotten() async throws {
        let store = try store()
        var forgotten: [UUID] = []
        let registry = FakeFolderRegistry()
        registry.destinations = [7: LiveDestination(url: invoices, displayName: "Invoices")]
        let coordinator = MoveCoordinator(
            store: store,
            resolver: MoveDestinationResolver(registry: registry, watchedDirectory: downloads),
            fileWasFiled: { forgotten.append($0) }
        )
        let source = try makeDownload("Scan.pdf", "PAYLOAD")
        let eventID = UUID()

        _ = await coordinator.accept(
            decision(source: source, chosen: "Statement.pdf", fileEventID: eventID)
        )

        #expect(forgotten == [eventID],
                "the row's name and URL are both stale now; its story continues in the history")
        await store.close()
    }
}
