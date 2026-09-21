import SwiftUI
import AppKit

/// Settings › History — the app's record of everything it has done to the
/// user's files, and the only place an Undo lives.
///
/// Founder decision 6 (2026-07-28) put history here rather than in the menu-bar
/// dropdown. That is not only a taste call: in `.menu` style a plain `Text` row
/// becomes a *disabled* `NSMenuItem`, which NSMenu keyboard navigation skips and
/// VoiceOver cannot read — so the failed and `unknown` rows, the ones that
/// matter most, would have been unreachable for those users. A real window has
/// no such constraint.
struct HistoryPane: View {
    @ObservedObject var coordinator: MoveCoordinator

    @State private var confirmingClear = false
    /// True once a Clear has emptied the list this session, so the empty state
    /// can say "History cleared" rather than the "Nothing moved yet" that reads
    /// as if the app had never done anything.
    @State private var didJustClear = false
    /// Per-row message from an Undo that did not work, keyed by record id. Undo
    /// failures are shown ON the row rather than in an alert: the row is the
    /// thing the message is about.
    @State private var undoFailures: [Int64: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move history")
                .font(.headline)
            Text("Every file you have accepted. Undo puts a file back in Downloads under the name it had before.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = coordinator.historyProblem {
                ProblemBanner(message: problem)
            }
            if let movedAside = coordinator.historyRecoveredFromCorruption {
                ProblemBanner(
                    message: "Your previous history file was damaged and could not be read. "
                        + "It has been kept at \(movedAside.lastPathComponent) and a new one "
                        + "started. Moves made before now can't be undone."
                )
            }

            if coordinator.recent.isEmpty {
                emptyState
            }
            if !coordinator.recent.isEmpty {
                list
            }
            // The footer is OUTSIDE the emptiness test on purpose. Removing it
            // when the list empties destroyed keyboard focus at the exact moment
            // it was sitting on the Clear History button that had just run —
            // focus jumped to nowhere and VoiceOver went quiet (A3). It now
            // stays put and simply disables.
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Clear move history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clearHistory() }
            // SwiftUI on macOS does NOT make a `.cancel` button the default,
            // so without this Return fired the destructive button and wiped up
            // to 200 undo records (A2). The safe choice is what Return does.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Your files stay exactly where they are. What goes is the record of "
                 + "the moves, so none of them can be undone afterwards. "
                 + "This can't be undone itself.")
        }
    }

    // MARK: - Pieces

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Identified by the FIRST RECORD's id, not by the title. An undo
                // rewrites `settled_at` to now, which can move a record into a
                // day section that already exists further up — `grouped` merges
                // only adjacent runs, so two sections could both be called
                // "Today" and SwiftUI would see duplicate ids (X2).
                ForEach(HistoryDay.grouped(coordinator.recent)) { day in
                    Text(day.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .padding(.horizontal, 12)
                        .background(.quaternary.opacity(0.4))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.records) { record in
                        HistoryRow(
                            record: record,
                            isLive: coordinator.inFlight.contains(record.fileEventID),
                            undoWithdrawn: coordinator.undoWithdrawn.contains(record.id),
                            isUndoing: coordinator.undoInFlight.contains(record.id),
                            undoFailure: undoFailures[record.id],
                            onUndo: { undo(record) }
                        )
                        if record.id != day.records.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(minHeight: 220, maxHeight: 380)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Button("Clear History…") { confirmingClear = true }
                .disabled(coordinator.recent.isEmpty)
                .accessibilityHint("Erases the record of every move, so none of them can be undone.")
            Spacer()
            Text(storedCountLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var storedCountLabel: String {
        switch coordinator.recent.count {
        case 0: "Nothing stored"
        case 1: "1 move stored"
        case let count: "\(count) moves stored"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(didJustClear ? "History cleared" : "Nothing moved yet")
                .fontWeight(.semibold)
            Text(didJustClear
                 ? "Your files are untouched. Moves you make from now on are recorded here."
                 : "When you accept a suggestion, the move is recorded here so you can put it back.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        // The list going empty is a real event with no other announcement, so
        // it becomes the element VoiceOver reads (A3).
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func undo(_ record: MoveRecord) {
        undoFailures[record.id] = nil
        Task {
            let outcome = await coordinator.undo(recordID: record.id)
            // Both outcomes are announced. Undo used to say nothing either way,
            // so a VoiceOver user pressed the button, heard silence, and had to
            // conclude the file went back — including when it had not (A4).
            switch outcome {
            case .restored(let restoredURL, let wasRenamedForCollision):
                announce(wasRenamedForCollision
                    ? "Put back as \(restoredURL.lastPathComponent), because "
                      + "\(record.originalName) was taken. Nothing was overwritten."
                    : "Put back in Downloads as \(restoredURL.lastPathComponent).")
            case .failed(let error):
                undoFailures[record.id] = error.message
                announce("Undo failed. \(error.message)")
            }
        }
    }

    private func clearHistory() {
        Task {
            let failure = await coordinator.clearHistory()
            undoFailures = [:]
            guard let failure else {
                didJustClear = true
                announce("History cleared. Your files are untouched.")
                return
            }
            // Reuses the same honest banner the store problems use, rather
            // than failing silently — a Clear that did nothing while the
            // user watched the list stay put is its own kind of lie.
            didJustClear = coordinator.recent.isEmpty
            coordinator.reportClearFailure(failure)
            announce(failure.message)
        }
    }

    /// Speaks one line to VoiceOver. Settings is a real, key window, which is
    /// where announcements are reliable — unlike the non-activating popup panel.
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

// MARK: - Row

private struct HistoryRow: View {
    let record: MoveRecord
    /// A move for this file is running right now, in this app. The row cannot
    /// tell on its own, and rendering "Moving…" without knowing showed a
    /// spinner for work nobody was doing (F11).
    let isLive: Bool
    let undoWithdrawn: Bool
    let isUndoing: Bool
    let undoFailure: String?
    let onUndo: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: HistoryRowPresentation {
        HistoryRowPresentation(record: record, isLive: isLive, undoWithdrawn: undoWithdrawn)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Truncated in the MIDDLE so the extension always survives.
                    // The full name is what `help` shows and what VoiceOver reads.
                    Text(presentation.currentName)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(presentation.currentName)
                    Spacer(minLength: 4)
                    Text(Self.clockTime.string(from: record.settledAt ?? record.acceptedAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)   // spoken in the row label instead
                }
                headline
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let undoFailure {
                    Text(undoFailure)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Only the button is clickable — the row itself is inert. Undo
            // cannot be redone in M6, so there is deliberately no large target
            // to hit by accident and no confirmation dialog to click through.
            if presentation.showsUndo {
                Button(action: onUndo) {
                    if isUndoing && !reduceMotion {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isUndoing ? "Undoing…" : "Undo")
                    }
                }
                .disabled(isUndoing)
                // Named, not "Undo this move". A VoiceOver user navigating the
                // list heard the same five words on every button in it and had
                // no way to tell which file each one belonged to (A7).
                .accessibilityLabel("Undo move of \(presentation.currentName)")
                .accessibilityHint("Puts \(presentation.currentName) back in Downloads as \(record.originalName).")
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            presentation.accessibilityLabel(
                timeSpokenAs: Self.spokenTime(for: record),
                undoFailure: undoFailure
            )
        )
    }

    @ViewBuilder
    private var headline: some View {
        let tint = Self.color(for: presentation.tone)
        if let folder = presentation.headlineFolder {
            HStack(spacing: 4) {
                Text(presentation.headline)
                Text(folder).fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(tint)
        } else {
            Text(presentation.headline)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Semantic system colours, so Increase Contrast and the user's appearance
    /// settings apply. Never the only carrier of meaning — each headline is a
    /// full sentence.
    private static func color(for tone: HistoryRowPresentation.Tone) -> Color {
        switch tone {
        // `.primary`, not `.secondary`: this line reports what happened to one
        // of the user's files, and `.secondary` measures ~3.9:1 at caption size
        // against a 4.5:1 bar (design-system, D8).
        case .normal: .primary
        case .caution: Color(nsColor: .systemOrange)
        case .failure: Color(nsColor: .systemRed)
        }
    }

    private static var clockTime: DateFormatter { HistoryDay.clockTime }

    /// VoiceOver gets the day back, since the visual row relies on the day
    /// header above it for that.
    private static func spokenTime(for record: MoveRecord) -> String {
        let date = record.settledAt ?? record.acceptedAt
        return HistoryDay.spokenDay(for: date) + " at " + clockTime.string(from: date)
    }
}

// MARK: - Day grouping

/// Records grouped under "Today" / "Yesterday" / a weekday and date, so the row
/// itself carries only the clock time.
struct HistoryDay: Equatable, Identifiable {
    let title: String
    let records: [MoveRecord]

    /// The first record's row id, NOT the title. An undo rewrites `settled_at`
    /// to now, which can produce a second section also called "Today" —
    /// `grouped` merges only adjacent runs — and two SwiftUI list items sharing
    /// an id is undefined behaviour (X2). Row ids are unique by construction.
    var id: Int64 { records.first?.id ?? 0 }

    /// Groups newest-first records into day sections, preserving order. Pure, so
    /// the boundary cases (midnight, a run spanning two days) are testable.
    @MainActor
    static func grouped(
        _ records: [MoveRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HistoryDay] {
        var days: [HistoryDay] = []
        for record in records {
            let date = record.settledAt ?? record.acceptedAt
            let title = self.title(for: date, now: now, calendar: calendar)
            if let last = days.last, last.title == title {
                days[days.count - 1] = HistoryDay(
                    title: title, records: last.records + [record]
                )
            } else {
                days.append(HistoryDay(title: title, records: [record]))
            }
        }
        return days
    }

    @MainActor
    static func title(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return dayAndDate.string(from: date)
    }

    @MainActor
    static func spokenDay(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let title = self.title(for: date, now: now, calendar: calendar)
        return title == "Today" || title == "Yesterday" ? title.lowercased() : "on " + title
    }

    /// `@MainActor` on both formatters, because `DateFormatter` is not
    /// `Sendable` and a `static let` of one is a shared mutable global the
    /// Swift 6 language mode rejects (X6). Both are only ever read while
    /// building the view, which is already main-actor work.
    @MainActor
    static let clockTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    @MainActor
    private static let dayAndDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return formatter
    }()
}

// MARK: - Problem banner

/// One honest line when the history database itself is misbehaving. Amber, not
/// red: the user's files are fine — it is the record of them that is not.
/// Amber on the sentence and nothing else — no icon, no tinted box. The design
/// system allows exactly one tinted container in the app (the privacy box), and
/// says amber and red appear only in status text, never as fills.
private struct ProblemBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
