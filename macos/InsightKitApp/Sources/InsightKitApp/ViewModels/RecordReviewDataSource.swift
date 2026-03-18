import AppKit
import Foundation

/// Adapter that loads a record folder and provides data for the three-panel review.
final class RecordReviewDataSource: ObservableObject {
    @Published var sessionPhase: SessionPhase = .reviewing
    @Published var chapters: [ChapterSummary] = []
    @Published var smartMinutesData: SmartMinutes?
    @Published var notes: [TimestampedNote] = []
    @Published var currentPlaybackTime: TimeInterval?
    @Published var transcriptEntries: [TranscriptEntry] = []
    @Published var recordingDuration: TimeInterval = 0
    @Published var mediaURL: URL?

    let metadata: RecordMetadata
    let recordPath: URL
    private let notesFileURL: URL

    init(metadata: RecordMetadata, rootDirectory: URL) {
        self.metadata = metadata
        self.recordPath = rootDirectory.appendingPathComponent(metadata.id)
        self.notesFileURL = recordPath.appendingPathComponent("notes.md")
        self.recordingDuration = metadata.duration
        loadMedia()
        loadNotes()
        loadTranscript()
        loadMinutes()
    }

    // MARK: - Loading

    private func loadMedia() {
        let extensions = ["mp4", "mov", "mkv", "m4a", "mp3", "wav"]
        for ext in extensions {
            let candidate = recordPath.appendingPathComponent("recording.\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                mediaURL = candidate
                return
            }
        }
    }

    private func loadNotes() {
        guard let content = try? String(contentsOf: notesFileURL, encoding: .utf8) else { return }
        // Parse simple format: each line is "MM:SS text"
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        notes = lines.compactMap { line in
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

    private func loadTranscript() {
        let transcriptURL = recordPath.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: transcriptURL) else { return }
        // Expect array of {start_ms, end_ms, speaker, text}
        guard let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        transcriptEntries = segments.compactMap { dict in
            guard let text = dict["text"] as? String else { return nil }
            let startMs = (dict["start_ms"] as? Int) ?? 0
            let speaker = dict["speaker"] as? String
            return TranscriptEntry(
                timestamp: TimeInterval(startMs) / 1000.0,
                speaker: speaker,
                text: text
            )
        }
    }

    private func loadMinutes() {
        let minutesURL = recordPath.appendingPathComponent("minutes.json")
        guard let data = try? Data(contentsOf: minutesURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let summary = (dict["structured_summary"] as? String) ?? ""
        let highlights = (dict["highlights"] as? [String]) ?? []
        let keyDecisions = (dict["key_decisions"] as? [String]) ?? []
        let actionItems = (dict["action_items"] as? [String]) ?? []

        if !summary.isEmpty {
            smartMinutesData = SmartMinutes(
                structuredSummary: summary,
                highlights: highlights,
                keyDecisions: keyDecisions,
                actionItems: actionItems
            )
        }
    }

    // MARK: - Save Notes

    func saveNotes() {
        let content = notes.map { note in
            let mins = Int(note.timestamp) / 60
            let secs = Int(note.timestamp) % 60
            return String(format: "%02d:%02d %@", mins, secs, note.text)
        }.joined(separator: "\n")
        try? content.write(to: notesFileURL, atomically: true, encoding: .utf8)
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(recordPath.path, inFileViewerRootedAtPath: recordPath.deletingLastPathComponent().path)
    }
}

// MARK: - ChapterSidebarDataSource

extension RecordReviewDataSource: ChapterSidebarDataSource {
    var smartMinutes: SmartMinutes? { smartMinutesData }

    var canGenerateMinutes: Bool {
        smartMinutesData == nil
    }

    func onChapterTapped(_ chapter: ChapterSummary) {
        currentPlaybackTime = chapter.timestamp
    }

    func onGenerateMinutes() {
        // Would call RPC to generate — placeholder
    }
}

// MARK: - CenterStageDataSource

extension RecordReviewDataSource: CenterStageDataSource {
    var phase: SessionPhase { .reviewing }
    var capturePreview: (any CapturePreviewProvider)? { nil }

    func onStartRecording() {}
    func onStopRecording() {}
    func onPauseRecording() {}

    func onTranscriptEntryTapped(_ entry: TranscriptEntry) {
        currentPlaybackTime = entry.timestamp
    }

    func onSeek(to time: TimeInterval) {
        currentPlaybackTime = time
    }
}

// MARK: - NotesEditorDataSource

extension RecordReviewDataSource: NotesEditorDataSource {
    var isEditable: Bool { true }

    func onNoteCreated(_ text: String, at time: TimeInterval) {
        let note = TimestampedNote(text: text, timestamp: time)
        notes.append(note)
        saveNotes()
    }

    func onNoteUpdated(_ note: TimestampedNote) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[idx] = note
        saveNotes()
    }

    func onNoteTapped(_ note: TimestampedNote) {
        currentPlaybackTime = note.timestamp
    }
}
