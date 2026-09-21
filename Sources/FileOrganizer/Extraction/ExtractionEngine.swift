import Foundation
import UniformTypeIdentifiers

/// Internal handoff from a type-specific extractor back to the engine.
/// The engine applies the snippet budget to `.text` and builds the
/// metadata snippet for `.metadataOnly` — extractors never do either.
enum ExtractorOutcome {
    case text(String, method: ExtractionMethod)
    case metadataOnly(FallbackReason)
}

/// The global snippet budget, enforced centrally by `ExtractionEngine`.
/// Extractors may consult the limits early (e.g. to stop walking PDF pages).
enum SnippetBudget {
    static let maxCharacters = 4000
    static let maxWords = 500

    static func wordCount(of text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// Trims, then truncates on a word boundary once either limit is hit.
    static func truncated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = 0
        var cut = trimmed.startIndex
        var overBudget = false
        trimmed.enumerateSubstrings(
            in: trimmed.startIndex..<trimmed.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            if words >= maxWords
                || trimmed.distance(from: trimmed.startIndex, to: range.upperBound) > maxCharacters {
                overBudget = true
                stop = true
                return
            }
            words += 1
            cut = range.upperBound
        }
        guard overBudget else { return trimmed }
        if cut == trimmed.startIndex {
            // One giant "word" (base64 blob etc.) — no boundary to cut at, hard-cap it.
            return String(trimmed.prefix(maxCharacters))
        }
        return String(trimmed[..<cut])
    }
}

/// Routes each announced file to the right extractor, one file at a time,
/// off the main thread. Every path ends in a completion call on the main queue.
final class ExtractionEngine: ContentExtracting {
    /// Parsing a malformed multi-hundred-MB PDF can hang or exhaust memory.
    private static let maxPDFFileSize: Int64 = 200 * 1024 * 1024

    /// Serial on purpose: OCR and PDF parsing are heavy; one file at a time
    /// keeps the machine responsive and memory flat.
    private let queue = DispatchQueue(label: "extraction", qos: .utility)

    private let pdfExtractor = PDFTextExtractor()
    private let imageExtractor = ImageOCRExtractor()
    private let textExtractor = PlainTextExtractor()

    #if DEBUG
    /// Founder-approved debug flag: prints a short *sanitized* snippet preview
    /// to stdout. Off by default — normal runs never print file content, and the
    /// whole logging path is compiled out of release builds (see `logResult`), so
    /// no environment variable can surface file content in a shipped binary.
    private let debugSnippets =
        ProcessInfo.processInfo.environment["FILE_ORGANIZER_DEBUG_SNIPPETS"] == "1"
    #endif

    func extract(from event: FileEvent, completion: @escaping (ExtractedContent) -> Void) {
        queue.async { [weak self] in
            // Engine gone = app tearing down; nobody is left to receive the result.
            guard let self = self else { return }
            let content = self.performExtraction(for: event)
            #if DEBUG
            self.logResult(content)
            #endif
            DispatchQueue.main.async { completion(content) }
        }
    }

    // MARK: - Routing

    private func performExtraction(for event: FileEvent) -> ExtractedContent {
        switch route(event) {
        case .text(let raw, let method):
            let snippet = SnippetBudget.truncated(raw)
            guard !snippet.isEmpty else {
                return metadataContent(for: event, reason: .noReadableText)
            }
            return ExtractedContent(
                event: event,
                snippet: snippet,
                method: method,
                wordCount: SnippetBudget.wordCount(of: snippet)
            )
        case .metadataOnly(let reason):
            return metadataContent(for: event, reason: reason)
        }
    }

    private func route(_ event: FileEvent) -> ExtractorOutcome {
        let values: URLResourceValues
        do {
            values = try event.url.resourceValues(
                forKeys: [.isRegularFileKey, .contentTypeKey, .fileSizeKey]
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoPermissionError {
                return .metadataOnly(.noPermission)
            }
            // Gone between announce and extraction (user moved/deleted it).
            return .metadataOnly(.fileDisappeared)
        }
        guard values.isRegularFile == true else {
            return .metadataOnly(.fileDisappeared)
        }
        // A nil size is *unknown*, not zero — only a confirmed 0 means empty.
        if let size = values.fileSize, size == 0 {
            return .metadataOnly(.emptyFile)
        }
        // Fresh size for the extractors; event.size is 2+ seconds stale.
        let fileSize = values.fileSize.map(Int64.init) ?? event.size

        guard let type = values.contentType else {
            return .metadataOnly(.unsupportedType)
        }
        if type.conforms(to: .pdf) {
            guard fileSize <= Self.maxPDFFileSize else {
                return .metadataOnly(.tooLarge)
            }
            return pdfExtractor.extract(from: event)
        }
        // SVG conforms to both .image and .text; it's XML, so read it as text —
        // image OCR can't decode SVG at all. Must be checked before .image.
        if type.conforms(to: .svg) {
            return textExtractor.extract(from: event)
        }
        if type.conforms(to: .image) {
            return imageExtractor.extract(from: event, fileSize: fileSize)
        }
        if type.conforms(to: .text) {
            return textExtractor.extract(from: event)
        }
        return .metadataOnly(.unsupportedType)
    }

    // MARK: - Metadata fallback

    private static let createdDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func metadataContent(for event: FileEvent, reason: FallbackReason) -> ExtractedContent {
        var typeDescription = "unknown type"
        var createdText = ""
        // try? is fine here: if metadata can't be read we still produce a useful
        // snippet from the name and size — nothing the user cares about is lost.
        if let values = try? event.url.resourceValues(
            forKeys: [.localizedTypeDescriptionKey, .creationDateKey]
        ) {
            if let description = values.localizedTypeDescription {
                typeDescription = description
            }
            if let created = values.creationDate {
                createdText = Self.createdDateFormatter.string(from: created)
            }
        }
        var parts = [event.name, typeDescription, event.formattedSize]
        if !createdText.isEmpty {
            parts.append("created \(createdText)")
        }
        let snippet = parts.joined(separator: " — ")
        return ExtractedContent(
            event: event,
            snippet: snippet,
            method: .metadataOnly(reason),
            wordCount: SnippetBudget.wordCount(of: snippet)
        )
    }

    // MARK: - Dev logging (DEBUG builds only — the whole path is compiled out of
    // release, so neither filenames nor any content snippet can reach a shipped log)

    #if DEBUG
    private func logResult(_ content: ExtractedContent) {
        // Filenames are attacker-controlled too — sanitize them like content.
        let safeName = LogSanitizer.sanitized(content.event.name)
        print("extracted: \(safeName) — \(content.method.label) — \(content.wordCount) words")
        if debugSnippets {
            let preview = LogSanitizer.sanitized(String(content.snippet.prefix(200)))
            print("snippet[\(content.method.label)]: \(preview)")
        }
        fflush(stdout)
    }
    #endif
}
