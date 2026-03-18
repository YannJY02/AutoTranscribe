import Foundation

/// Lightweight utility for serializing and parsing timestamped notes to/from notes.md format.
/// Format: each line is "MM:SS text"
enum NotesFileIO {
    static func serialize(_ notes: [TimestampedNote]) -> String {
        notes.map { note in
            let totalSec = Int(note.timestamp)
            let mm = totalSec / 60
            let ss = totalSec % 60
            return String(format: "%02d:%02d %@", mm, ss, note.text)
        }.joined(separator: "\n")
    }

    static func parse(_ content: String) -> [TimestampedNote] {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                return TimestampedNote(text: line, timestamp: 0)
            }
            let timeParts = parts[0].split(separator: ":")
            let seconds: TimeInterval
            if timeParts.count == 2, let m = Int(timeParts[0]), let s = Int(timeParts[1]) {
                seconds = TimeInterval(m * 60 + s)
            } else {
                seconds = 0
            }
            return TimestampedNote(text: String(parts[1]), timestamp: seconds)
        }
    }

    static func write(_ notes: [TimestampedNote], to url: URL) {
        let content = serialize(notes)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func read(from url: URL) -> [TimestampedNote] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(content)
    }
}
