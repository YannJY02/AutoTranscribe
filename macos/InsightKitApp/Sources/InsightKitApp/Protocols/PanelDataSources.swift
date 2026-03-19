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
    var capturePreview: (any CapturePreviewProvider)? { get }
    var transcriptEntries: [TranscriptEntry] { get }
    var recordingDuration: TimeInterval { get }
    var mediaURL: URL? { get }
    func onStartRecording()
    func onStopRecording()
    func onPauseRecording()
    func onTranscriptEntryTapped(_ entry: TranscriptEntry)
    func onSeek(to time: TimeInterval)
    func onGenerateMinutes()
    func onSkipMinutes()
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
