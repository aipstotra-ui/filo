import Foundation

/// A self-contained snapshot of one file's settled suggestion, built at the
/// moment it is enqueued for the popup. The popup renders ONLY from this
/// snapshot — never from live `PipelineModel.fileStates` after it is shown —
/// so a later prune or re-suggestion can't corrupt a popup already on screen.
/// Value type, `Sendable`.
struct PopupSuggestion: Identifiable, Sendable, Equatable {
    /// Same identity as the originating `FileEvent`. Also the popup's identity
    /// and the enqueue-once dedup key.
    let fileEventID: UUID
    /// Where the file is right now (the watched Downloads copy). Carried so M6
    /// can move it; M5 only reads its extension while validating an edited name.
    let sourceURL: URL
    /// The file's current on-disk name, shown dimmed as "what it is now".
    let originalName: String
    /// The AI's suggested filename — already sanitized by the AI module and
    /// carrying the real file extension. This is the edit field's starting text.
    let suggestedFilename: String
    /// The suggested destination: a matched folder, an honest "no folder fits",
    /// or nothing to show at all.
    let destination: PopupDestination

    var id: UUID { fileEventID }

    /// The real file's extension, re-applied by `FilenameSanitizer` when the
    /// user's edited name is validated at the Accept boundary.
    var fileExtension: String { sourceURL.pathExtension }
}

/// The destination shown in the popup. A dedicated enum (rather than reusing
/// `PipelineModel.DestinationState`) makes illegal popup states unrepresentable:
/// a popup never shows for a still-matching (`.pending`) file, and a matched
/// folder always carries its store identity.
enum PopupDestination: Sendable, Equatable {
    /// A confident folder match: shown as "→ [folder icon] {name}".
    case folder(name: String, id: Int64)
    /// Folders exist but none clears the bar — the canonical honest line
    /// "No folder fits — leaving it in Downloads".
    case noFolderFits
    /// No destination line at all (this is the spec's "none" case): the AI had
    /// a name but matching produced no verdict — no folders configured, the
    /// match backstop fired, or the matched folder vanished. Mirrors the menu's
    /// silent `DestinationState.quiet`, so the two views stay consistent.
    case quiet

    /// The store identity to hand M6, or nil when there is no destination folder.
    var folderID: Int64? {
        if case .folder(_, let id) = self { return id }
        return nil
    }

    /// The display name of the destination folder, or nil when there is none.
    var folderName: String? {
        if case .folder(let name, _) = self { return name }
        return nil
    }
}
