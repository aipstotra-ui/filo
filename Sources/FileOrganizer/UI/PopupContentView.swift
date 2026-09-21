import SwiftUI
import AppKit

/// The popup's content, rendered from a self-contained `PopupSuggestion`
/// snapshot: the current name (dimmed), an editable suggested-name field, the
/// destination line, and Dismiss / Accept. Semantic system colors and native
/// controls only (spec §6.7), so Increase Contrast, Reduce Transparency, and
/// the user's accent color all respond automatically. Text wraps; nothing is
/// clipped to a fixed height.
/// The live state of the popup on screen, owned by `SuggestionPanelController`
/// and mutated by `PopupController` through `PanelPresenting.update(activity:)`.
///
/// A reference type so the panel can be re-rendered in place: recreating the
/// view to show "Moving…" would throw away whatever the user had typed.
@MainActor
final class PopupViewState: ObservableObject {
    @Published var activity: PopupActivity = .editing
}

struct PopupContentView: View {
    let suggestion: PopupSuggestion
    @ObservedObject var state: PopupViewState
    let onAccept: (String) -> Void
    let onDismiss: () -> Void
    let onHoverChanged: (Bool) -> Void

    /// The live text of the edit field. Starts as the AI's suggested name.
    @State private var editedName: String
    @FocusState private var fieldFocused: Bool
    /// Reduce Motion replaces the indeterminate spinner with a still caption:
    /// an animation that never stops is exactly what the setting exists to
    /// remove, and "Moving…" already carries the whole meaning (A8).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        suggestion: PopupSuggestion,
        state: PopupViewState,
        onAccept: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.suggestion = suggestion
        self.state = state
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        self.onHoverChanged = onHoverChanged
        _editedName = State(initialValue: suggestion.suggestedFilename)
    }

    /// True while a move is running for this popup. Accept is unavailable (a
    /// second press would start a second move) and Dismiss becomes "Hide".
    private var isMoving: Bool { state.activity == .moving }

    /// The honest failure text, or nil when the last attempt did not fail.
    private var failureMessage: String? {
        if case .failed(let message, _) = state.activity { return message }
        return nil
    }

    /// True for the one failure the user can fix from here: macOS privacy (TCC)
    /// refusing the destination folder (founder decision 7).
    private var offersPrivacySettings: Bool {
        if case .failed(_, let offers) = state.activity { return offers }
        return false
    }

    /// True once the move has settled and this popup is only being read. The
    /// name field stops taking input here: the file has already left the path
    /// this popup names, so a Return in the field would be a move against a
    /// stale path (F13). The controller refuses it too — this is the half the
    /// user can see.
    private var isSettled: Bool { completionNotice != nil }

    /// Set when the move succeeded but not exactly as asked. The file has
    /// already moved, so there is nothing left to accept.
    private var completionNotice: String? {
        if case .completed(let notice) = state.activity { return notice }
        return nil
    }

    /// The edited name run through the SAME guard the AI module applies to its
    /// own output (path separators, control/bidi chars, traversal stripped;
    /// real extension re-applied). nil means nothing usable remains — Accept
    /// is then disabled and the popup shows the empty-name hint.
    private var sanitizedName: String? {
        FilenameSanitizer.sanitize(editedName, originalExtension: suggestion.fileExtension)
    }
    private var canAccept: Bool { sanitizedName != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            nameField
            destinationLine
            if !canAccept {
                // An inline error, so it takes error-text on the sentence and
                // no icon — same anatomy as a failed move (design-system).
                Text("Name can't be empty")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            failureLine
            completionLine
            footer
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 312, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))   // opaque window material
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { onHoverChanged($0) }
        .onChange(of: canAccept) { _, nowValid in
            // VoiceOver does not auto-read a line that just appeared, so speak
            // the empty-name error when Accept becomes unavailable.
            if !nowValid { announce("Name can't be empty") }
        }
        .onChange(of: state.activity) { _, now in
            // Same reason, and it matters more here: the failure line appears
            // without any keystroke from the user, so nothing else would speak
            // it. A move outcome nobody can perceive is the bug M6 exists to fix.
            switch now {
            case .moving:
                announce("Moving the file…")
            case .failed(let message, _):
                announce("Move failed. \(message)")
            case .completed(let notice):
                announce("Moved, with a change. \(notice)")
            case .editing:
                break
            }
        }
    }

    // MARK: - Pieces

    /// App name plus the file's current name, combined into one static element
    /// for VoiceOver (a11y must-fix #8).
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI File Organizer")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(suggestion.originalName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI File Organizer suggestion. Original name, \(suggestion.originalName).")
    }

    /// The editable suggested name. A native rounded-border field; the pencil is
    /// a decorative editability hint only (non-interactive, hidden from VoiceOver
    /// — the bordered field already conveys "editable"). ui-designer confirms at
    /// step 7 whether to keep or drop it.
    private var nameField: some View {
        TextField("Suggested name", text: $editedName)
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .lineLimit(1)
            .focused($fieldFocused)
            .onSubmit {
                // Return in the field accepts the current text (never inserts a
                // newline — this is a single-line field). Refused once the move
                // has settled: the file has already moved, so this would start a
                // second move against a path it no longer occupies (F13). The
                // controller refuses it too; both halves are deliberate, because
                // this one is the half the user can see.
                if canAccept, !isSettled { onAccept(editedName) }
            }
            .disabled(isSettled || isMoving)
            .overlay(alignment: .trailing) {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 7)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    // The affordance fades with the field it describes, so a
                    // busy or settled popup does not still invite an edit.
                    .opacity(isSettled || isMoving ? 0 : 1)
            }
            .accessibilityLabel("Suggested name")
            .accessibilityValue(editedName)
            .accessibilityHint(isSettled
                ? "The file has already moved. This name can no longer be changed."
                : "Editable. Accept confirms this name.")
    }

    /// The destination: a matched folder, the honest no-match line, or nothing.
    @ViewBuilder
    private var destinationLine: some View {
        switch suggestion.destination {
        case .folder(let name, _):
            HStack(spacing: 5) {
                Text("→")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                FolderIcon()
                    .frame(width: 13, height: 11)
                    .accessibilityHidden(true)
                Text(name)
                    .foregroundStyle(.primary)
            }
            .font(.caption)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Destination folder, \(name).")
        case .noFolderFits:
            // Canonical string — reused verbatim in the VoiceOver announcement.
            Text("No folder fits — leaving it in Downloads")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .quiet:
            EmptyView()
        }
    }

    /// Dismiss (quiet) and Accept (prominent) — Accept is the single clear action.
    private var footer: some View {
        HStack(spacing: 8) {
            if isMoving {
                if !reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                // `.primary`: this line reports what is happening to a file, and
                // `.secondary` measures ~3.9:1 at caption size (design-system).
                Text("Moving…")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            Spacer()
            if completionNotice != nil {
                // The file has already moved. Offering Accept here would invite
                // a second move of a file that is no longer where the popup
                // says it is, so the only control left is acknowledgement.
                Button("OK") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)        // Return
                    .accessibilityLabel("Close")
                    .accessibilityHint("The file has already moved. This just closes the popup.")
            } else {
                // Founder decision 5: Dismiss stays ENABLED during a move and
                // means *hide*. The move continues and its result lands in the
                // history — it is never a cancel. Esc must always be answered.
                Button {
                    onDismiss()
                } label: {
                    Text(isMoving ? "Hide" : "Dismiss").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)             // Esc
                .accessibilityLabel(isMoving ? "Hide popup" : "Dismiss suggestion")
                .accessibilityHint(isMoving
                    ? "Hides this popup. The move carries on and its result appears in your history."
                    : "Closes without changing the file.")

                Button(failureMessage == nil ? "Accept" : "Try again") {
                    onAccept(editedName)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)            // Return
                .disabled(!canAccept || isMoving)
                .accessibilityLabel(
                    failureMessage == nil ? "Accept suggestion" : "Try the move again"
                )
                .accessibilityHint(acceptHint)
            }
        }
        .padding(.top, 6)
    }

    private var acceptHint: String {
        if isMoving { return "A move is already running for this file." }
        if !canAccept { return "Enter a name to accept" }
        if failureMessage != nil { return "Tries the move again with the name above." }
        return "Moves the file using the name above."
    }

    /// The honest failure line. The popup deliberately STAYS OPEN showing this
    /// and re-enables Accept: an error the user never read is exactly the silent
    /// failure this milestone exists to kill.
    ///
    /// Design-system inline-error anatomy: red on the sentence, and nothing
    /// else. No banner, no fill, no icon, no warning triangle — the amber
    /// triangle it used to draw made a *failure* look like the *caution* state
    /// two lines below it (D2).
    @ViewBuilder
    private var failureLine: some View {
        if let failureMessage {
            VStack(alignment: .leading, spacing: 4) {
                noticeLine(
                    failureMessage,
                    tint: Color(nsColor: .systemRed),
                    spokenAs: "Move failed. \(failureMessage)"
                )
                if offersPrivacySettings {
                    // Founder decision 7: a TCC block is the one failure the user
                    // can actually fix, so it gets the one action that fixes it.
                    // Link style = the underlined "actionable words" the design
                    // system asks for on a line that opens something.
                    Button("Open System Settings") { Self.openPrivacySettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityHint(
                            "Opens Privacy & Security › Files and Folders, "
                            + "where you can allow this app to write into that folder."
                        )
                }
            }
        }
    }

    /// The move worked, but not as asked — the name was taken, or the folder
    /// wasn't available. Amber, not red: the file is fine, it just isn't where
    /// or what the user expected, and that is the whole point of saying it.
    @ViewBuilder
    private var completionLine: some View {
        if let completionNotice {
            noticeLine(
                completionNotice,
                tint: Color(nsColor: .systemOrange),
                spokenAs: "Moved, with a change. \(completionNotice)"
            )
        }
    }

    private func noticeLine(
        _ message: String, tint: Color, spokenAs spoken: String
    ) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)   // wraps, never clipped
            .accessibilityLabel(spoken)
    }

    /// Opens the pane that grants this app access to the blocked folder.
    ///
    /// A local URL scheme handled by System Settings on this Mac — no network
    /// call, and nothing is sent anywhere. Built with `URL(string:)` rather than
    /// force-unwrapped: a failure here must do nothing, never crash the app the
    /// user is in the middle of trusting with their files.
    private static func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security"
                + "?Privacy_FilesAndFolders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - VoiceOver

    /// Posts a high-priority announcement. This fires while the panel is key
    /// (the user is editing), where VoiceOver reliably listens.
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
