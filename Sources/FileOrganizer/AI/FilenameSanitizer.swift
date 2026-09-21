import Foundation

/// Sanitizes a model-suggested filename before it may touch any filesystem API.
/// Model output is untrusted input (docs/process/ai-engineering.md) — this is the
/// output-side enforcement of the injection defense.
///
/// Contract (specified by FilenameSanitizerTests):
/// - strips path separators (`/`, `:`, `\`), control characters, bidi/format
///   controls, and leading dots; folds separator-lookalike scalars to `-`
/// - discards whatever extension the model chose and always re-applies
///   `originalExtension` in code — but only when that extension is itself a
///   plain alphanumeric tail (`^[A-Za-z0-9]{1,8}$`); anything else appends
///   no extension at all
/// - caps the full result at 100 characters (grapheme clusters — never split
///   a CJK character or emoji)
/// - returns `nil` when nothing usable remains (empty, whitespace-only,
///   symbol-only input); the caller then falls back to metadata-only naming
enum FilenameSanitizer {
    /// Cap on the full name, extension included, counted in Characters.
    static let maxLength = 100

    static func sanitize(_ raw: String, originalExtension: String) -> String? {
        var name = removingDangerousScalars(from: raw)

        // ".." must never survive (path traversal); collapse runs of dots.
        while name.contains("..") {
            name = name.replacingOccurrences(of: "..", with: ".")
        }

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // A leading dot would make the file hidden.
        while name.hasPrefix(".") {
            name.removeFirst()
        }

        // The model's extension is never trusted — ours is re-applied below.
        name = droppingModelExtension(name)
        name = trimmingTrailingJunk(name)

        guard !name.isEmpty else { return nil }

        // The real file's extension is still outside input (an attacker names
        // the downloaded file): only a plain alphanumeric tail may be
        // re-appended, or a hostile extension ("aa:bb", "pdf\nx") would
        // reintroduce the very characters stripped above.
        let extensionIsSafe = originalExtension.range(
            of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression
        ) != nil
        let suffix = extensionIsSafe ? ".\(originalExtension)" : ""
        let allowedStemLength = Swift.max(0, maxLength - suffix.count)
        name = trimmingTrailingJunk(String(name.prefix(allowedStemLength)))
        guard !name.isEmpty else { return nil }

        return name + suffix
    }

    /// Unicode scalars that read as path separators without being one:
    /// fraction slash, fullwidth solidus, division slash, fullwidth
    /// backslash, fullwidth colon, big solidus. Folded to `-` so the name
    /// keeps its shape without ever looking like a path.
    private static let separatorLookalikes: Set<Unicode.Scalar> = [
        "\u{2044}", "\u{FF0F}", "\u{2215}", "\u{FF3C}", "\u{FF1A}", "\u{29F8}",
    ]

    /// Removes path separators (a name must stay a single path component) and
    /// folds separator lookalikes to `-`; then hands off to the shared
    /// `DangerousScalars` stripper (control characters, bidi/format controls,
    /// line separators) used by the summary path too. Everything else —
    /// including all Unicode letters and emoji — passes through untouched.
    private static func removingDangerousScalars(from text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" { continue }
            if separatorLookalikes.contains(scalar) {
                result += "-"
                continue
            }
            result.unicodeScalars.append(scalar)
        }
        return DangerousScalars.stripped(
            from: result, foldingWhitespaceControlsToSpaces: false
        )
    }

    /// Drops trailing ".ext"-shaped tails (1–8 alphanumerics), repeatedly, so
    /// double extensions like "statement.pdf.exe" lose both.
    private static func droppingModelExtension(_ name: String) -> String {
        var result = name
        while let range = result.range(
            of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression
        ) {
            result.removeSubrange(range)
        }
        return result
    }

    /// Trailing whitespace or dots (left over after stripping or truncation)
    /// would produce names like "report ." — trim them.
    private static func trimmingTrailingJunk(_ name: String) -> String {
        var result = name
        while let last = result.last, last == "." || last.isWhitespace {
            result.removeLast()
        }
        return result
    }
}
