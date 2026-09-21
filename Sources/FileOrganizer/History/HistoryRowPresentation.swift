import Foundation

/// One history row turned into the three lines the Settings › History pane
/// draws, per the founder-approved mockup (`docs/mockups/m6-history-undo.html`
/// §1–2).
///
/// Pure and separate from the view because the *words* are the product here.
/// This milestone exists so the user is never misled about what happened to
/// their file, and "never misled" is a property of these sentences — so they are
/// unit-tested rather than eyeballed in a screenshot.
///
/// Every state fills the same three slots, so the reader's eye learns one shape:
/// 1. **`currentName`** — what the file is called *right now*. This is what you
///    would type into Spotlight, which is why it leads even though the popup
///    puts the old name first: by the time you are here, you know the file by
///    its new name.
/// 2. **`headline`** — what happened.
/// 3. **`detail`** — where it came from, or what to do next when it went wrong.
struct HistoryRowPresentation: Equatable {

    /// Colour carries no information on its own — every headline is a full
    /// sentence that survives the colour being removed (spec §7, and the
    /// mockup's "amber/red are always full sentences").
    enum Tone: Equatable {
        /// It worked.
        case normal
        /// The file is fine, but something did not go to plan.
        case caution
        /// It did not happen.
        case failure
    }

    let currentName: String
    /// Line 2. `headlineFolder` is the part the view sets in semibold; it is
    /// kept separate rather than marked up inside the string so the string
    /// stays a plain sentence for VoiceOver.
    let headline: String
    let headlineFolder: String?
    let detail: String?
    let tone: Tone
    /// Undo is shown ONLY where undoing is genuinely possible. A row that
    /// cannot be undone says so in words — never a greyed-out button, which
    /// invites the user to hunt for a way to enable it.
    let showsUndo: Bool

    /// - Parameters:
    ///   - record: the stored row.
    ///   - isLive: whether a move for this file is running **right now**, in
    ///     this app. Only the caller knows; the row cannot tell (F11).
    ///   - undoWithdrawn: whether this record's Undo has been withdrawn for the
    ///     session because an earlier undo moved the file but could not record
    ///     it (F8).
    init(record: MoveRecord, isLive: Bool = false, undoWithdrawn: Bool = false) {
        // What the file is called RIGHT NOW. For everything that happened,
        // that is the row's final name — but a move that FAILED never gave the
        // file that name, so leading with it sent the user to Downloads looking
        // for a file that is still under its old one, with line 3 telling them
        // it was there "under this name" (F3).
        switch record.state {
        case .failed, .unknown:
            currentName = record.originalName
        case .inProgress, .moved, .undone:
            currentName = record.finalName
        }

        switch record.state {
        case .inProgress where !isLive:
            // `inProgress` and NOT running: this row was stranded. Either the
            // app stopped between writing the row and settling it, or a
            // reconcile could not resolve it. Rendering it as "Moving…" showed a
            // spinner for work nobody is doing — and "Moving…" was in fact only
            // ever reachable in exactly these dead cases (F11).
            headline = "Interrupted — the app can't confirm this one"
            headlineFolder = nil
            detail = "Look in Downloads for \(record.originalName)"
                + (record.destinationFolderName.map { ", and in \($0)" } ?? "")
                + ". No Undo is offered, because the app can't confirm what happened."
            tone = .caution
            showsUndo = false

        case .inProgress:
            headline = "Moving…"
            headlineFolder = nil
            detail = record.destinationFolderName.map { "to \($0)" }
            tone = .normal
            showsUndo = false

        case .moved:
            // Order matters: a fallback is checked FIRST, because a requested
            // folder that turned out to be unusable is the headline even when
            // the rename that followed changed nothing.
            if let reason = record.fallbackReason {
                // Founder decision 2: the requested folder was unusable, so the
                // file was renamed where it is — and we say so rather than
                // letting the user believe it reached the folder they chose.
                headline = "Renamed in Downloads — "
                    + reason.explanation(namingFolder: record.destinationFolderName)
                headlineFolder = nil
                tone = .caution
                showsUndo = record.changedAnythingOnDisk && !undoWithdrawn
            } else if !record.changedAnythingOnDisk {
                // The mover's collision ladder landed on the file's own name, so
                // nothing actually happened on disk. An Undo here would offer to
                // "put back" a file that never left (X8).
                headline = "Nothing to change — it already had this name here"
                headlineFolder = nil
                tone = .normal
                showsUndo = false
            } else {
                headline = "Moved to"
                headlineFolder = record.destinationFolderName ?? "Downloads"
                // A `moved` row with a note is the cross-volume case where the
                // copy succeeded but the original could not be removed — the
                // user has a duplicate and must be told (C1/M13).
                tone = record.failureDetail == nil ? .normal : .caution
                showsUndo = !undoWithdrawn
            }
            detail = Self.joined(
                record.changedAnythingOnDisk ? "was \(record.originalName)" : nil,
                record.moveCaveat
            )

        case .undone:
            headline = "Undone — back in Downloads"
            headlineFolder = nil
            tone = .normal
            showsUndo = false
            if record.finalName == record.originalName {
                detail = record.destinationFolderName.map { "had been in \($0)" }
            } else {
                // Undo uses the same no-clobber mover as the forward move, so a
                // newer file holding the original name is never overwritten —
                // the restored file gets a deduped name instead. Saying so is
                // the difference between "the app renamed my file for no reason"
                // and "the app protected the other file".
                detail = "The name \(record.originalName) was already taken, so it came back "
                    + "as \(record.finalName). Nothing was overwritten."
            }

        case .failed:
            headline = record.failureDetail ?? "Couldn't move"
            headlineFolder = nil
            // `currentName` above is already the ORIGINAL name for this state,
            // so "this name" now points at a name the file really has.
            detail = "Still in Downloads under this name. Nothing was changed."
            tone = .failure
            showsUndo = false

        case .unknown:
            // The app stopped mid-move and cannot prove where the file went.
            // It offers no Undo and does not guess — it tells the user the two
            // places to look. Guessing here could move a file the app never
            // touched (C2).
            headline = "Result unknown — the app stopped mid-move"
            headlineFolder = nil
            detail = "Look in Downloads for \(record.originalName) and in "
                + "\(record.finalDirectory.lastPathComponent) for \(record.finalName). "
                + "No Undo is offered, because the app can't confirm what happened."
            tone = .caution
            showsUndo = false
        }
    }

    /// What VoiceOver reads for the whole row, as one sentence. Uses the FULL
    /// name — the view truncates the middle of a long name visually, but the
    /// app never stores or speaks a shortened one.
    /// - Parameter undoFailure: the message from an Undo on this row that did
    ///   not work. Part of the row's label, not only a line beside it: a
    ///   VoiceOver user who reads the row and never hears this concludes the
    ///   file went back when it did not (A4).
    func accessibilityLabel(timeSpokenAs time: String, undoFailure: String? = nil) -> String {
        var parts = [currentName, time]
        if let headlineFolder {
            parts.append("\(headline) \(headlineFolder)")
        } else {
            parts.append(headline)
        }
        if let detail { parts.append(detail) }
        if let undoFailure { parts.append(undoFailure) }
        return parts.joined(separator: ". ")
    }

    private static func joined(_ parts: String?...) -> String? {
        let kept = parts.compactMap { $0 }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }
}

private extension MoveRecord {
    /// The note stored on a row that nonetheless succeeded: a collision rename,
    /// or the cross-volume case where the copy is complete but the original
    /// could not be removed.
    ///
    /// It deliberately does NOT repeat the fallback clause. This row renders
    /// that itself, from its own `fallback_reason` column, so a note carrying it
    /// too printed the same sentence twice (X9) — which is why the coordinator
    /// stores `MoveSummary.historyNote` here rather than the popup's full
    /// `notice`.
    var moveCaveat: String? {
        guard state == .moved else { return nil }
        return failureDetail
    }
}
