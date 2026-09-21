import SwiftUI
import AppKit

/// The Settings window: General + Folders + History (docs/mockups/
/// m4-folders-settings.html and m6-history-undo.html, both founder-approved).
/// Copy comes verbatim from docs/product/design-system.md's canonical strings table.
///
/// History sits third, per the mockup: General first is the macOS convention,
/// Folders is the thing you set up once, and History is the thing you visit
/// when something surprised you.
struct SettingsView: View {
    @ObservedObject var watcher: DownloadsWatcher
    @ObservedObject var registry: FolderRegistry
    /// nil when the history database could not be opened, in which case the
    /// History tab explains that rather than showing a misleading empty list.
    var coordinator: MoveCoordinator?
    /// Why it could not be opened, when it could not — so the pane's advice can
    /// be true rather than generic (F12).
    var openFailure: MoveHistoryStore.StoreError?

    var body: some View {
        TabView {
            GeneralPane(watcher: watcher)
                .tabItem { Label("General", systemImage: "gearshape") }
            FoldersPane(registry: registry)
                .tabItem { Label("Folders", systemImage: "folder.fill") }
            Group {
                if let coordinator {
                    HistoryPane(coordinator: coordinator)
                } else {
                    HistoryUnavailablePane(failure: openFailure)
                }
            }
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620)
    }
}

/// Shown when `history.db` could not be opened at all. The app is then not
/// moving anything (founder decision 1: a move it cannot record is a move it
/// does not make), and saying so beats an empty list that reads as "you have
/// never moved anything".
private struct HistoryUnavailablePane: View {
    let failure: MoveHistoryStore.StoreError?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)
            Text("History isn't available")
                .fontWeight(.semibold)
            Text("The app couldn't open its history file, so it isn't moving any files "
                 + "this session — it won't move a file it can't record and put back. "
                 + "Suggestions still appear as usual. " + Self.advice(for: failure))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    /// What to actually do about it. "Restarting usually fixes this" is true of
    /// a locked or unreadable file and flatly false of a history written by a
    /// newer version of the app — restarting that one will fail identically
    /// every time (F12).
    static func advice(for failure: MoveHistoryStore.StoreError?) -> String {
        switch failure {
        case .unsupportedSchemaVersion:
            "This history was written by a newer version of the app, so this "
            + "version can't read it. Updating the app will fix it; restarting won't."
        case .cannotOpen, .queryFailed, .recordNotFound, .invalidRetentionLimit, .none:
            "Restarting the app usually fixes this."
        }
    }
}

/// Minimal for M4: the watcher's own status line, nothing invented.
private struct GeneralPane: View {
    @ObservedObject var watcher: DownloadsWatcher

    var body: some View {
        Text(watcher.statusMessage)
            .foregroundStyle(.secondary)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The fixed privacy sentence (design-system: shown in full wherever folder
/// data is collected, never buried).
private struct PrivacyBox: View {
    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(Color.accentColor)
            Text("To learn what a folder holds, the app reads its file names and briefly looks inside a few files. Nothing leaves your Mac.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FoldersPane: View {
    @ObservedObject var registry: FolderRegistry
    @State private var rejection: FolderAddRejection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if registry.folders.isEmpty {
                emptyState
            } else {
                populatedState
            }
        }
        .padding(20)
        .alert(
            "Folder not added",
            isPresented: Binding(
                get: { rejection != nil },
                set: { if !$0 { rejection = nil } }
            ),
            presenting: rejection
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { rejection in
            switch rejection {
            case .duplicate:
                Text("That folder is already in the list.")
            case .isDownloads:
                Text("Downloads is the folder being watched — choose a different folder as a destination.")
            }
        }
    }

    private var populatedState: some View {
        Group {
            Text("The app can suggest one of these folders as a destination for a new download. It only ever suggests — nothing is moved.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PrivacyBox()
            VStack(spacing: 0) {
                ForEach(registry.folders) { folder in
                    FolderRow(folder: folder, registry: registry)
                    if folder.id != registry.folders.last?.id {
                        Divider()
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            HStack {
                Button("Add Folder…") { presentAddPanel() }
                Spacer()
                Text(folderCountLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            FolderIcon()
                .frame(width: 46, height: 38)
            Text("No target folders yet")
                .fontWeight(.semibold)
            Text("Choose the folders where your files usually end up — like Invoices or Receipts. When a new download fits one, its suggestion will include that folder as a destination. Nothing is moved.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            PrivacyBox()
                .frame(maxWidth: 420)
            Button("Add Folder…") { presentAddPanel() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var folderCountLabel: String {
        registry.folders.count == 1 ? "1 folder" : "\(registry.folders.count) folders"
    }

    /// The standard macOS folder picker. Directories only; picking a folder
    /// is itself the user's read grant — the app asks for nothing broader.
    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rejection = registry.addFolder(at: url)
    }
}

private struct FolderRow: View {
    let folder: RegisteredFolder
    let registry: FolderRegistry
    @State private var showingAccessHelp = false

    var body: some View {
        HStack(spacing: 11) {
            FolderIcon()
                .frame(width: 26, height: 21)
                .grayscale(folder.status == .missing ? 1 : 0)
                .opacity(folder.status == .missing ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(folder.displayName)
                        .lineLimit(1)
                    Text(folder.displayPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                statusLine
            }
            Spacer(minLength: 8)
            Button {
                registry.rescan(folderID: folder.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .frame(width: 24, height: 24)
            .help("Rescan")
            Button {
                registry.remove(folderID: folder.id)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .frame(width: 24, height: 24)
            .help("Remove")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch folder.status {
        case .indexed:
            Text("Indexed · \(folder.totalFileCount) files, \(folder.contentReadCount) read")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .scanning:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Scanning…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .cantAccess:
            Button {
                showingAccessHelp = true
            } label: {
                Text("Can't access — click to learn why")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .underline()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingAccessHelp, arrowEdge: .bottom) {
                AccessHelpView()
            }
        case .missing:
            Text("Folder missing")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// Plain-language explanation with a Grant Access step (mockup annotation:
/// "opens a short plain-language explanation with a Grant Access step").
private struct AccessHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS is not letting the app read this folder.")
                .fontWeight(.semibold)
            Text("To grant access: open System Settings → Privacy & Security → Files & Folders, and allow AI File Organizer. Then click Rescan on this folder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 320)
    }
}
