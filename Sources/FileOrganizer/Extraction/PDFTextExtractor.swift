import Foundation
import PDFKit

/// Pulls text from PDFs. Digital PDFs give up their text layer directly;
/// scanned PDFs (no text layer) get page 1 rendered and OCR'd instead.
struct PDFTextExtractor {
    private let maxPages = 10

    func extract(from event: FileEvent) -> ExtractorOutcome {
        guard let document = PDFDocument(url: event.url) else {
            return .metadataOnly(.unreadableFile)
        }
        // isLocked only: many bank statements and e-tickets are encrypted with
        // an owner password but open (and extract) fine — isEncrypted is true
        // for those, and rejecting them would fall back on exactly the files
        // this app is most useful for.
        if document.isLocked {
            return .metadataOnly(.passwordProtected)
        }

        var accumulated = ""
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index), let pageText = page.string else { continue }
            accumulated += pageText + "\n"
            if SnippetBudget.wordCount(of: accumulated) >= SnippetBudget.maxWords {
                break
            }
        }
        if !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(accumulated, method: .pdfText)
        }

        // No text layer at all: a scanned PDF. Render page 1 and OCR it.
        // Render failures are *our* failure to scan — never claim the file
        // has no text when we couldn't even look at it.
        guard let firstPage = document.page(at: 0) else {
            return .metadataOnly(.scanFailed)
        }
        let rendered = firstPage.thumbnail(of: CGSize(width: 1600, height: 2000), for: .mediaBox)
        guard let cgImage = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .metadataOnly(.scanFailed)
        }
        do {
            let ocrText = try ImageOCRExtractor.recognizedText(in: cgImage)
            guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .metadataOnly(.noReadableText)
            }
            return .text(ocrText, method: .pdfPageOCR)
        } catch {
            return .metadataOnly(.scanFailed)
        }
    }
}
