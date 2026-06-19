import AppKit
import Foundation

/// Adapter that loads a record folder and provides data for the three-panel review.
final class RecordReviewDataSource: ObservableObject {
    @Published var sessionPhase: SessionPhase = .reviewing
    @Published var chapters: [ChapterSummary] = []
    @Published var smartMinutesData: SmartMinutes?
    @Published var notes: [TimestampedNote] = []
    @Published var currentPlaybackTime: TimeInterval?
    @Published var mediaSeekRequest: MediaSeekRequest?
    @Published var transcriptEntries: [TranscriptEntry] = []
    @Published var recordingDuration: TimeInterval = 0
    @Published var mediaURL: URL?
    @Published var mediaStatusMessage: String?
    @Published var seekStatusMessage: String?
    @Published var exportStatusMessage: String?
    @Published var lastExportURL: URL?

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
                mediaStatusMessage = nil
                return
            }
        }
        mediaURL = nil
        mediaStatusMessage = "媒体文件缺失：无法回放原始记录。请在 Finder 检查 \(recordPath.lastPathComponent) 中的 recording.* 文件。"
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
        let timeline = (dict["timeline_beats"] as? [[String: Any]]) ?? []

        if !summary.isEmpty {
            let loadedChapters = timeline.compactMap { item -> ChapterSummary? in
                let title = (item["title"] as? String) ?? ""
                let body = (item["summary"] as? String) ?? ""
                if title.isEmpty && body.isEmpty { return nil }
                return ChapterSummary(
                    timestamp: TimestampNormalizer.normalize((item["timestamp"] as? String) ?? "", duration: metadata.duration),
                    title: title.isEmpty ? body : title,
                    summary: body
                )
            }
            chapters = loadedChapters
            smartMinutesData = SmartMinutes(
                structuredSummary: summary,
                highlights: highlights,
                speakerSummaries: Self.speakerSummaries(from: transcriptEntries),
                keyDecisions: keyDecisions,
                actionItems: actionItems,
                chapters: loadedChapters
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

    func exportRecord(format: String) {
        do {
            let url = try RecordDocumentExporter.export(format: format, metadata: metadata, recordPath: recordPath)
            lastExportURL = url
            exportStatusMessage = "已导出 \(url.lastPathComponent)"
        } catch {
            exportStatusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func updatePlaybackTime(_ time: TimeInterval) {
        guard time.isFinite else { return }
        let normalized = max(0, time)
        if let currentPlaybackTime, abs(currentPlaybackTime - normalized) < 0.25 {
            return
        }
        currentPlaybackTime = normalized
    }

    private static func speakerSummaries(from entries: [TranscriptEntry]) -> [SpeakerMinutesSummary] {
        let grouped = Dictionary(grouping: entries) { entry in
            let speaker = entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return speaker.isEmpty ? "未标注" : speaker
        }
        return grouped.keys.sorted().map { speaker in
            let speakerEntries = grouped[speaker] ?? []
            let latest = speakerEntries.map(\.timestamp).max() ?? 0
            return SpeakerMinutesSummary(
                speakerName: speaker,
                summary: "\(speakerEntries.count) 条发言，最晚发言时间 \(formatTimestamp(latest))。"
            )
        }
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - ChapterSidebarDataSource

extension RecordReviewDataSource: ChapterSidebarDataSource {
    var smartMinutes: SmartMinutes? { smartMinutesData }

    var canGenerateMinutes: Bool {
        smartMinutesData == nil
    }

    func onChapterTapped(_ chapter: ChapterSummary) {
        requestMediaSeek(to: chapter.timestamp, source: "章节", detail: chapter.title)
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
                speakerSummaries: pkg.speakerPerspectives.map {
                    SpeakerMinutesSummary(
                        speakerName: $0.speaker,
                        summary: $0.viewpoints.joined(separator: "；")
                    )
                },
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
        let speaker = entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        requestMediaSeek(to: entry.timestamp, source: "逐字稿", detail: speaker.isEmpty ? entry.text : speaker)
    }

    func onSeek(to time: TimeInterval) {
        requestMediaSeek(to: time, source: "播放器", detail: "")
    }

    func onSkipMinutes() {}
}

// MARK: - NotesEditorDataSource

extension RecordReviewDataSource: NotesEditorDataSource {
    var isEditable: Bool { true }

    var recordingTime: TimeInterval { currentPlaybackTime ?? 0 }

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
        requestMediaSeek(to: note.timestamp, source: "笔记", detail: note.text)
    }

    private func requestMediaSeek(to time: TimeInterval, source: String, detail: String) {
        let normalized = max(0, time)
        let needsPlayerSeek = currentPlaybackTime.map { abs($0 - normalized) >= 0.25 } ?? true
        updatePlaybackTime(normalized)
        if needsPlayerSeek {
            mediaSeekRequest = MediaSeekRequest(time: normalized)
        }
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDetail.isEmpty {
            seekStatusMessage = "已跳转到 \(Self.formatTimestamp(normalized)) · \(source)"
        } else {
            seekStatusMessage = "已跳转到 \(Self.formatTimestamp(normalized)) · \(source)：\(trimmedDetail)"
        }
    }
}
