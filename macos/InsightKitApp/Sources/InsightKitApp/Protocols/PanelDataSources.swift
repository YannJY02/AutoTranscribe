import Combine
import Foundation

// MARK: - Chapter Sidebar

protocol ChapterSidebarDataSource: ObservableObject {
    var chapters: [ChapterSummary] { get }
    var smartMinutes: SmartMinutes? { get }
    var canGenerateMinutes: Bool { get }
    func onChapterTapped(_ chapter: ChapterSummary)
    func onGenerateMinutes()
}

// MARK: - Center Stage

protocol CenterStageDataSource: ObservableObject {
    var phase: SessionPhase { get }
    var smartMinutes: SmartMinutes? { get }
    var capturePreview: (any CapturePreviewProvider)? { get }
    var capturePreviewStatusMessage: String? { get }
    var transcriptEntries: [TranscriptEntry] { get }
    var recordingDuration: TimeInterval { get }
    var isRecordingPaused: Bool { get }
    var isFinalizingRecording: Bool { get }
    var recordingStatusMessage: String? { get }
    var liveProgressPresentation: LiveProgressPresentation? { get }
    var canExportDocument: Bool { get }
    var lastExportPath: String { get }
    var mediaURL: URL? { get }
    var reviewSourceMediaURL: URL? { get }
    var reviewSourceStatusMessage: String? { get }
    var currentPlaybackTime: TimeInterval? { get }
    var mediaSeekRequest: MediaSeekRequest? { get }
    var reviewSourcePlaybackRequested: Bool { get }
    var editableSpeakers: [String] { get }
    var canRecoverTranscript: Bool { get }
    var transcriptRecoveryStatusMessage: String? { get }
    func onStartRecording()
    func onStopRecording()
    func onPauseRecording()
    func onTranscriptEntryTapped(_ entry: TranscriptEntry)
    func onSeek(to time: TimeInterval)
    func onPlaybackTimeUpdated(_ time: TimeInterval)
    func onGenerateMinutes()
    func onSkipMinutes()
    func onExportDocument(format: String)
    func renameSpeaker(from oldLabel: String, to newLabel: String)
    func onRecoverTranscript()
}

extension CenterStageDataSource {
    var mediaSeekRequest: MediaSeekRequest? { nil }
    var reviewSourcePlaybackRequested: Bool { false }
    var isRecordingPaused: Bool { false }
    var isFinalizingRecording: Bool { false }
    var recordingStatusMessage: String? { nil }
    var liveProgressPresentation: LiveProgressPresentation? { nil }
    var capturePreviewStatusMessage: String? { nil }
    var canExportDocument: Bool { false }
    var lastExportPath: String { "" }
    var reviewSourceMediaURL: URL? { mediaURL }
    var reviewSourceStatusMessage: String? { nil }
    var editableSpeakers: [String] { [] }
    var canRecoverTranscript: Bool { false }
    var transcriptRecoveryStatusMessage: String? { nil }
    func onPlaybackTimeUpdated(_ time: TimeInterval) {}
    func onExportDocument(format: String) {}
    func renameSpeaker(from oldLabel: String, to newLabel: String) {}
    func onRecoverTranscript() {}
}

// MARK: - Notes Editor

protocol NotesEditorDataSource: ObservableObject {
    var notes: [TimestampedNote] { get }
    var currentPlaybackTime: TimeInterval? { get }
    var recordingTime: TimeInterval { get }
    var isEditable: Bool { get }
    func onNoteCreated(_ text: String, at time: TimeInterval)
    func onNoteUpdated(_ note: TimestampedNote)
    func onNoteTapped(_ note: TimestampedNote)
}
