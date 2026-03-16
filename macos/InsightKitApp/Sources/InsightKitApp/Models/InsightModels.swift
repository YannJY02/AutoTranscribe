import Foundation

struct WorkbenchItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let body: String
    let meta: String
    let evidence: EvidenceRange?
}

struct ActionItem: Identifiable, Hashable {
    let id = UUID()
    var task: String
    var owner: String
    var status: String
    var dueAt: String
    var priority: String
    var needsReview: Bool
    var evidence: EvidenceRange?
}

struct InsightWorkbenchState {
    var sessionOverview: String
    var highlightInsights: [WorkbenchItem]
    var speakerPerspectives: [WorkbenchItem]
    var decisionLedger: [WorkbenchItem]
    var actionTracks: [WorkbenchItem]
    var timelineBeats: [WorkbenchItem]

    static let empty = InsightWorkbenchState(
        sessionOverview: "尚未生成洞察内容。",
        highlightInsights: [],
        speakerPerspectives: [],
        decisionLedger: [],
        actionTracks: [],
        timelineBeats: []
    )
}

enum InsightTab: String, CaseIterable, Identifiable {
    case sessionOverview = "会话总览"
    case highlightInsights = "高光洞察"
    case speakerMap = "观点图谱"
    case decisionLedger = "决策账本"
    case actionTracks = "执行清单"
    case timelineBeats = "时间脉络"

    var id: String { rawValue }
}

struct InsightRefreshResult {
    let package: InsightPackageV1
    let updatedAt: Date?
    let provider: String
    let needsReviewCount: Int
}

struct InsightPackageV1: Codable {
    struct EvidenceSpan: Codable {
        let startMs: Int
        let endMs: Int

        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case endMs = "end_ms"
        }
    }

    struct SessionOverview: Codable {
        let title: String
        let overview: String
        let topics: [String]
    }

    struct Highlight: Codable {
        let quote: String
        let reason: String
        let speaker: String
        let evidenceSpan: EvidenceSpan

        enum CodingKeys: String, CodingKey {
            case quote
            case reason
            case speaker
            case evidenceSpan = "evidence_span"
        }
    }

    struct SpeakerPerspective: Codable {
        let speaker: String
        let viewpoints: [String]
        let evidenceSpans: [EvidenceSpan]

        enum CodingKeys: String, CodingKey {
            case speaker
            case viewpoints
            case evidenceSpans = "evidence_spans"
        }
    }

    struct Decision: Codable {
        let problem: String
        let options: [String]
        let decision: String
        let rationale: String
        let owner: String
        let needsReview: Bool?
        let evidenceSpan: EvidenceSpan

        enum CodingKeys: String, CodingKey {
            case problem
            case options
            case decision
            case rationale
            case owner
            case needsReview = "needs_review"
            case evidenceSpan = "evidence_span"
        }
    }

    struct ActionTrack: Codable {
        let task: String
        let owner: String
        let dueAt: String
        let priority: String
        let status: String
        let needsReview: Bool?
        let evidenceSpan: EvidenceSpan

        enum CodingKeys: String, CodingKey {
            case task
            case owner
            case dueAt = "due_at"
            case priority
            case status
            case needsReview = "needs_review"
            case evidenceSpan = "evidence_span"
        }
    }

    struct TimelineBeat: Codable {
        let timestamp: String
        let title: String
        let summary: String
    }

    struct ProvenanceLink: Codable {
        let label: String
        let url: String
    }

    let sessionOverview: SessionOverview
    let highlightInsights: [Highlight]
    let speakerPerspectives: [SpeakerPerspective]
    let decisionLedger: [Decision]
    let actionTracks: [ActionTrack]
    let timelineBeats: [TimelineBeat]
    let provenanceLinks: [ProvenanceLink]

    enum CodingKeys: String, CodingKey {
        case sessionOverview = "session_overview"
        case highlightInsights = "highlight_insights"
        case speakerPerspectives = "speaker_perspectives"
        case decisionLedger = "decision_ledger"
        case actionTracks = "action_tracks"
        case timelineBeats = "timeline_beats"
        case provenanceLinks = "provenance_links"
    }
}

extension InsightPackageV1.EvidenceSpan {
    var range: EvidenceRange {
        EvidenceRange(startMs: startMs, endMs: endMs)
    }
}
