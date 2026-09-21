import Foundation
import Testing
import FoundationModels
@testable import FileOrganizer

/// Live end-to-end smoke test for the real on-device model. Unlike the rest of
/// the suite (which mocks the model), this drives `AIEngine` against the actual
/// FoundationModels runtime, so it only runs when RUN_LIVE_AI is set — the
/// normal `swift test` skips it entirely (the model is slow and its wording is
/// non-deterministic). It closes M3's "never seen live" gap and confirms M4's
/// precondition: with Apple Intelligence on, a snippet produces a real
/// suggestion (summary + sanitized filename + embedding), not a fallback.
///
///   RUN_LIVE_AI=1 swift test --filter LiveAISmokeTests
@Suite("Live AI smoke", .serialized)
struct LiveAISmokeTests {

    @Test("A snippet yields a real suggestion end-to-end",
          .enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE_AI"] != nil))
    @MainActor
    func liveSuggestion() async throws {
        let availability = SystemLanguageModel.default.availability
        print("live-ai: availability = \(availability)")
        guard case .available = availability else {
            Issue.record("Apple Intelligence unavailable (\(availability)) — enable it to run this smoke test.")
            return
        }

        // A synthetic invoice snippet (no real user data) so the printed
        // summary/filename can be eyeballed for quality.
        let event = FileEvent(
            url: URL(fileURLWithPath: "/tmp/Invoice-ACME-0447.pdf"),
            size: 1234,
            detectedAt: Date()
        )
        let content = ExtractedContent(
            event: event,
            snippet: "INVOICE  ACME Corporation  Bill To Jane Founder  Invoice #0447  Amount Due $1,240.00  Due Date 2026-08-01  Please remit payment.",
            method: .plainText,
            wordCount: 20
        )

        let engine = AIEngine()
        let start = Date()
        let result: AIResult = await withCheckedContinuation { cont in
            engine.suggest(for: content) { cont.resume(returning: $0) }
        }
        print(String(format: "live-ai: generation took %.1fs", Date().timeIntervalSince(start)))

        switch result {
        case .suggestion(let s):
            print("live-ai: summary  = \(s.summary)")
            print("live-ai: filename = \(s.suggestedFilename)")
            print("live-ai: embedding dims = \(s.embedding?.count.description ?? "nil")")
            #expect(!s.summary.isEmpty)
            #expect(!s.suggestedFilename.isEmpty)
            #expect(!s.suggestedFilename.contains("/"))
        case .unavailable(let reason):
            Issue.record("live-ai: expected a suggestion, got unavailable — \(reason.label)")
        }
    }
}
