import Foundation

/// Why a file fell back to name-and-type-only extraction. Typed, so the
/// compiler — not string comparison — keeps the UI and extractors in sync.
enum FallbackReason {
    case unsupportedType
    case emptyFile
    case fileDisappeared
    case noPermission
    case unreadableFile
    case passwordProtected
    /// Opened and scanned fine, but no text was found inside.
    case noReadableText
    case scanFailed
    case tooLarge
    case timedOut
    /// Claims to be text (.txt etc.) but the bytes are binary.
    case binaryContent

    /// Short human label, shown in the menu as "<label> — using name & type".
    var label: String {
        switch self {
        case .unsupportedType: return "Unsupported type"
        case .emptyFile: return "Empty file"
        case .fileDisappeared: return "File disappeared"
        case .noPermission: return "No permission to read"
        case .unreadableFile: return "Unreadable file"
        case .passwordProtected: return "Password-protected"
        case .noReadableText: return "No readable text"
        case .scanFailed: return "Text scan failed"
        case .tooLarge: return "Too large to read"
        case .timedOut: return "Took too long to read"
        case .binaryContent: return "Not readable text"
        }
    }
}

/// How a file's snippet was obtained — surfaced in the UI so the user always
/// knows what the app could (and couldn't) read.
enum ExtractionMethod {
    case pdfText
    case ocr
    case pdfPageOCR
    case plainText
    /// Nothing readable inside; the snippet is just filename + type + size + date.
    case metadataOnly(FallbackReason)

    /// Short human-readable label for the menu UI.
    var label: String {
        switch self {
        case .pdfText: return "PDF text"
        case .ocr: return "Screenshot text"
        case .pdfPageOCR: return "Scanned page"
        case .plainText: return "Text file"
        case .metadataOnly: return "Name & type only"
        }
    }
}

/// What Extraction hands onward: a bounded, in-memory text snippet.
/// Snippets are never written to disk or logs (see docs/product/decisions.md).
struct ExtractedContent {
    let event: FileEvent
    let snippet: String
    let method: ExtractionMethod
    let wordCount: Int
}
