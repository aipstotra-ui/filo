import Foundation

/// Reads plain-text files (txt, md, csv, source code…). Only the first 64 KB
/// is ever read — a multi-gigabyte log file costs the same as a note.
struct PlainTextExtractor {
    private static let maxBytes = 64 * 1024

    func extract(from event: FileEvent) -> ExtractorOutcome {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: event.url)
            // Closing a read-only handle can't lose anything the user cares about.
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maxBytes) ?? Data()
        } catch {
            return .metadataOnly(.unreadableFile)
        }
        guard !data.isEmpty else {
            return .metadataOnly(.emptyFile)
        }

        // UTF-16 encodes ASCII as pairs with a NUL byte, so files with a UTF-16
        // byte-order mark must bypass the NUL gate below or every real UTF-16
        // file would be rejected. The printability check is still the backstop.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16),
                  Self.isMostlyPrintable(text) else {
                return .metadataOnly(.binaryContent)
            }
            return .text(text, method: .plainText)
        }

        // Real (non-UTF-16) text virtually never contains NUL bytes; binary data
        // virtually always does. Cheap first gate — Latin-1 decoding below
        // "succeeds" on any bytes, so it can't be the gate.
        guard !data.contains(0) else {
            return .metadataOnly(.binaryContent)
        }
        let text = Self.decoded(data)
        guard Self.isMostlyPrintable(text) else {
            // A binary file wearing a .txt name — don't feed garbage onward.
            return .metadataOnly(.binaryContent)
        }
        return .text(text, method: .plainText)
    }

    /// UTF-8 first, ISO Latin-1 as the never-fails last resort (the
    /// printability check catches true binary). UTF-16 is handled earlier,
    /// by its byte-order mark.
    private static func decoded(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        // A 64 KB cut can split a multi-byte UTF-8 character right at the end;
        // retry with up to 3 trailing bytes trimmed before giving up on UTF-8.
        if data.count == maxBytes {
            for trim in 1...3 {
                if let utf8 = String(data: data.dropLast(trim), encoding: .utf8) {
                    return utf8
                }
            }
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// True if the decoded text looks like language rather than decoded binary:
    /// almost no control characters, and mostly letters/digits/punctuation/space.
    /// (Merely "not a control character" is too weak — random bytes decoded as
    /// Latin-1 become accented letters and pass; QA caught exactly that.)
    private static func isMostlyPrintable(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return false }
        var control = 0
        var textLike = 0
        let textLikeSet = CharacterSet.alphanumerics
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        for scalar in scalars {
            // Whitespace is checked first on purpose: newline and tab are also
            // control characters, and they must count as text, not against it.
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                textLike += 1
            } else if CharacterSet.controlCharacters.contains(scalar) {
                control += 1
            } else if textLikeSet.contains(scalar) {
                textLike += 1
            }
        }
        let total = Double(scalars.count)
        return Double(control) / total < 0.02 && Double(textLike) / total >= 0.85
    }
}
