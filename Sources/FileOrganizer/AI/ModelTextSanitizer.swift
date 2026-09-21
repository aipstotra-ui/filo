import Foundation

/// Scalar-level cleanup shared by everything the model writes: the filename
/// path (`FilenameSanitizer`) and the summary path (`SummarySanitizer`).
/// Model output is untrusted input (docs/process/ai-engineering.md) — no model string
/// reaches the UI or a filesystem API without passing through here.
enum DangerousScalars {
    /// Bidirectional and invisible format controls that can visually reorder
    /// or hide text (ALM, LRM/RLM, LRE/RLE/PDF/LRO/RLO, LRI/RLI/FSI/PDI),
    /// plus the invisible zero-width space, word joiner, and ZWNBSP/BOM.
    /// Deliberately NOT included: U+200D (zero-width joiner) — stripping it
    /// would break family emoji into separate people.
    private static let bidiFormatControls: Set<Unicode.Scalar> = [
        "\u{061C}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{200B}", "\u{2060}", "\u{FEFF}",
    ]

    /// Removes control characters (Unicode category Cc: NULs, terminal
    /// escapes, line breaks) and the bidi/format controls above; folds the
    /// Unicode line/paragraph separators (U+2028/U+2029) to a space.
    ///
    /// `foldingWhitespaceControlsToSpaces` is for display text (summaries):
    /// newlines, carriage returns, and tabs become spaces instead of
    /// vanishing, so words don't merge. Filenames keep the drop behavior.
    static func stripped(from text: String, foldingWhitespaceControlsToSpaces: Bool) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == "\u{2028}" || scalar == "\u{2029}" {
                result += " "
                continue
            }
            if bidiFormatControls.contains(scalar) { continue }
            if scalar.properties.generalCategory == .control {
                if foldingWhitespaceControlsToSpaces,
                    scalar == "\n" || scalar == "\r" || scalar == "\t" {
                    result += " "
                }
                continue
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

/// Sanitizes a model-written summary for display. The summary is shown in the
/// UI (M4's popup), so it gets the same scalar stripping as filenames, plus:
/// interior line breaks fold to spaces, whitespace runs collapse, and the
/// result is capped at one line of 120 characters.
enum SummarySanitizer {
    /// Matches the `@Guide` limit in `NamingOutput.summary`.
    static let maxLength = 120

    static func sanitize(_ raw: String) -> String {
        let stripped = DangerousScalars.stripped(
            from: raw, foldingWhitespaceControlsToSpaces: true
        )
        let collapsed = stripped
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }
}
