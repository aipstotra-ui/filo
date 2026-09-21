import Foundation
import Testing
@testable import FileOrganizer

/// The sentences a failed move puts in front of the user — in the popup and,
/// weeks later, in Settings › History.
///
/// Pinned rather than eyeballed for the same reason the History row strings are:
/// the words ARE the product here. Two rules, both from the design system:
/// **never surface an error code or a POSIX name**, and **name the folder the
/// user actually chose** rather than saying "that folder".
@Suite("Move failure messages")
struct MoveErrorMessageTests {

    /// Every case, so a new one has to make a deliberate choice about its words.
    private static let allErrors: [MoveError] = [
        .sourceMissing(path: "/Users/someone/Downloads/scan.pdf"),
        .sourceNotAFile(path: "/Users/someone/Downloads/adir"),
        .invalidName(name: "../../etc/passwd"),
        .sourceOutsideWatchedFolder(path: "/private/tmp/x.pdf"),
        .destinationDirectoryMissing(path: "/Users/someone/Invoices"),
        .destinationNotWritable(path: "/Users/someone/Invoices", detail: "Permission denied"),
        .destinationBlockedByPrivacy(path: "/Users/someone/Documents"),
        .destinationOutsideAllowedFolders(path: "/etc"),
        .destinationNameUnavailable(directory: "/Users/someone/Invoices", attempted: 50),
        .nameTooLong(name: String(repeating: "a", count: 300)),
        .crossVolumeCopyFailed(detail: "No space left on device", incompleteCopyRemained: true),
        .moveFailed(code: 28, detail: "No space left on device"),
    ]

    // MARK: - D4: no error codes, no POSIX names, no raw paths

    @Test("What the history stores never contains an errno or a POSIX name",
          arguments: MoveErrorMessageTests.allErrors)
    func historyDetailIsPlainLanguage(error: MoveError) {
        // "(errno 28: No space left on device)" is what a user used to find in
        // their History pane. The typed payload still exists — it just stays in
        // dev logs, where a path and a code belong.
        let stored = error.historyDetail(namingFolder: "Invoices")

        #expect(!stored.contains("errno"))
        #expect(!stored.lowercased().contains("permission denied"),
                "a strerror string is a POSIX name, not a sentence for a person")
        #expect(!stored.contains("/Users/"), "no absolute paths on screen")
        #expect(!stored.contains("/private/"))
        #expect(!stored.contains("/etc"))
        #expect(stored.hasSuffix("."), "it is a sentence")
    }

    @Test("The leftover partial file from a failed cross-volume copy is still reported")
    func aLeftoverPartialCopyIsAlwaysMentioned() {
        // C1/M13: this is the one specific the user must act on — a stray
        // incomplete file sitting in the destination folder. It used to travel
        // inside the free-text `detail`, which is exactly what D4 removed, so it
        // needed a home of its own.
        let leftBehind = MoveError.crossVolumeCopyFailed(
            detail: "whatever", incompleteCopyRemained: true
        )
        #expect(leftBehind.historyDetail(namingFolder: "Invoices").contains("incomplete copy"))

        let tidy = MoveError.crossVolumeCopyFailed(
            detail: "whatever", incompleteCopyRemained: false
        )
        #expect(!tidy.historyDetail(namingFolder: "Invoices").contains("incomplete copy"),
                "and a copy that WAS cleaned up must not claim a leftover")
    }

    @Test("A privacy block always tells the user where to turn it on")
    func privacyBlockCarriesItsFix() {
        let stored = MoveError.destinationBlockedByPrivacy(path: "/Users/someone/Documents")
            .historyDetail(namingFolder: "Documents")

        #expect(stored.contains("System Settings"))
        #expect(stored.contains("Documents"))
    }

    // MARK: - D5: name the folder

    @Test("Every folder-related failure names the folder instead of saying 'that folder'",
          arguments: [
            MoveError.destinationDirectoryMissing(path: "/x"),
            .destinationNotWritable(path: "/x", detail: "d"),
            .destinationBlockedByPrivacy(path: "/x"),
            .destinationOutsideAllowedFolders(path: "/x"),
            .destinationNameUnavailable(directory: "/x", attempted: 50),
          ])
    func folderFailuresNameTheFolder(error: MoveError) {
        let named = error.message(namingFolder: "Tax & Accounting 2026")

        #expect(named.contains("Tax & Accounting 2026"))
        #expect(!named.contains("that folder"),
                "the popup knows the name — the user picked it seconds ago")
    }

    @Test("With no folder to name, the sentence still reads properly",
          arguments: MoveErrorMessageTests.allErrors)
    func genericWordingStillReads(error: MoveError) {
        // A rename in place has no folder, so the generic wording has to stand
        // on its own rather than leaving a hole mid-sentence.
        let generic = error.message
        #expect(!generic.isEmpty)
        #expect(!generic.contains("nil"))
        #expect(!generic.contains("()"))
        #expect(generic.hasSuffix("."))
    }

    // MARK: - Founder decision 7: which failure gets the button

    @Test("Only a privacy block offers 'Open System Settings'",
          arguments: MoveErrorMessageTests.allErrors)
    func onlyPrivacyBlocksOfferTheButton(error: MoveError) {
        let expected = if case .destinationBlockedByPrivacy = error { true } else { false }
        #expect(error.isBlockedByPrivacy == expected)
        #expect(MoveFailure.moveFailed(error).isBlockedByPrivacy == expected,
                "and the flag survives the wrap the popup actually receives")
    }

    @Test("A history failure is never offered the privacy button")
    func historyFailureOffersNoButton() {
        #expect(!MoveFailure.historyUnavailable(detail: "x").isBlockedByPrivacy)
        #expect(!MoveFailure.alreadyInFlight.isBlockedByPrivacy)
    }
}
