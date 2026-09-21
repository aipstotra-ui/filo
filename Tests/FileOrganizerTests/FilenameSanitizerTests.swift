import Testing
@testable import FileOrganizer

/// Contract tests for FilenameSanitizer — the output-side injection defense.
/// No raw model string may ever reach a filesystem API; these tests pin down
/// exactly what "safe" means. Each test is self-contained (pure function, no state).
@Suite("FilenameSanitizer")
struct FilenameSanitizerTests {

    // MARK: - Dangerous characters

    @Test("Strips path separators and control characters")
    func stripsSeparatorsAndControlCharacters() throws {
        let raw = "bank/state:ment\u{0}june\nreport\u{1B}final"
        let result = try #require(
            FilenameSanitizer.sanitize(raw, originalExtension: "pdf"),
            "a name with salvageable letters should not be rejected outright"
        )
        #expect(!result.contains("/"))
        #expect(!result.contains(":"))
        #expect(!result.contains("\u{0}"))
        #expect(!result.contains("\n"))
        #expect(!result.contains("\u{1B}"))
        #expect(result.hasSuffix(".pdf"))
    }

    @Test("Strips leading dots so a suggestion can never become a hidden file")
    func stripsLeadingDots() {
        let result = FilenameSanitizer.sanitize(".hidden", originalExtension: "txt")
        #expect(result == "hidden.txt")
    }

    @Test("Path traversal collapses to a separator-free, dot-free-prefix name")
    func rejectsTraversal() throws {
        let result = try #require(
            FilenameSanitizer.sanitize("../../etc/passwd", originalExtension: "pdf")
        )
        #expect(!result.contains("/"))
        #expect(!result.contains(".."))
        #expect(!result.hasPrefix("."))
        #expect(result.hasSuffix(".pdf"))
    }

    // MARK: - Length cap: 100 CHARACTERS, not bytes

    @Test("Caps at 100 characters counting characters, not bytes (CJK)")
    func capsAtOneHundredCharactersForCJK() throws {
        // 150 CJK characters; each is 3 UTF-8 bytes. A byte-based cap would
        // keep only ~32 of them — a character-based cap keeps ~96.
        let raw = String(repeating: "統", count: 150)
        let result = try #require(FilenameSanitizer.sanitize(raw, originalExtension: "pdf"))
        #expect(result.count <= 100)
        #expect(result.hasSuffix(".pdf"))
        let stem = result.dropLast(".pdf".count)
        #expect(stem.count >= 80, "cap must count characters, not bytes")
        #expect(stem.allSatisfy { $0 == "統" }, "truncation must not mangle CJK characters")
    }

    @Test("Truncation never splits an emoji grapheme cluster")
    func truncationPreservesEmojiClusters() throws {
        let family: Character = "👨‍👩‍👧‍👦" // one Character, 4 scalars joined by ZWJ
        let raw = String(repeating: String(family), count: 120)
        let result = try #require(FilenameSanitizer.sanitize(raw, originalExtension: "png"))
        #expect(result.count <= 100)
        #expect(result.hasSuffix(".png"))
        let stem = result.dropLast(".png".count)
        #expect(!stem.isEmpty)
        #expect(
            stem.allSatisfy { $0 == family },
            "a split ZWJ sequence would leave partial emoji in the stem"
        )
    }

    @Test("Strips bidirectional and invisible format controls")
    func stripsBidiAndFormatControls() throws {
        // Every bidi/format control that can visually reorder or hide text:
        // ALM, LRM, RLM, LRE/RLE/PDF/LRO/RLO, LRI/RLI/FSI/PDI.
        let controls: [Character] = [
            "\u{061C}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        ]
        let raw = "report" + String(controls) + "June"
        let result = try #require(FilenameSanitizer.sanitize(raw, originalExtension: "pdf"))
        for control in controls {
            #expect(!result.contains(control), "U+\(String(control.unicodeScalars.first!.value, radix: 16)) must be stripped")
        }
        #expect(result == "reportJune.pdf")
    }

    @Test("Keeps the zero-width joiner so family emoji survive")
    func keepsZeroWidthJoiner() {
        let result = FilenameSanitizer.sanitize("👨‍👩‍👧‍👦 beach day", originalExtension: "png")
        #expect(result == "👨‍👩‍👧‍👦 beach day.png")
    }

    @Test("Folds Unicode separator lookalikes to a dash")
    func foldsSeparatorLookalikesToDash() {
        // Fraction slash, fullwidth solidus, division slash, fullwidth
        // backslash, fullwidth colon, big solidus — all read as separators.
        let raw = "a\u{2044}b\u{FF0F}c\u{2215}d\u{FF3C}e\u{FF1A}f\u{29F8}g"
        let result = FilenameSanitizer.sanitize(raw, originalExtension: "pdf")
        #expect(result == "a-b-c-d-e-f-g.pdf")
    }

    // MARK: - Unusable input → nil

    @Test(
        "Empty, whitespace-only, and symbol-only suggestions are rejected",
        arguments: [
            "",
            "   \n\t  ",
            "///:::...",
            "\u{0}\u{1B}\r\n",
        ]
    )
    func rejectsUnusableInput(raw: String) {
        #expect(FilenameSanitizer.sanitize(raw, originalExtension: "pdf") == nil)
    }

    // MARK: - Extension is always ours, never the model's

    @Test("Always re-applies the real extension, ignoring the model's choice")
    func reappliesOriginalExtension() {
        let result = FilenameSanitizer.sanitize("statement.exe", originalExtension: "pdf")
        #expect(result == "statement.pdf")
    }

    @Test("A good plain name passes through with the extension appended")
    func goodNamePassesThrough() {
        let result = FilenameSanitizer.sanitize(
            "Chase Statement June 2026", originalExtension: "pdf"
        )
        #expect(result == "Chase Statement June 2026.pdf")
    }

    @Test(
        "A malformed original extension is dropped entirely, never appended",
        arguments: [
            "aa:bb",           // colon smuggled through the extension
            "pdf\nx",          // newline smuggled through the extension
            "p/df",            // path separator
            "pdf.exe",         // double extension
            "verylongext123",  // over 8 characters
            "",                // no extension at all
        ]
    )
    func rejectsMalformedOriginalExtension(badExtension: String) {
        let result = FilenameSanitizer.sanitize("statement", originalExtension: badExtension)
        #expect(result == "statement", "only ^[A-Za-z0-9]{1,8}$ may be appended")
    }

    // MARK: - Pinned behavior (security-auditor probes, M3)

    @Test("Windows-style backslash traversal loses every backslash and dot pair")
    func backslashTraversalStripped() throws {
        let result = try #require(
            FilenameSanitizer.sanitize("..\\..\\windows\\system32", originalExtension: "pdf")
        )
        #expect(!result.contains("\\"))
        #expect(!result.contains(".."))
        #expect(!result.hasPrefix("."))
        #expect(result == "windowssystem32.pdf")
    }

    @Test("NTFS alternate-data-stream colon is stripped")
    func ntfsAlternateDataStreamColonStripped() throws {
        let result = try #require(
            FilenameSanitizer.sanitize("report.pdf:Zone.Identifier", originalExtension: "pdf")
        )
        #expect(!result.contains(":"))
        #expect(result.hasSuffix(".pdf"))
        #expect(result == "report.pdfZone.Identifier.pdf")
    }
}
