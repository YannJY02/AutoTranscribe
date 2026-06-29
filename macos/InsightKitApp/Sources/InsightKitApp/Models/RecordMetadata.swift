import Foundation

enum MediaType: String, Codable {
    case audio
    case video
}

enum RecordSource: String, Codable {
    case live
    case imported
}

struct RecordMetadata: Identifiable, Codable, Equatable {
    let id: String
    let createdAt: Date
    let duration: TimeInterval
    let mediaType: MediaType
    let source: RecordSource
    var title: String?
    var userTags: [String]
    var autoTags: [String]
    var summaryPreview: String?

    var displayTitle: String {
        if let title = Self.trimmedNonEmpty(title) {
            return title
        }
        if let generatedTitle = Self.standardizedGeneratedTitle(summaryPreview) {
            return generatedTitle
        }
        return "\(source.defaultTitlePrefix) \(Self.defaultTitleDateFormatter.string(from: createdAt))"
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func standardizedGeneratedTitle(_ value: String?) -> String? {
        guard var title = trimmedNonEmpty(value) else { return nil }
        title = title.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        while let first = title.first, "-*#•".contains(first) {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !title.isEmpty else { return nil }
        guard title.count > generatedTitleMaxCharacters else { return title }
        let end = title.index(title.startIndex, offsetBy: generatedTitleMaxCharacters - 3)
        let prefix = String(title[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }

    private static let generatedTitleMaxCharacters = 44

    private static let defaultTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

extension RecordSource {
    var defaultTitlePrefix: String {
        switch self {
        case .live:
            return "实时记录"
        case .imported:
            return "导入记录"
        }
    }
}
