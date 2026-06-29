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
    @Published var assetStatusMessage: String?
    @Published var transcriptRecoveryStatusMessage: String?
    @Published var assetHealth: MeetingAssetHealth = .empty
    @Published var lastExportURL: URL?

    let metadata: RecordMetadata
    let recordPath: URL
    private let rpcQueue = DispatchQueue(label: "InsightKit.RecordReview.RPC", qos: .userInitiated)
    private let rpcClient: InsightRPCClientProtocol?
    private let transcriptRecoveryService: TranscriptRecoveryServicing?

    init(
        metadata: RecordMetadata,
        rootDirectory: URL,
        recordPath: URL? = nil,
        rpcClient: InsightRPCClientProtocol? = nil,
        transcriptRecoveryService: TranscriptRecoveryServicing? = nil
    ) {
        self.metadata = metadata
        self.rpcClient = rpcClient
        self.transcriptRecoveryService = transcriptRecoveryService
            ?? rpcClient.map { TranscriptRecoveryService(rpcClient: $0) }
        self.recordPath = recordPath
            ?? RecordsIndexService.recordFolderURL(for: metadata.id, rootDirectory: rootDirectory)
            ?? rootDirectory.appendingPathComponent(metadata.id)
        self.recordingDuration = metadata.duration
        loadMeetingAsset()
    }

    // MARK: - Loading

    private func loadMeetingAsset() {
        let snapshot = MeetingAssetSnapshot.load(recordPath: recordPath, duration: metadata.duration)
        mediaURL = snapshot.mediaURL
        mediaStatusMessage = snapshot.mediaStatusMessage
        assetHealth = snapshot.health
        notes = snapshot.notes
        transcriptEntries = snapshot.transcriptEntries
        smartMinutesData = snapshot.smartMinutes
        chapters = snapshot.chapters
    }

    // MARK: - Save Notes

    func saveNotes() {
        _ = persistNotes(notes)
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

    var editableSpeakers: [String] {
        let labels = transcriptEntries.map { entry in
            Self.normalizedSpeakerLabel(entry.speaker)
        }
        return Array(Set(labels)).sorted()
    }

    func renameSpeaker(from oldLabel: String, to newLabel: String) {
        do {
            let changed = try MeetingAssetSnapshot.renameSpeaker(in: recordPath, from: oldLabel, to: newLabel)
            guard changed else { return }
            assetStatusMessage = nil
            reloadTranscriptAndMinutes()
        } catch {
            assetStatusMessage = "说话人重命名失败：\(error.localizedDescription)"
        }
    }

    var canRecoverTranscript: Bool {
        assetHealth.canRecoverTranscript && transcriptRecoveryService != nil
    }

    func recoverTranscript() {
        guard let transcriptRecoveryService else { return }
        transcriptRecoveryStatusMessage = "正在从已保存媒体恢复逐字稿。"
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try transcriptRecoveryService.recoverTranscript(
                    recordPath: self.recordPath,
                    duration: self.metadata.duration
                )
                DispatchQueue.main.async {
                    self.loadMeetingAsset()
                    self.transcriptRecoveryStatusMessage = result.smartMinutesMayNeedRegeneration
                        ? "逐字稿已恢复；现有智能纪要仍保留，但可能需要重新生成以匹配新逐字稿。"
                        : "逐字稿已恢复。"
                }
            } catch {
                DispatchQueue.main.async {
                    self.transcriptRecoveryStatusMessage = "逐字稿恢复失败：\(error.localizedDescription)"
                }
            }
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

    private func reloadTranscriptAndMinutes() {
        loadMeetingAsset()
    }

    private func persistNotes(_ nextNotes: [TimestampedNote]) -> Bool {
        do {
            try MeetingAssetSnapshot.writeNotes(nextNotes, to: recordPath)
            assetStatusMessage = nil
            assetHealth = MeetingAssetSnapshot.load(recordPath: recordPath, duration: metadata.duration).health
            return true
        } catch {
            assetStatusMessage = "笔记保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private static func normalizedSpeakerLabel(_ speaker: String?) -> String {
        let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "未标注" : trimmed
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
        assetHealth.canGenerateSmartMinutes
    }

    func onChapterTapped(_ chapter: ChapterSummary) {
        requestMediaSeek(to: chapter.timestamp, source: "章节", detail: chapter.title)
    }

    func onGenerateMinutes() {
        guard let client = rpcClient else { return }
        let meetingID = metadata.id
        rpcQueue.async { [weak self] in
            guard let self else { return }
            guard let result = try? client.buildFinal(meetingID: meetingID) else { return }
            let pkg = result.package
            do {
                try MeetingAssetSnapshot.writeInsightPackage(pkg, to: self.recordPath)
            } catch {
                DispatchQueue.main.async {
                    self.assetStatusMessage = "Smart Minutes 保存失败：\(error.localizedDescription)"
                }
                return
            }
            let snapshot = MeetingAssetSnapshot.load(recordPath: self.recordPath, duration: self.metadata.duration)
            DispatchQueue.main.async {
                self.smartMinutesData = snapshot.smartMinutes
                self.chapters = snapshot.chapters
                self.assetHealth = snapshot.health
                self.assetStatusMessage = nil
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
        let previous = notes
        notes.append(note)
        if !persistNotes(notes) {
            notes = previous
        }
    }

    func onNoteUpdated(_ note: TimestampedNote) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let previous = notes
        notes[idx] = note
        if !persistNotes(notes) {
            notes = previous
        }
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
