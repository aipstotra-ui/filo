import Foundation
import Testing
@testable import FileOrganizer

/// The watcher diffs the folder by NAME, so a file the app itself creates —
/// a rename-in-place, or an undo restoring a file to Downloads — would
/// otherwise look like a brand-new download and get a suggestion made for it.
/// `AppCreatedFileClaims` is what prevents that, and these tests pin the two
/// things it must get right: never re-announce our own output, and never
/// swallow a real download.
@Suite("App-created file claims")
struct AppCreatedFileClaimsTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let lifetime: TimeInterval = 300

    /// The watched folder. Real path, but nothing is ever written here — the
    /// claim box only compares paths.
    private var downloads: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClaimTests-Downloads")
    }

    private func box() -> AppCreatedFileClaims {
        AppCreatedFileClaims(watching: downloads, lifetime: lifetime)
    }

    private func inDownloads(_ name: String) -> URL {
        downloads.appendingPathComponent(name)
    }

    // MARK: - Adopting our own output

    @Test("A claimed name that has appeared is adopted, and the claim is spent")
    func appearingClaimIsAdopted() {
        let claims = box()
        claims.claim(inDownloads("Invoice.pdf"), group: UUID(), now: now)

        let adopted = claims.consumeAppeared(presentNames: ["Invoice.pdf"], now: now)

        #expect(adopted == ["Invoice.pdf"], "the name becomes an ordinary known file")
        #expect(claims.count == 0, "a claim is spent once honoured — it must not linger")
    }

    @Test("A claim survives while the file has not appeared yet")
    func pendingClaimSurvives() {
        // The whole point: `knownNames.formIntersection(currentNames)` would drop
        // the name every scan, so the claim must outlive the file's absence.
        let claims = box()
        claims.claim(inDownloads("Invoice.pdf"), group: UUID(), now: now)

        let adopted = claims.consumeAppeared(presentNames: ["something-else.pdf"], now: now)

        #expect(adopted.isEmpty)
        #expect(claims.count == 1, "still waiting for the move to land")
    }

    @Test("A claim survives many scans while the move is slow")
    func claimSurvivesRepeatedScans() {
        let claims = box()
        claims.claim(inDownloads("Invoice.pdf"), group: UUID(), now: now)

        // A cross-volume move is a copy and can take minutes; simulate scans
        // every 10s for 4 minutes, still inside the 5-minute lifetime.
        for step in stride(from: 10.0, through: 240.0, by: 10.0) {
            _ = claims.consumeAppeared(presentNames: [], now: now.addingTimeInterval(step))
        }

        #expect(claims.count == 1, "a slow move must not lose its claim")
        let adopted = claims.consumeAppeared(
            presentNames: ["Invoice.pdf"], now: now.addingTimeInterval(250)
        )
        #expect(adopted == ["Invoice.pdf"], "and it is still honoured when the file lands")
    }

    @Test("An expired claim is still honoured if the file did arrive")
    func expiredButPresentClaimIsAdopted() {
        // Presence beats age: adopting late is right, because announcing the
        // app's own output as a new download is the bug being prevented.
        let claims = box()
        claims.claim(inDownloads("Invoice.pdf"), group: UUID(), now: now)

        let adopted = claims.consumeAppeared(
            presentNames: ["Invoice.pdf"], now: now.addingTimeInterval(lifetime * 10)
        )

        #expect(adopted == ["Invoice.pdf"])
        #expect(claims.count == 0)
    }

    @Test("Claiming a name does not adopt unrelated files present in the folder")
    func unrelatedFilesAreUntouched() {
        let claims = box()
        claims.claim(inDownloads("Invoice.pdf"), group: UUID(), now: now)

        let adopted = claims.consumeAppeared(presentNames: ["holiday-photo.jpg"], now: now)

        #expect(adopted.isEmpty, "a real new download must still be announced")
    }

    @Test("No claims is a no-op")
    func emptyClaimsIsANoOp() {
        let adopted = box().consumeAppeared(presentNames: ["a.pdf", "b.pdf"], now: now)

        #expect(adopted.isEmpty)
    }

    // MARK: - Not swallowing real downloads (M7)

    @Test("M7: an unused collision rung is released the moment the move settles")
    func unusedRungsAreReleasedWhenTheMoveSettles() {
        // This is the finding. The mover announces every rung of its ladder but
        // uses one. If the losers were left to age out, a genuine download named
        // "Invoice.pdf" arriving in the next five minutes would be adopted as
        // ours and NEVER announced — no popup, no menu row, ever.
        let claims = box()
        let group = UUID()
        claims.claim(inDownloads("Invoice.pdf"), group: group, now: now)
        claims.claim(inDownloads("Invoice 2.pdf"), group: group, now: now)
        claims.claim(inDownloads("Invoice 3.pdf"), group: group, now: now)

        // Rung 3 is the one that landed.
        claims.releaseUnused(group: group, keeping: inDownloads("Invoice 3.pdf"))

        #expect(claims.count == 1, "only the rung that actually landed is still claimed")

        // The user now downloads a real file called Invoice.pdf, seconds later.
        let adopted = claims.consumeAppeared(
            presentNames: ["Invoice.pdf", "Invoice 3.pdf"], now: now.addingTimeInterval(5)
        )

        #expect(adopted == ["Invoice 3.pdf"],
                "our own output is adopted; the user's real download must NOT be")
        #expect(claims.count == 0)
    }

    @Test("M7: a failed move releases every claim it made")
    func failedMoveReleasesEverything() {
        let claims = box()
        let group = UUID()
        claims.claim(inDownloads("Invoice.pdf"), group: group, now: now)
        claims.claim(inDownloads("Invoice 2.pdf"), group: group, now: now)

        // Nothing was created, so nothing may stay claimed.
        claims.releaseUnused(group: group, keeping: nil)

        #expect(claims.count == 0)
        let adopted = claims.consumeAppeared(presentNames: ["Invoice.pdf"], now: now)
        #expect(adopted.isEmpty, "a download arriving after a failed move is a real download")
    }

    @Test("Releasing one move's rungs leaves another move's claims alone")
    func releaseIsScopedToItsOwnGroup() {
        let claims = box()
        let mine = UUID()
        let theirs = UUID()
        claims.claim(inDownloads("A.pdf"), group: mine, now: now)
        claims.claim(inDownloads("B.pdf"), group: theirs, now: now)

        claims.releaseUnused(group: mine, keeping: nil)

        #expect(claims.count == 1)
        #expect(claims.consumeAppeared(presentNames: ["A.pdf", "B.pdf"], now: now) == ["B.pdf"],
                "the concurrent move's claim must survive")
    }

    @Test("A claim that is never settled still expires rather than leaking")
    func abandonedClaimExpires() {
        // Backstop for a crash between claiming and settling.
        let claims = box()
        claims.claim(inDownloads("Invoice 2.pdf"), group: UUID(), now: now)

        _ = claims.consumeAppeared(presentNames: [], now: now.addingTimeInterval(lifetime + 1))

        #expect(claims.count == 0, "unused claims must not leak")
    }

    // MARK: - Directory scoping

    @Test("M7: names outside the watched folder are not claimed at all")
    func claimsAreScopedToTheWatchedFolder() {
        // The mover moves files into folders all over the disk. Only the watched
        // folder's names can ever be confused with a download; claiming anything
        // else is dead state that could shadow a real download by coincidence.
        let claims = box()
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaimTests-Invoices")

        claims.claim(elsewhere.appendingPathComponent("Invoice.pdf"), group: UUID(), now: now)

        #expect(claims.count == 0, "a move into Invoices is not the watcher's business")
        #expect(claims.consumeAppeared(presentNames: ["Invoice.pdf"], now: now).isEmpty,
                "and a Downloads file of that name is still a real download")
    }

    @Test("A file in a SUBfolder of the watched folder is not claimed")
    func subfolderNamesAreNotClaimed() {
        // The watcher is non-recursive, so it never sees these — claiming them
        // would be state that is never consumed.
        let claims = box()
        claims.claim(
            downloads.appendingPathComponent("sub").appendingPathComponent("Invoice.pdf"),
            group: UUID(), now: now
        )

        #expect(claims.count == 0)
    }

    // MARK: - Concurrency

    @Test("Claims survive concurrent writers without corrupting")
    func concurrentClaimsAreSafe() async {
        // The real shape of the race the lock exists for: the mover claims from
        // a detached task while the watcher consumes on the main queue. Under
        // Swift 5 language mode the compiler diagnoses none of this, so it is
        // pinned here instead. (Run under the thread sanitizer to see the
        // unlocked version fail; unsanitized it usually just corrupts silently.)
        let claims = box()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    claims.claim(
                        self.inDownloads("file-\(index).pdf"), group: UUID(), now: self.now
                    )
                }
                group.addTask {
                    _ = claims.consumeAppeared(presentNames: ["file-\(index).pdf"], now: self.now)
                }
            }
        }
        // The assertion that matters is that we got here at all, with a
        // consistent count, rather than crashing on a dictionary mid-resize.
        #expect(claims.count <= 200)
    }

    // MARK: - F9: one move settling must not retire another move's live claim

    @Test("F9: two moves claiming the same name — the first keeps it when the second settles")
    func oneMoveSettlingDoesNotRetireAnothersClaim() {
        // Two concurrent accepts are ordinary, not exotic: a move outlives its
        // panel (founder decision 5), so the user can accept a second file while
        // the first is still moving, and the AI can suggest the same name twice.
        //
        // Claims used to be keyed by name alone, last writer wins. So B's claim
        // overwrote A's ownership, and when B settled, `releaseUnused(group: B)`
        // deleted the entry A's real file depends on — after which the watcher
        // announced the file this app had just written as a brand-new download,
        // and made a suggestion for it (risk #8).
        let claims = box()
        let moveA = UUID()
        let moveB = UUID()
        let contested = inDownloads("report.pdf")

        claims.claim(contested, group: moveA, now: now)
        claims.claim(contested, group: moveB, now: now)

        // B finishes first and used a different name entirely.
        claims.releaseUnused(group: moveB, keeping: inDownloads("report 2.pdf"))

        #expect(
            claims.consumeAppeared(presentNames: ["report.pdf"], now: now) == ["report.pdf"],
            "A is still relying on this name — B settling must not have taken it away"
        )
    }

    @Test("F9: once the LAST interested move lets go, the name really is released")
    func theNameIsFreedWhenEveryClaimantHasSettled() {
        // The other half: holding names forever would be its own bug — a stale
        // claim silently adopts a genuine download that happens to share the
        // name, and it is never announced at all.
        let claims = box()
        let moveA = UUID()
        let moveB = UUID()
        let contested = inDownloads("report.pdf")

        claims.claim(contested, group: moveA, now: now)
        claims.claim(contested, group: moveB, now: now)
        claims.releaseUnused(group: moveB, keeping: nil)
        claims.releaseUnused(group: moveA, keeping: nil)

        #expect(claims.count == 0)
        #expect(
            claims.consumeAppeared(presentNames: ["report.pdf"], now: now).isEmpty,
            "a real download of that name is now announced normally"
        )
    }
}
