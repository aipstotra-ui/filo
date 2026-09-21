import Foundation
import Testing
@testable import FileOrganizer

// MARK: - Test doubles

/// Stands in for `FolderRegistry`: whatever the folder index says RIGHT NOW,
/// which is deliberately not what the popup captured when it was shown.
@MainActor
private final class FakeRegistry: DestinationResolving {
    var destinations: [Int64: LiveDestination] = [:]
    /// The folders the app is allowed to write into. Separate from
    /// `destinations` on purpose, so a test can make the two DISAGREE — that
    /// divergence is exactly what the write-bounds gate exists to catch.
    var registeredURLs: [URL]?
    private(set) var lookups: [Int64] = []

    func liveDestination(forStoreID storeID: Int64) -> LiveDestination? {
        lookups.append(storeID)
        return destinations[storeID]
    }

    func registeredFolderURLs() -> [URL] {
        registeredURLs ?? destinations.values.map(\.url)
    }
}

/// A filesystem that exists only in this test: every "missing", "not a
/// directory", and "not writable" case is reachable without chmod games, a
/// second user account, or a real TCC denial.
private struct FakeProbe: FileProbing {
    var kinds: [String: FileKind] = [:]
    var writableDirectories: Set<String> = []

    func kind(at url: URL) -> FileKind? { kinds[url.path] }

    func isWritableDirectory(at url: URL) -> Bool {
        kinds[url.path] == .directory && writableDirectories.contains(url.path)
    }
}

// MARK: - Suite

/// The move-time re-validation pass. Everything the popup knew may have gone
/// stale between the popup appearing and Accept being pressed: the file can
/// have moved, and the destination folder can have been removed, renamed,
/// deleted — or replaced by a *different* folder that inherited its row id
/// when the index was rebuilt (SQLite AUTOINCREMENT resets; risk #4).
@MainActor
@Suite("MoveDestinationResolver")
struct MoveDestinationResolverTests {

    private let downloads = URL(fileURLWithPath: "/Users/tester/Downloads")
    private let invoices = URL(fileURLWithPath: "/Users/tester/Documents/Invoices")
    private let taxes = URL(fileURLWithPath: "/Users/tester/Documents/Taxes")

    private var source: URL { downloads.appendingPathComponent("Scan 2026-07-20 14.33.pdf") }

    private func decision(
        folderID: Int64? = 7,
        folderName: String? = "Invoices",
        chosen: String = "Chase Statement June 2026.pdf"
    ) -> AcceptedSuggestion {
        AcceptedSuggestion(
            fileEventID: UUID(),
            sourceURL: source,
            originalName: "Scan 2026-07-20 14.33.pdf",
            chosenFilename: chosen,
            destinationFolderID: folderID,
            destinationFolderName: folderName
        )
    }

    /// A probe where the source is a healthy regular file and `folder` is a
    /// healthy writable directory.
    private func healthyProbe(folder: URL? = nil) -> FakeProbe {
        var probe = FakeProbe()
        probe.kinds[source.path] = .regularFile
        probe.kinds[downloads.path] = .directory
        probe.writableDirectories.insert(downloads.path)
        if let folder {
            probe.kinds[folder.path] = .directory
            probe.writableDirectories.insert(folder.path)
        }
        return probe
    }

    private func registry(_ entries: [Int64: LiveDestination]) -> FakeRegistry {
        let registry = FakeRegistry()
        registry.destinations = entries
        return registry
    }

    /// A resolver whose watched folder is `downloads` — where every test's
    /// source file lives.
    private func resolver(
        registry: FakeRegistry, probe: FakeProbe, watching: URL? = nil
    ) -> MoveDestinationResolver {
        MoveDestinationResolver(
            registry: registry, watchedDirectory: watching ?? downloads, probe: probe
        )
    }

    private func failure(
        _ sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> ResolvedDestination
    ) -> MoveError? {
        do {
            let resolved = try body()
            Issue.record(
                "expected a typed MoveError; resolved to \(resolved.directory.path)",
                sourceLocation: sourceLocation
            )
            return nil
        } catch let error as MoveError {
            return error
        } catch {
            Issue.record("expected a MoveError, got \(error)", sourceLocation: sourceLocation)
            return nil
        }
    }

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

    @Test("A healthy folder resolves to its LIVE path, not to anything the popup remembered")
    func healthyFolderResolvesLive() throws {
        // The folder was renamed since it was indexed; the registry follows its
        // bookmark. The resolver must use what it is told now.
        let renamed = URL(fileURLWithPath: "/Users/tester/Documents/Invoices 2026")
        let registry = registry([7: LiveDestination(url: renamed, displayName: "Invoices")])
        let resolver = resolver(registry: registry, probe: healthyProbe(folder: renamed))

        let resolved = try resolver.resolve(decision())

        #expect(resolved.directory.path == renamed.path)
        #expect(resolved.sourceURL.path == source.path)
        #expect(resolved.preferredName == "Chase Statement June 2026.pdf")
        #expect(resolved.destinationFolderName == "Invoices")
        #expect(resolved.fallbackReason == nil)
        #expect(resolved.isRenameInPlace == false)
        #expect(registry.lookups == [7], "the folder id is re-resolved at move time")
    }

    @Test("No destination folder is a rename in place — and NOT a fallback")
    func noFolderIsAnOrdinaryRenameInPlace() throws {
        let resolver = resolver(registry: registry([:]), probe: healthyProbe())

        let resolved = try resolver.resolve(decision(folderID: nil, folderName: nil))

        #expect(resolved.directory.path == downloads.path)
        #expect(resolved.preferredName == "Chase Statement June 2026.pdf")
        #expect(resolved.destinationFolderName == nil)
        // Calling this a fallback would make the app apologise for doing
        // exactly what the user asked for.
        #expect(resolved.fallbackReason == nil, "leaving it in Downloads is not a failure")
        #expect(resolved.isRenameInPlace)
    }

    // MARK: - 2. Stale source — hard failure, never a fallback

    @Test("A source that is gone fails hard: no fallback, no move invented")
    func missingSourceIsAHardFailure() {
        var probe = FakeProbe()
        probe.kinds[downloads.path] = .directory
        probe.writableDirectories.insert(downloads.path)
        probe.kinds[invoices.path] = .directory
        probe.writableDirectories.insert(invoices.path)
        let resolver = resolver(
            registry: registry([7: LiveDestination(url: invoices, displayName: "Invoices")]),
            probe: probe
        )

        let error = failure { try resolver.resolve(decision()) }

        #expect(name(of: error) == "sourceMissing")
    }

    @Test("A source that is now a directory is refused")
    func directorySourceIsRefused() {
        var probe = healthyProbe(folder: invoices)
        probe.kinds[source.path] = .directory
        let resolver = resolver(
            registry: registry([7: LiveDestination(url: invoices, displayName: "Invoices")]),
            probe: probe
        )

        let error = failure { try resolver.resolve(decision()) }

        #expect(name(of: error) == "sourceNotAFile")
    }

    // MARK: - 3. Stale folder id — fall back, and say why

    @Test("A folder id that no longer resolves falls back to renaming in place")
    func unregisteredFolderFallsBack() throws {
        let resolver = resolver(registry: registry([:]), probe: healthyProbe())

        let resolved = try resolver.resolve(decision())

        #expect(resolved.fallbackReason == .folderNotRegistered)
        #expect(resolved.directory.path == downloads.path, "renamed where it is")
        #expect(resolved.destinationFolderName == nil)
        #expect(resolved.preferredName == "Chase Statement June 2026.pdf")
    }

    @Test("A row id that now points at a DIFFERENT folder never gets the file")
    func rebuiltIndexIdentityMismatchFallsBack() throws {
        // The index was rebuilt: AUTOINCREMENT restarted and id 7 is now the
        // Taxes folder. The popup said "Invoices". Moving the file into Taxes
        // would put it somewhere the user never chose (risk #4).
        let registry = registry([7: LiveDestination(url: taxes, displayName: "Taxes")])
        let resolver = resolver(registry: registry, probe: healthyProbe(folder: taxes))

        let resolved = try resolver.resolve(decision(folderID: 7, folderName: "Invoices"))

        #expect(resolved.fallbackReason == .folderIdentityChanged)
        #expect(resolved.directory.path != taxes.path, "the file must NOT go into Taxes")
        #expect(resolved.directory.path == downloads.path)
        #expect(resolved.destinationFolderName == nil)
    }

    @Test("A destination id with no display name to cross-check is not trusted")
    func unverifiableIdentityFallsBack() throws {
        let registry = registry([7: LiveDestination(url: invoices, displayName: "Invoices")])
        let resolver = resolver(registry: registry, probe: healthyProbe(folder: invoices))

        let resolved = try resolver.resolve(decision(folderID: 7, folderName: nil))

        #expect(resolved.fallbackReason == .folderIdentityChanged)
        #expect(resolved.directory.path == downloads.path)
    }

    @Test("A folder that is gone from disk falls back with the honest reason")
    func missingFolderFallsBack() throws {
        // Registered, name matches — but nothing is at that path any more.
        let registry = registry([7: LiveDestination(url: invoices, displayName: "Invoices")])
        let resolver = resolver(registry: registry, probe: healthyProbe())

        let resolved = try resolver.resolve(decision())

        #expect(resolved.fallbackReason == .folderMissing)
        #expect(resolved.directory.path == downloads.path)
    }

    @Test("A folder path that is now a FILE falls back rather than moving into it")
    func folderReplacedByAFileFallsBack() throws {
        var probe = healthyProbe()
        probe.kinds[invoices.path] = .regularFile
        let registry = registry([7: LiveDestination(url: invoices, displayName: "Invoices")])
        let resolver = resolver(registry: registry, probe: probe)

        let resolved = try resolver.resolve(decision())

        #expect(resolved.fallbackReason == .folderNotADirectory)
        #expect(resolved.directory.path == downloads.path)
    }

    @Test("A BLOCKED folder fails honestly — it does NOT quietly rename in place")
    func blockedFolderFailsRatherThanFallingBack() {
        // Founder decision 2026-07-28 (M24): "gone" and "blocked" are different
        // things. A folder that is gone falls back; a folder we cannot write
        // into fails, because a file silently left in Downloads after the user
        // chose Invoices is indistinguishable from the app not working.
        var probe = healthyProbe()
        probe.kinds[invoices.path] = .directory      // present, but not writable
        let registry = registry([7: LiveDestination(url: invoices, displayName: "Invoices")])
        let resolver = resolver(registry: registry, probe: probe)

        let error = failure { try resolver.resolve(decision()) }

        #expect(name(of: error) == "destinationNotWritable")
        #expect(error?.message.isEmpty == false)
    }

    @Test("Every fallback reason carries a non-empty explanation")
    func everyFallbackReasonExplainsItself() {
        for reason in MoveFallbackReason.allCases {
            #expect(!reason.explanation.isEmpty, "\(reason) has nothing to tell the user")
        }
    }

    // MARK: - 4. Source checks come first

    @Test("A missing source fails even when the destination folder is ALSO broken")
    func sourceCheckWinsOverFolderFallback() {
        // Order matters: falling back to "rename in place" for a file that is
        // not there would write a history row for a move that cannot happen.
        let probe = FakeProbe()   // nothing exists at all
        let resolver = resolver(registry: registry([:]), probe: probe)

        let error = failure { try resolver.resolve(decision()) }

        #expect(name(of: error) == "sourceMissing")
    }

    // MARK: - 5. Write bounds (M14)

    @Test("A source outside the watched folder is refused, not renamed where it sits")
    func sourceOutsideTheWatchedFolderIsRefused() {
        // A rename in place writes into whatever folder the source is in, so a
        // source from somewhere else would turn a stale popup into a write
        // outside the one folder this app promises to touch.
        let resolver = resolver(
            registry: registry([:]),
            probe: healthyProbe(),
            watching: URL(fileURLWithPath: "/Users/tester/SomewhereElse")
        )

        let error = failure { try resolver.resolve(decision(folderID: nil, folderName: nil)) }

        #expect(name(of: error) == "sourceOutsideWatchedFolder")
    }

    @Test("A neighbour folder whose name merely starts the same is NOT inside the watched one")
    func boundsCompareOnComponentBoundaries() {
        // "/Users/tester/Downloads-old" must not read as inside
        // "/Users/tester/Downloads".
        let lookalike = URL(fileURLWithPath: "/Users/tester/Downloads-old")
        let resolver = resolver(
            registry: registry([:]), probe: healthyProbe(), watching: lookalike
        )

        #expect(resolver.allowsWriting(into: lookalike))
        #expect(resolver.allowsWriting(into: downloads) == false,
                "a shared prefix is not containment")
        #expect(resolver.allowsWriting(into: lookalike.appendingPathComponent("Sub")),
                "a real subfolder IS inside")
    }

    @Test("A destination the registry does not vouch for is refused")
    func destinationOutsideAllowedFoldersIsRefused() {
        // The lookup and the allow-list disagree: id 7 resolves to Taxes, but
        // Taxes is not one of the folders the user registered. Vacuous against
        // the real registry — and the gate that catches the day it stops being.
        let registry = registry([7: LiveDestination(url: taxes, displayName: "Invoices")])
        registry.registeredURLs = [invoices]
        let resolver = resolver(registry: registry, probe: healthyProbe(folder: taxes))

        let error = failure { try resolver.resolve(decision()) }

        #expect(name(of: error) == "destinationOutsideAllowedFolders")
    }

    @Test("The watched folder and every registered folder are writable; nothing else is")
    func allowedRootsAreTheWatchedAndRegisteredFolders() {
        let registry = registry([7: LiveDestination(url: invoices, displayName: "Invoices")])
        let resolver = resolver(registry: registry, probe: healthyProbe(folder: invoices))

        #expect(resolver.allowsWriting(into: downloads))
        #expect(resolver.allowsWriting(into: invoices))
        #expect(resolver.allowsWriting(into: invoices.appendingPathComponent("2026")))
        #expect(resolver.allowsWriting(into: taxes) == false)
        #expect(resolver.allowsWriting(into: URL(fileURLWithPath: "/tmp")) == false)
        #expect(resolver.allowsWriting(into: URL(fileURLWithPath: "/")) == false)
    }
}
