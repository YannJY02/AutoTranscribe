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
    func onStartRecording()
    func onStopRecording()
    func onPauseRecording()
    func onTranscriptEntryTapped(_ entry: TranscriptEntry)
    func onSeek(to time: TimeInterval)
    func onGenerateMinutes()
    func onSkipMinutes()
    func onExportDocument(format: String)
}

extension CenterStageDataSource {
    var mediaSeekRequest: MediaSeekRequest? { nil }
    var reviewSourcePlaybackRequested: Bool { false }
    var recordingStatusMessage: String? { nil }
    var liveProgressPresentation: LiveProgressPresentation? { nil }
    var capturePreviewStatusMessage: String? { nil }
    var canExportDocument: Bool { false }
    var lastExportPath: String { "" }
    var reviewSourceMediaURL: URL? { mediaURL }
    var reviewSourceStatusMessage: String? { nil }
    func onExportDocument(format: String) {}
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
