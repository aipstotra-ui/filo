import Foundation
import Testing
@testable import FileOrganizer

/// Pure tests for popup placement geometry and the VoiceOver arrival strings —
/// no window, no screen, no VoiceOver required.
@Suite("Popup placement & announcement")
struct PopupPlacementTests {

    // MARK: - Placement geometry

    @Test("Placed at the top-right of the visible frame, inset by the margin")
    func placesTopRight() {
        // A 1440×900 screen whose visible frame starts at y=0, top at 900.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = PopupPositioner.topRightFrame(
            in: visible, size: CGSize(width: 312, height: 140), margin: 14
        )
        #expect(frame.maxX == visible.maxX - 14, "right edge sits one margin from the right")
        #expect(frame.maxY == visible.maxY - 14, "top edge sits one margin below the top")
        #expect(frame.width == 312)
        #expect(frame.height == 140)
    }

    @Test("Respects a non-zero visible-frame origin (menu bar / Dock insets)")
    func respectsVisibleFrameOrigin() {
        // Visible frame inset by a 25 pt menu bar (top) and a 70 pt Dock (bottom).
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 900 - 25 - 70)
        let frame = PopupPositioner.topRightFrame(
            in: visible, size: CGSize(width: 312, height: 140), margin: 14
        )
        #expect(frame.maxY == visible.maxY - 14)
        #expect(frame.minY >= visible.minY, "never dips below the Dock inset")
        #expect(frame.minX >= visible.minX)
    }

    @Test("A popup taller/wider than the screen is clamped fully inside")
    func clampsOversized() {
        let visible = CGRect(x: 0, y: 0, width: 200, height: 120)
        let frame = PopupPositioner.topRightFrame(
            in: visible, size: CGSize(width: 312, height: 140), margin: 14
        )
        #expect(frame.minX == visible.minX, "clamped to the left edge when wider than the screen")
        #expect(frame.minY == visible.minY, "clamped to the bottom edge when taller than the screen")
    }

    // MARK: - VoiceOver arrival announcement

    @Test("A matched-folder announcement names the file and the destination")
    @MainActor
    func announcesMatch() {
        let suggestion = PopupSuggestion(
            fileEventID: UUID(),
            sourceURL: URL(fileURLWithPath: "/x/Downloads/Scan.pdf"),
            originalName: "Scan.pdf",
            suggestedFilename: "Chase Statement.pdf",
            destination: .folder(name: "Invoices", id: 3)
        )
        #expect(SuggestionPanelController.announcement(for: suggestion)
                == "Suggestion ready. Suggested name Chase Statement.pdf, destination Invoices.")
    }

    @Test("A no-folder announcement reuses the canonical honest string verbatim")
    @MainActor
    func announcesNoFolder() {
        let suggestion = PopupSuggestion(
            fileEventID: UUID(),
            sourceURL: URL(fileURLWithPath: "/x/Downloads/IMG.heic"),
            originalName: "IMG.heic",
            suggestedFilename: "Whiteboard notes.heic",
            destination: .noFolderFits
        )
        let text = SuggestionPanelController.announcement(for: suggestion)
        #expect(text == "Suggestion ready. Suggested name Whiteboard notes.heic. No folder fits — leaving it in Downloads.")
        #expect(text.contains("No folder fits — leaving it in Downloads"),
                "the visible and spoken no-match copy must match exactly")
    }

    @Test("A quiet-destination announcement names only the file")
    @MainActor
    func announcesQuiet() {
        let suggestion = PopupSuggestion(
            fileEventID: UUID(),
            sourceURL: URL(fileURLWithPath: "/x/Downloads/a.zip"),
            originalName: "a.zip",
            suggestedFilename: "Project archive.zip",
            destination: .quiet
        )
        #expect(SuggestionPanelController.announcement(for: suggestion)
                == "Suggestion ready. Suggested name Project archive.zip.")
    }
}
