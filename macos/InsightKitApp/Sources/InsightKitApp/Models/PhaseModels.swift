import Foundation

// MARK: - Session Phase

enum SessionPhase: String, Equatable {
    case preparing
    case running
    case postSession
    case reviewing
    // Import-specific
    case selecting
    case processing
}

// MARK: - Chapter Summary

struct ChapterSummary: Identifiable, Equatable {
    let id: UUID
    let timestamp: TimeInterval
    let title: String
    let summary: String

    init(id: UUID = UUID(), timestamp: TimeInterval, title: String, summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.summary = summary
    }
}

// MARK: - Smart Minutes

struct SmartMinutes: Identifiable {
    let id: UUID
    let generatedAt: Date
    let structuredSummary: String
    let highlights: [String]
    let speakerSummaries: [SpeakerMinutesSummary]
    let keyDecisions: [String]
    let actionItems: [String]
    let chapters: [ChapterSummary]

    init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        structuredSummary: String = "",
        highlights: [String] = [],
        speakerSummaries: [SpeakerMinutesSummary] = [],
        keyDecisions: [String] = [],
        actionItems: [String] = [],
        chapters: [ChapterSummary] = []
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.structuredSummary = structuredSummary
        self.highlights = highlights
        self.speakerSummaries = speakerSummaries
        self.keyDecisions = keyDecisions
        self.actionItems = actionItems
        self.chapters = chapters
    }
}

struct SpeakerMinutesSummary: Identifiable, Equatable {
    let id: UUID
    let speakerName: String
    let summary: String

    init(id: UUID = UUID(), speakerName: String, summary: String) {
        self.id = id
        self.speakerName = speakerName
        self.summary = summary
    }
}

// MARK: - Timestamped Note

struct TimestampedNote: Identifiable, Equatable {
    let id: UUID
    var text: String
    let timestamp: TimeInterval
    let createdAt: Date

    init(id: UUID = UUID(), text: String, timestamp: TimeInterval, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.createdAt = createdAt
    }
}

// MARK: - Transcript Entry (for panel protocol)

struct TranscriptEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: TimeInterval
    let speaker: String?
    let text: String

    init(id: UUID = UUID(), timestamp: TimeInterval, speaker: String? = nil, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - Capture Preview Provider

protocol CapturePreviewProvider {
    var previewLayer: Any? { get }
}
