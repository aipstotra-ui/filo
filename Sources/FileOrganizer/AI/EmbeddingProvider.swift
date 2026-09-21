import Foundation
import NaturalLanguage

/// Tiny boundary for turning text into a vector, so M4's folder matching can
/// be tested with a mock. Implementations must be safe to call off the main
/// thread (hence Sendable).
protocol EmbeddingProviding: Sendable {
    /// Returns a sentence embedding for the text, or nil when no embedding
    /// model covers the text's language. Purely on-device (NaturalLanguage
    /// framework) — no download, no network.
    func embedding(for text: String) -> [Float]?
}

/// NLEmbedding-backed implementation. Stateless: the OS caches the underlying
/// model assets, so loading per call keeps this thin without a memory cost we
/// have to manage ourselves.
struct SentenceEmbeddingProvider: EmbeddingProviding {
    func embedding(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let language = recognizer.dominantLanguage ?? .english

        // Fall back to the English model for unsupported languages — a rough
        // vector still beats none for folder matching.
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language)
            ?? NLEmbedding.sentenceEmbedding(for: .english) else {
            return nil
        }
        guard let vector = embedding.vector(for: trimmed) else { return nil }
        return vector.map(Float.init)
    }
}
