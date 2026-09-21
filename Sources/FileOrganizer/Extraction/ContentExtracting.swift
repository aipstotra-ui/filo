import Foundation

/// Module boundary between Watcher output and the AI engine's input:
/// a stable new file goes in, a bounded text snippet comes out.
protocol ContentExtracting {
    /// Extracts a snippet for the given file.
    /// The completion is called exactly once, on the main queue, unless the
    /// engine is deallocated mid-flight (app teardown). Every failure surfaces
    /// as `.metadataOnly(reason)`, never as silence.
    func extract(from event: FileEvent, completion: @escaping (ExtractedContent) -> Void)
}
