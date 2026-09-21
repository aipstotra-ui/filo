import SwiftUI

/// The menu-bar dropdown: recently detected files (with extraction + AI
/// status and, when folders are configured, a suggested destination),
/// watcher status, Choose folders…, and Quit. Never shows snippet content or
/// summaries — only method, counts, the sanitized suggested name, and a
/// folder name the user chose themselves.
struct MenuContentView: View {
    @ObservedObject var watcher: DownloadsWatcher
    @ObservedObject var pipeline: PipelineModel
    @ObservedObject var registry: FolderRegistry
    /// Lets a row with a settled suggestion reopen that file's popup. Optional
    /// so the menu still renders in a preview or a test with no controller.
    var popups: PopupController?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(watcher.statusMessage)

        Divider()

        if watcher.recentEvents.isEmpty {
            Text("No new files yet — drop one into Downloads")
        } else {
            ForEach(watcher.recentEvents) { event in
                row(for: event)
                // The row's information lines are plain Text, which NSMenu
                // renders as *disabled* items — unclickable, and skipped by
                // keyboard navigation and VoiceOver. So the action is its own
                // one-line Button, which is an ENABLED menu item and therefore
                // reachable by everyone. It reopens that file's popup, which is
                // how a file that scrolled past the popup queue can still be
                // acted on (M5 hand-off #3).
                //
                // Deliberately NOT achieved by wrapping the whole multi-line row
                // in a Button: a menu item's label is a single line, so the
                // detail lines would be squashed or dropped.
                if let popups, popups.needsMenuRoute(fileEventID: event.id) {
                    Button("Review \(suggestedName(for: event) ?? event.name)…") {
                        popups.reopen(fileEventID: event.id)
                    }
                }
            }
        }

        if showZeroFoldersHint {
            Text("No target folders yet — destinations appear once you choose folders")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Choose folders…") {
            // Accessory app: activate so the Settings window comes to front.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Button("Quit AI File Organizer") {
            NSApp.terminate(nil)
        }
    }

    /// One file's lines. Identical whether the row is a button or inert, so a
    /// file does not visibly change shape the moment its suggestion settles.
    private func row(for event: FileEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(event.name)  ·  \(event.formattedSize)")
            Text(extractionLine(for: event))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let aiLine = aiLine(for: event) {
                Text(aiLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            destinationLine(for: event)
        }
    }

    /// The quiet hint (mockup variant B): only when no folders are set up AND
    /// at least one visible file actually has a suggestion the hint applies to.
    private var showZeroFoldersHint: Bool {
        guard registry.folders.isEmpty else { return false }
        return watcher.recentEvents.contains { event in
            if case .suggested(_, .suggestion, _) = pipeline.fileStates[event.id] {
                return true
            }
            return false
        }
    }

    /// Second line: what the app could (and couldn't) read out of the file.
    private func extractionLine(for event: FileEvent) -> String {
        switch pipeline.fileStates[event.id] {
        case .none:
            // No state registered for this file (shouldn't normally happen).
            return "—"
        case .extracting:
            return "Reading…"
        case .done(let content), .thinking(let content), .suggested(let content, _, _):
            // Exhaustive on purpose: a new extraction method must make a
            // deliberate choice about how it appears here.
            switch content.method {
            case .pdfText, .ocr, .pdfPageOCR, .plainText:
                return "\(content.method.label) · \(content.wordCount) words"
            case .metadataOnly(let reason):
                switch reason {
                case .unsupportedType:
                    return "Using name & type"
                default:
                    return "\(reason.label) — using name & type"
                }
            }
        }
    }

    /// Third line: the AI's progress and verdict. nil before the AI starts.
    private func aiLine(for event: FileEvent) -> String? {
        switch pipeline.fileStates[event.id] {
        case .none, .extracting, .done:
            return nil
        case .thinking:
            return "Thinking…"
        case .suggested(_, let result, _):
            switch result {
            case .suggestion(let suggestion):
                // Already sanitized inside the AI module — safe to display.
                return "Suggested: \(suggestion.suggestedFilename)"
            case .unavailable(let reason):
                // One honest line per reason; the labels live on the enum so
                // the switch there stays exhaustive.
                return reason.label
            }
        }
    }

    /// Fourth line (M4): the destination, or the honest no-match. Nothing at
    /// all while matching runs, when the AI had no suggestion, or when no
    /// folders are indexed — the app never pretends to have an answer.
    @ViewBuilder
    private func destinationLine(for event: FileEvent) -> some View {
        if case .suggested(_, _, let destination) = pipeline.fileStates[event.id] {
            switch destination {
            case .match(let folderName, _):
                // ONE Text, not an HStack. In `.menu` style NSMenu turns each
                // view into its own menu item, so an HStack of arrow + icon +
                // name came out as three separate lines with the folder name
                // stranded below an empty arrow. Concatenated `Text` (including
                // the symbol, via `Text(Image:)`) stays a single item.
                //
                // The popup (M5) uses the folder ID; the menu shows the name only.
                (
                    Text("→  ").foregroundStyle(.secondary)
                    + Text(Image(systemName: "folder.fill")).foregroundStyle(FolderIcon.tint)
                    + Text("  \(folderName)")
                )
                .font(.caption)
                .accessibilityLabel("Destination: \(folderName)")
            case .noMatch:
                Text("No folder fits — leaving it in Downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .pending, .quiet:
                EmptyView()
            }
        }
    }

    /// The AI's suggested name for this file, when it has one.
    private func suggestedName(for event: FileEvent) -> String? {
        guard case .suggested(_, .suggestion(let suggestion), _) = pipeline.fileStates[event.id]
        else { return nil }
        return suggestion.suggestedFilename
    }
}

/// The blue folder glyph shared by the menu destination line and the
/// Settings rows (design-system: folder gradient #74B9FF → #3E8EF0).
struct FolderIcon: View {
    /// Top and bottom of the folder gradient.
    static let gradientTop = Color(red: 0x74 / 255, green: 0xB9 / 255, blue: 0xFF / 255)
    static let gradientBottom = Color(red: 0x3E / 255, green: 0x8E / 255, blue: 0xF0 / 255)

    /// The gradient collapsed to one solid blue, for places that can only take a
    /// flat colour — a folder symbol inlined into concatenated `Text`, which is
    /// how the menu draws its destination line (a `.menu`-style `MenuBarExtra`
    /// splits any real `HStack` across separate menu items). Midway between the
    /// two stops, so it reads as the same blue at caption size.
    static let tint = Color(red: 0x59 / 255, green: 0xA3 / 255, blue: 0xF7 / 255)

    var body: some View {
        Image(systemName: "folder.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(
                .linearGradient(
                    colors: [Self.gradientTop, Self.gradientBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}
