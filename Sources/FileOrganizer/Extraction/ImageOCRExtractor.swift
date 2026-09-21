import Foundation
import ImageIO
import Vision

/// OCRs screenshots and other images with Apple's on-device Vision framework.
/// Everything runs locally; the image never leaves the machine.
struct ImageOCRExtractor {
    /// Cheap first filter: OCR on huge files (RAW photos etc.) is rarely useful.
    private static let maxFileSize: Int64 = 30 * 1024 * 1024
    /// Decoded-pixel bound: a small PNG can decode to multi-gigabyte bitmaps
    /// (decompression bomb), so decoding goes through a capped thumbnail.
    private static let maxPixelSize = 4000

    /// `fileSize` is the fresh size from the engine's routing check —
    /// `event.size` is 2+ seconds stale by the time extraction runs.
    func extract(from event: FileEvent, fileSize: Int64) -> ExtractorOutcome {
        guard fileSize <= Self.maxFileSize else {
            return .metadataOnly(.tooLarge)
        }
        // Thumbnail decoding bounds memory no matter what the pixel dimensions
        // claim; Vision reads downsampled text fine at this size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(event.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .metadataOnly(.unreadableFile)
        }
        do {
            let text = try Self.recognizedText(in: image)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .metadataOnly(.noReadableText)
            }
            return .text(text, method: .ocr)
        } catch {
            return .metadataOnly(.scanFailed)
        }
    }

    /// Core CGImage → text routine, shared with `PDFTextExtractor` for scanned PDFs.
    /// Vision's `perform` is synchronous and throwing — callers run this on the
    /// extraction queue and map errors to `.metadataOnly`.
    static func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
