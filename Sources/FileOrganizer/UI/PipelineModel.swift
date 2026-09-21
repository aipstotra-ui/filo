import Foundation
import Combine

/// Owns the pipeline: watcher announces a file → extraction reads it → the AI
/// suggests a better name → the UI observes each file's progress here.
/// Main-actor-bound, so all state changes on the main thread by construction;
/// callbacks arriving from main-queue components re-enter via
/// `MainActor.assumeIsolated` (they are already on the main thread — this
/// just proves it to the compiler, and traps loudly if that ever changes).
@MainActor
final class PipelineModel: ObservableObject {
    /// One file's journey through the pipeline.
    enum FileState {
        case extracting
        /// Extraction finished; the AI has not been started yet (transient —
        /// `beginThinking` follows in the same call).
        case done(ExtractedContent)
        /// The AI is working on a suggestion.
        case thinking(ExtractedContent)
        /// The AI answered: either a suggestion or an honest reason it couldn't.
        /// The destination attaches asynchronously after the suggestion shows.
        case suggested(ExtractedContent, AIResult, DestinationState)
    }

    /// The folder-matching verdict for one suggested file (M4). Founder
    /// decision: matching runs ONLY after a successful AI suggestion — when
    /// the AI is unavailable the destination stays `.quiet` and the menu
    /// shows nothing extra.
    enum DestinationState: Equatable {
        /// Matching is in flight; the row shows no destination line yet.
        case pending
        /// No destination line at all (AI unavailable, no indexed folders,
        /// matching timed out, or the matched folder vanished mid-flight).
        case quiet
        /// "→ [folder icon] {name}". Carries the folder's store identity too
        /// (not just its name) so the M5 popup can hand the right folder to
        /// M6's mover even when two folders share a leaf name.
        case match(folderName: String, folderID: Int64)
        /// Folders exist but none clears the threshold:
        /// "No folder fits — leaving it in Downloads"
        case noMatch
    }

    /// A hung extraction (huge or malformed file) must not leave rows on
    /// "Reading…" forever — after this long the file falls back to name & type.
    private static let extractionTimeout: TimeInterval = 60

    /// Backstop only: AIEngine has its own 60 s inference timeout (plus one
    /// retry), so under normal load this never fires. It CAN fire legitimately
    /// when a burst of files queues behind the serial AI chain — each file
    /// waits its turn, and a file deep in the queue may still be unstarted at
    /// 150 s. That's why it reports `.aiBusy`, not `.timedOut`: the AI didn't
    /// fail, it just never got to this file. No row may stick on "Thinking…".
    private static let aiBackstopTimeout: TimeInterval = 150

    /// Folder matching is embedding math over in-memory vectors — normally
    /// instant. The backstop mirrors the embedding budget: if no verdict
    /// landed after this long, the row stays quiet and a late result is
    /// dropped. No row may stick on a pending destination forever.
    private static let matchTimeout: TimeInterval = 10

    let watcher: DownloadsWatcher
    let registry: FolderRegistry
    private let extractor: any ContentExtracting
    private let ai: any AIProviding
    private let embedder: any EmbeddingProviding

    /// Per-file progress, keyed by `FileEvent.id`.
    @Published private(set) var fileStates: [UUID: FileState] = [:]

    init(
        watcher: DownloadsWatcher = DownloadsWatcher(),
        extractor: any ContentExtracting = ExtractionEngine(),
        ai: any AIProviding = AIEngine(),
        embedder: any EmbeddingProviding = SentenceEmbeddingProvider(),
        registry: FolderRegistry? = nil
    ) {
        self.watcher = watcher
        self.extractor = extractor
        self.ai = ai
        self.embedder = embedder
        self.registry = registry ?? Self.makeDefaultRegistry()
        watcher.onNewFile = { [weak self] event in
            // DownloadsWatcher delivers on the main queue (M1 design).
            MainActor.assumeIsolated {
                self?.beginExtraction(for: event)
            }
        }
    }

    /// Opens the on-disk folder index; if that fails the registry still works
    /// for the session (in memory), never fatal to a menu-bar app. The error
    /// (which can carry the DB path) is logged in dev builds only — the
    /// user-facing "running in memory / index rebuilt" surfacing is a known
    /// deferred gap (see docs/product/milestones.md M4 known issues).
    private static func makeDefaultRegistry() -> FolderRegistry {
        let store: FolderIndexStore?
        do {
            store = try FolderIndexStore(databaseURL: FolderRegistry.defaultDatabaseURL())
        } catch {
            store = nil
            #if DEBUG
            print("PipelineModel: folder index unavailable, running in memory: "
                + LogSanitizer.sanitized(String(describing: error)))
            #endif
        }
        return FolderRegistry(store: store)
    }

    private func beginExtraction(for event: FileEvent) {
        pruneStates()
        fileStates[event.id] = .extracting
        scheduleExtractionTimeout(for: event)
        extractor.extract(from: event) { [weak self] content in
            // ExtractionEngine calls back on the main queue.
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // Only land the result if the file is still waiting on one — drops
                // late results after a timeout and results for pruned files alike.
                guard case .extracting = self.fileStates[event.id] else { return }
                self.fileStates[event.id] = .done(content)
                self.beginThinking(about: content)
            }
        }
    }

    private func scheduleExtractionTimeout(for event: FileEvent) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.extractionTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard case .extracting = self.fileStates[event.id] else { return }
                let content = ExtractedContent(
                    event: event,
                    snippet: event.name,
                    method: .metadataOnly(.timedOut),
                    wordCount: 0
                )
                self.fileStates[event.id] = .done(content)
                self.beginThinking(about: content)
            }
        }
    }

    /// Every completed extraction goes to the AI — even a metadata-only
    /// snippet (name, type, size, date) is often enough to name a zip.
    private func beginThinking(about content: ExtractedContent) {
        let id = content.event.id
        fileStates[id] = .thinking(content)
        scheduleAIBackstop(for: content)
        ai.suggest(for: content) { [weak self] result in
            guard let self = self else { return }
            // Same guard-drop as extraction: late or pruned results vanish.
            guard case .thinking = self.fileStates[id] else { return }
            switch result {
            case .suggestion(let suggestion):
                // Publish the suggestion immediately; the destination line
                // attaches asynchronously once matching finishes.
                self.fileStates[id] = .suggested(content, result, .pending)
                self.beginMatching(for: content, suggestion: suggestion)
            case .unavailable:
                // Founder decision: no AI suggestion → no destination, ever.
                self.fileStates[id] = .suggested(content, result, .quiet)
            }
        }
    }

    private func scheduleAIBackstop(for content: ExtractedContent) {
        let id = content.event.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.aiBackstopTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard case .thinking = self.fileStates[id] else { return }
                self.fileStates[id] = .suggested(content, .unavailable(.aiBusy), .quiet)
            }
        }
    }

    // MARK: - Folder matching (M4)

    /// Builds the query vectors off-main and asks FolderMatcher for the best
    /// indexed folder. Query = the suggestion's snippet embedding plus fresh
    /// embeddings of the AI summary and of the original filename, all unit-
    /// normalized here (the matcher excludes non-unit vectors by design).
    private func beginMatching(for content: ExtractedContent, suggestion: AISuggestion) {
        let id = content.event.id
        let candidates = registry.matchCandidates
        guard !candidates.isEmpty else {
            // Zero indexed folders: the menu-level hint (or plain quiet)
            // covers this; the row itself shows no destination line.
            landDestination(.quiet, for: id)
            return
        }

        scheduleMatchBackstop(for: id)
        let embedder = self.embedder
        let snippetEmbedding = suggestion.embedding
        let queryTexts = [suggestion.summary, content.event.name]

        Task.detached(priority: .utility) { [weak self] in
            var query: [[Float]] = []
            if let raw = snippetEmbedding, let unit = FolderMatcher.unitNormalized(raw) {
                query.append(unit)
            }
            for text in queryTexts {
                if let raw = embedder.embedding(for: text),
                   let unit = FolderMatcher.unitNormalized(raw) {
                    query.append(unit)
                }
            }
            guard !query.isEmpty else {
                // Nothing about this file could be embedded, so no comparison
                // happened. That is "couldn't evaluate", not "evaluated and
                // nothing fit" — stay quiet rather than claim "No folder fits".
                await MainActor.run { [weak self] in
                    self?.landDestination(.quiet, for: id)
                }
                return
            }
            let verdict = FolderMatcher.bestMatch(query: query, candidates: candidates)
            await MainActor.run { [weak self] in
                self?.landVerdict(verdict, for: id)
            }
        }
    }

    private func landVerdict(_ verdict: MatchVerdict, for id: UUID) {
        let destination: DestinationState
        switch verdict {
        case .match(let folderID, _):
            if let name = registry.displayName(forStoreID: folderID) {
                destination = .match(folderName: name, folderID: folderID)
            } else {
                // Folder removed while matching ran — nothing to point at.
                destination = .quiet
            }
        case .noGoodMatch:
            destination = .noMatch
        case .noFoldersConfigured:
            destination = .quiet
        }
        landDestination(destination, for: id)
    }

    /// Attaches a destination only while the row is still waiting for one —
    /// late results (after the backstop) and pruned files are dropped.
    private func landDestination(_ destination: DestinationState, for id: UUID) {
        guard case .suggested(let content, let result, .pending) = fileStates[id] else { return }
        fileStates[id] = .suggested(content, result, destination)
    }

    private func scheduleMatchBackstop(for id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.matchTimeout) { [weak self] in
            MainActor.assumeIsolated {
                // No verdict in time: the row stays quiet rather than showing
                // a stale or fabricated destination; the late result is dropped.
                self?.landDestination(.quiet, for: id)
            }
        }
    }

    /// Drop state for files no longer shown, so the dictionary never grows unbounded.
    private func pruneStates() {
        let liveIDs = Set(watcher.recentEvents.map { $0.id })
        fileStates = fileStates.filter { liveIDs.contains($0.key) }
    }
}
