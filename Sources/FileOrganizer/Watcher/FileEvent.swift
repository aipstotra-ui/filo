import Foundation

/// A completed new file that the watcher has announced.
struct FileEvent: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let size: Int64
    let detectedAt: Date

    var name: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
