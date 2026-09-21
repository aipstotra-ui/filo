import Foundation

/// Module boundary between Extraction's output and the AI engine:
/// a bounded snippet goes in, a sanitized suggestion (or an honest
/// unavailable-reason) comes out. Main-actor-bound so the compiler, not a
/// comment, enforces the "called on the main queue" contract.
@MainActor
protocol AIProviding {
    /// Produces a suggestion for the given extracted content.
    /// The completion is called exactly once, on the main actor, unless the
    /// engine is deallocated mid-flight (app teardown). Every failure surfaces
    /// as `.unavailable(reason)`, never as silence.
    func suggest(for content: ExtractedContent, completion: @escaping (AIResult) -> Void)
}

/// What the AI module hands onward for one file.
enum AIResult: Sendable {
    case suggestion(AISuggestion)
    case unavailable(AIUnavailableReason)
}

/// A completed suggestion. `suggestedFilename` has ALREADY been through
/// `FilenameSanitizer` (with the real file's extension re-applied) — it never
/// leaves the AI module raw. Summaries and embeddings stay in memory and are
/// never logged (docs/process/engineering-rules.md).
struct AISuggestion: Sendable {
    let summary: String
    let suggestedFilename: String
    /// Sentence embedding of the extraction snippet, for folder matching (M4).
    /// nil when the snippet's language has no embedding model.
    let embedding: [Float]?
}

/// Why no suggestion was produced. Typed, so the UI and engine stay in sync
/// through the compiler — mirrors Extraction's `FallbackReason`.
enum AIUnavailableReason: Sendable {
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady
    case timedOut
    case generationFailed
    /// The pipeline's backstop fired: the AI never answered for this file
    /// (still queued behind others, or the engine broke its
    /// completion-exactly-once contract). Distinct from `.timedOut`, which is
    /// the engine's own verdict on a single hung generation.
    case aiBusy

    /// Short honest line for the menu UI.
    var label: String {
        switch self {
        case .appleIntelligenceOff:
            return "Turn on Apple Intelligence for suggestions"
        case .deviceNotEligible:
            return "This Mac can't run Apple Intelligence"
        case .modelNotReady:
            return "Apple Intelligence is still getting ready — no suggestion yet"
        case .timedOut:
            return "AI took too long — using name & type"
        case .generationFailed:
            return "AI couldn't suggest a name — using name & type"
        case .aiBusy:
            return "AI is busy — using name & type"
        }
    }
}
