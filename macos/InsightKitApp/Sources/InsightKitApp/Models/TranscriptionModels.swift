import Foundation

enum TranscriptionJobState: String, CaseIterable, Identifiable {
    case queued
    case running
    case completed
    case failed
    case pausedByLive = "paused_by_live"
    case cancelled

    var id: String { rawValue }
}

struct TranscriptionJob: Identifiable, Hashable {
    let id: String
    var meetingID: String
    var sourcePath: String
    var title: String
    var state: TranscriptionJobState
    var progress: Int
    var stage: String
    var error: String
    var reason: String
    var startedAt: Date?
    var endedAt: Date?
}

struct TranscriptionWatcherState: Equatable {
    var isRunning: Bool = false
    var dirs: [String] = []
    var queueSize: Int = 0
    var activeJobID: String?
}

enum TranscriptionPollingMode: String, Equatable {
    case idle
    case active
    case degraded
}

struct TranscriptionImportResult {
    let jobID: String
    let meetingID: String
    let state: TranscriptionJobState
}

struct TranscriptionWatchResult {
    let isRunning: Bool
    let dirs: [String]
}

struct TranscriptionCancelResult {
    let jobID: String
    let state: TranscriptionJobState
}

struct TranscriptionLastCompleted {
    let job: TranscriptionJob
    let meetingID: String
    let segmentsCount: Int
    let updatedAt: Date?
}

struct TranscriptionStatusResult {
    let watcher: TranscriptionWatcherState
    let queue: [TranscriptionJob]
    let activeJob: TranscriptionJob?
    let lastCompleted: TranscriptionLastCompleted?
    let jobs: [TranscriptionJob]
}

extension TranscriptionJobState {
    init(apiValue: String) {
        self = TranscriptionJobState(rawValue: apiValue) ?? .queued
    }
}
