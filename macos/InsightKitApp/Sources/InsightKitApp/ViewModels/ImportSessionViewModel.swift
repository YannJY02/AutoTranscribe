import AppKit
import Combine
import Foundation

/// Simplified ViewModel for the import transcription workflow.
/// Manages single-file import: selecting → processing → reviewing.
final class ImportSessionViewModel: ObservableObject {
    @Published var sessionPhase: SessionPhase = .selecting
    @Published var chapters: [ChapterSummary] = []
    @Published var smartMinutesData: SmartMinutes?
    @Published var notes: [TimestampedNote] = []
    @Published var currentPlaybackTime: TimeInterval?
    @Published var transcriptEntries: [TranscriptEntry] = []
    @Published var recordingDuration: TimeInterval = 0
    @Published var mediaURL: URL?
    @Published var importProgress: Double = 0
    @Published var importElapsed: TimeInterval = 0
    @Published var errorMessage: String?

    private let rpcClient: InsightRPCClientProtocol
    private let sidecarManager: SidecarManager
    private let rpcQueue = DispatchQueue(label: "InsightKit.ImportSession.RPC", qos: .userInitiated)
    private let fetchLock = NSLock()
    private var fetchInFlight = false
    private var currentMeetingID: String?
    private var pollTask: Task<Void, Never>?
    private var importStartTime: Date?

    // Phase 5: injected by WorkflowCoordinator
    var recordsService: RecordsIndexService?

    init(
        rpcClient: InsightRPCClientProtocol = InsightRPCClient(),
        sidecarManager: SidecarManager = SidecarManager()
    ) {
        self.rpcClient = rpcClient
        self.sidecarManager = sidecarManager
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Import Flow

    func importFile(url: URL) {
        mediaURL = url
        sessionPhase = .processing
        importProgress = 0
        importElapsed = 0
        importStartTime = Date()
        errorMessage = nil

        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.sidecarManager.startIfNeeded(ensureReady: { [weak self] in
                    guard let self else { return }
                    _ = try self.rpcClient.ensureReady(timeoutSec: 6)
                })
                let title = url.deletingPathExtension().lastPathComponent
                _ = try self.rpcClient.transcriptionImport(filePath: url.path, title: title)
                self.startPolling()
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.sessionPhase = .selecting
                }
            }
        }
    }

    func saveNotesToRecord() {
        guard let meetingID = currentMeetingID, let service = recordsService else { return }
        let notesURL = service.rootDirectory
            .appendingPathComponent(meetingID)
            .appendingPathComponent("notes.md")
        NotesFileIO.write(notes, to: notesURL)
    }

    func resetToSelecting() {
        pollTask?.cancel()
        pollTask = nil
        sessionPhase = .selecting
        chapters = []
        smartMinutesData = nil
        notes = []
        currentPlaybackTime = nil
        transcriptEntries = []
        recordingDuration = 0
        mediaURL = nil
        importProgress = 0
        importElapsed = 0
        errorMessage = nil
        currentMeetingID = nil
        recordsService?.refreshIndex()
    }

    func buildFinalInsight() {
        guard let meetingID = currentMeetingID else { return }
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.rpcClient.buildFinal(meetingID: meetingID)
                DispatchQueue.main.async {
                    self.applyInsightResult(result)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func exportDocument(format: String = "markdown") {
        guard let meetingID = currentMeetingID else { return }
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.rpcClient.documentExport(meetingID: meetingID, format: format, outputDir: "txt")
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func revealInFinder() {
        guard let url = mediaURL else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { break }
                self.fetchStatus()
            }
        }
    }

    private func fetchStatus() {
        fetchLock.lock()
        guard !fetchInFlight else {
            fetchLock.unlock()
            return
        }
        fetchInFlight = true
        fetchLock.unlock()

        rpcQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.fetchLock.lock()
                self.fetchInFlight = false
                self.fetchLock.unlock()
            }
            do {
                let status = try self.rpcClient.transcriptionStatus(limit: 10)
                DispatchQueue.main.async {
                    self.applyStatus(status)
                }
            } catch {
                // Polling failure — silently retry
            }
        }
    }

    private func applyStatus(_ status: TranscriptionStatusResult) {
        // Find the most recent job
        guard let job = status.jobs.first else { return }

        currentMeetingID = job.meetingID

        // Update progress
        if let startTime = importStartTime {
            importElapsed = Date().timeIntervalSince(startTime)
        }
        importProgress = Double(job.progress) / 100.0

        // Check completion
        if job.state == .completed {
            pollTask?.cancel()
            pollTask = nil
            sessionPhase = .reviewing
            // Load transcript and insight on rpcQueue, update UI on main
            let meetingID = job.meetingID
            rpcQueue.async { [weak self] in
                guard let self else { return }
                // Load transcript segments
                let segments = (try? self.rpcClient.transcriptList(meetingID: meetingID, limit: 2000)) ?? []
                // Load insight (build_final may already be done by RecordWriter)
                let insightResult = try? self.rpcClient.buildFinal(meetingID: meetingID)
                DispatchQueue.main.async {
                    self.transcriptEntries = segments.map { seg in
                        TranscriptEntry(
                            timestamp: TimeInterval(seg.startMs) / 1000.0,
                            speaker: seg.speaker,
                            text: seg.text
                        )
                    }
                    if let result = insightResult {
                        self.applyInsightResult(result)
                    }
                    self.recordsService?.refreshIndex()
                }
            }
        } else if job.state == .failed {
            pollTask?.cancel()
            pollTask = nil
            errorMessage = "转写失败：\(job.error.isEmpty ? "未知错误" : job.error)"
            sessionPhase = .selecting
        }
    }

    private func applyInsightResult(_ result: InsightRefreshResult) {
        let pkg = result.package

        // Extract chapters from timeline beats
        var extractedChapters: [ChapterSummary] = []
        for beat in pkg.timelineBeats {
            extractedChapters.append(ChapterSummary(
                timestamp: 0,
                title: beat.title,
                summary: beat.summary
            ))
        }
        chapters = extractedChapters

        // Build smart minutes from package
        let highlights = pkg.highlightInsights.map { $0.quote }
        let keyDecisions = pkg.decisionLedger.map { $0.decision }
        let actionItems = pkg.actionTracks.map { $0.task }

        smartMinutesData = SmartMinutes(
            structuredSummary: pkg.sessionOverview.overview,
            highlights: highlights,
            keyDecisions: keyDecisions,
            actionItems: actionItems,
            chapters: extractedChapters
        )
    }
}

// MARK: - ChapterSidebarDataSource

extension ImportSessionViewModel: ChapterSidebarDataSource {
    var smartMinutes: SmartMinutes? { smartMinutesData }

    var canGenerateMinutes: Bool {
        sessionPhase == .reviewing && currentMeetingID != nil
    }

    func onChapterTapped(_ chapter: ChapterSummary) {
        currentPlaybackTime = chapter.timestamp
    }

    func onGenerateMinutes() {
        buildFinalInsight()
    }
}

// MARK: - CenterStageDataSource

extension ImportSessionViewModel: CenterStageDataSource {
    var phase: SessionPhase { sessionPhase }
    var capturePreview: (any CapturePreviewProvider)? { nil }

    func onStartRecording() { /* Not applicable for import */ }
    func onStopRecording() { /* Not applicable for import */ }
    func onPauseRecording() { /* Not applicable for import */ }

    func onTranscriptEntryTapped(_ entry: TranscriptEntry) {
        currentPlaybackTime = entry.timestamp
    }

    func onSeek(to time: TimeInterval) {
        currentPlaybackTime = time
    }

    func onSkipMinutes() {
        sessionPhase = .reviewing
    }
}

// MARK: - NotesEditorDataSource

extension ImportSessionViewModel: NotesEditorDataSource {
    var isEditable: Bool {
        sessionPhase == .processing || sessionPhase == .reviewing
    }

    var recordingTime: TimeInterval { 0 }

    func onNoteCreated(_ text: String, at time: TimeInterval) {
        let note = TimestampedNote(text: text, timestamp: time)
        notes.append(note)
    }

    func onNoteUpdated(_ note: TimestampedNote) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[idx] = note
    }

    func onNoteTapped(_ note: TimestampedNote) {
        currentPlaybackTime = note.timestamp
    }
}
