import Testing
@testable import FileOrganizer

/// Contract tests for SummarySanitizer — the display-side twin of
/// FilenameSanitizer. A model summary is untrusted text that M4's popup will
/// render, so interior control characters, bidi overrides, and line breaks
/// must never survive to the UI.
@Suite("SummarySanitizer")
struct SummarySanitizerTests {

    @Test("Strips control characters anywhere in the text, not just the edges")
    func stripsInteriorControlCharacters() {
        let raw = "Chase\u{0}state\u{1B}ment\u{7F} June"
        #expect(SummarySanitizer.sanitize(raw) == "Chasestatement June")
    }

    @Test("Strips bidirectional and invisible format controls")
    func stripsBidiControls() {
        let raw = "Invoice \u{202E}gnp.eruci\u{202C} from \u{200F}ACME\u{2066}\u{2069}"
        let result = SummarySanitizer.sanitize(raw)
        for scalar in ["\u{202E}", "\u{202C}", "\u{200F}", "\u{2066}", "\u{2069}"] {
            #expect(!result.contains(scalar))
        }
    }

    @Test("Strips zero-width space, word joiner, and BOM")
    func stripsInvisibleScalars() {
        let raw = "\u{FEFF}Bank\u{200B}statement\u{2060} June"
        #expect(SummarySanitizer.sanitize(raw) == "Bankstatement June")
    }

    @Test("Folds interior newlines and line separators to single spaces")
    func foldsLineBreaksToSpaces() {
        let raw = "line one\nline two\r\nline three\u{2028}line four\u{2029}line five"
        #expect(
            SummarySanitizer.sanitize(raw)
                == "line one line two line three line four line five"
        )
    }

    @Test("Trims and collapses runs of whitespace")
    func collapsesWhitespace() {
        #expect(SummarySanitizer.sanitize("  a   bank\t\tstatement  ") == "a bank statement")
    }

    @Test("Caps at 120 characters")
    func capsAtOneHundredTwentyCharacters() {
        let raw = String(repeating: "統", count: 300)
        let result = SummarySanitizer.sanitize(raw)
        #expect(result.count == SummarySanitizer.maxLength)
        #expect(result.allSatisfy { $0 == "統" })
    }

    @Test("Keeps the zero-width joiner so family emoji survive")
    func keepsZeroWidthJoiner() {
        let family: Character = "👨‍👩‍👧‍👦"
        let result = SummarySanitizer.sanitize("Photo of \(family) at the beach")
        #expect(result.contains(family))
    }

    @Test("Empty and whitespace-only input becomes the empty string")
    func emptyInputStaysEmpty() {
        #expect(SummarySanitizer.sanitize("") == "")
        #expect(SummarySanitizer.sanitize(" \n\t ") == "")
    }
}
