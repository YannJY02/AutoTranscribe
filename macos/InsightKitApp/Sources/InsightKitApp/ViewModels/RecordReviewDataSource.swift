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
    private let rpcQueue = DispatchQueue(label: "InsightKit.RecordReview.RPC", qos: .userInitiated)
    private let rpcClient: InsightRPCClientProtocol?

    init(metadata: RecordMetadata, rootDirectory: URL, rpcClient: InsightRPCClientProtocol? = nil) {
        self.metadata = metadata
        self.rpcClient = rpcClient
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
        notes = NotesFileIO.read(from: notesFileURL)
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
        NotesFileIO.write(notes, to: notesFileURL)
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
        guard let client = rpcClient else { return }
        let meetingID = metadata.id
        let minutesURL = recordPath.appendingPathComponent("minutes.json")
        rpcQueue.async { [weak self] in
            guard let self else { return }
            guard let result = try? client.buildFinal(meetingID: meetingID) else { return }
            let pkg = result.package
            let highlights = pkg.highlightInsights.map { $0.quote }
            let keyDecisions = pkg.decisionLedger.map { $0.decision }
            let actionItems = pkg.actionTracks.map { $0.task }
            let minutesDict: [String: Any] = [
                "structured_summary": pkg.sessionOverview.overview,
                "highlights": highlights,
                "key_decisions": keyDecisions,
                "action_items": actionItems,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: minutesDict, options: .prettyPrinted) {
                try? data.write(to: minutesURL)
            }
            let chapters: [ChapterSummary] = pkg.timelineBeats.map {
                ChapterSummary(timestamp: 0, title: $0.title, summary: $0.summary)
            }
            let smartMinutes = SmartMinutes(
                structuredSummary: pkg.sessionOverview.overview,
                highlights: highlights,
                keyDecisions: keyDecisions,
                actionItems: actionItems,
                chapters: chapters
            )
            DispatchQueue.main.async {
                self.smartMinutesData = smartMinutes
                self.chapters = chapters
            }
        }
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

    func onSkipMinutes() {}
}

// MARK: - NotesEditorDataSource

extension RecordReviewDataSource: NotesEditorDataSource {
    var isEditable: Bool { true }

    var recordingTime: TimeInterval { 0 }

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
