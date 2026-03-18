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
    var userTags: [String]
    var autoTags: [String]
    var summaryPreview: String?
}
