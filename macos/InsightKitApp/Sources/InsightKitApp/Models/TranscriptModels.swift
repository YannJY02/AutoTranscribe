import Foundation

struct TranscriptSegment: Identifiable, Hashable {
    let id = UUID()
    let startMs: Int
    let endMs: Int
    let speaker: String
    let source: String
    let text: String

    var timeLabel: String {
        let seconds = max(0, startMs / 1000)
        let min = seconds / 60
        let sec = seconds % 60
        return String(format: "%02d:%02d", min, sec)
    }

    func overlaps(_ range: EvidenceRange?) -> Bool {
        guard let range else { return false }
        return !(endMs < range.startMs || startMs > range.endMs)
    }
}

struct EvidenceRange: Hashable, Codable {
    let startMs: Int
    let endMs: Int

    var label: String {
        "\(timeLabel(from: startMs))-\(timeLabel(from: endMs))"
    }

    private func timeLabel(from ms: Int) -> String {
        let sec = max(0, ms / 1000)
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}
