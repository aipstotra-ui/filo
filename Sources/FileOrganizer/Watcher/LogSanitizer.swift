import Foundation

/// Dev-log sanitizer. Filenames and file content are attacker-controlled, so
/// anything echoed to the terminal must have control characters stripped
/// (they can carry ANSI escape sequences) and line breaks folded to "⏎".
/// Lives in Watcher so both Watcher and Extraction can use it (pipeline order).
enum LogSanitizer {
    static func sanitized(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r"
                || scalar == "\u{2028}" || scalar == "\u{2029}" {
                result += "⏎"
            } else if CharacterSet.controlCharacters.contains(scalar) {
                continue
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
