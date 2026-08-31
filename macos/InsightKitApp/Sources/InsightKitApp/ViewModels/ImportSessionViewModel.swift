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
    @Published var mediaSeekRequest: MediaSeekRequest?
    @Published var transcriptEntries: [TranscriptEntry] = []
    @Published var recordingDuration: TimeInterval = 0
    @Published var mediaURL: URL?
    @Published var importProgress: Double = 0
    @Published var importElapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var importStatusMessage: String?
    @Published var analysisStatusMessage: String?
    @Published var exportStatusMessage: String?
    @Published var lastExportURL: URL?
    @Published var currentJobID: String?

    private let rpcClient: InsightRPCClientProtocol
    private let sidecarManager: SidecarManager
    private let analyticsSubmit: (@escaping (ProductAnalytics) -> Void) -> Void
    private let rpcQueue = DispatchQueue(label: "InsightKit.ImportSession.RPC", qos: .userInitiated)
    private let fetchLock = NSLock()
    private var fetchInFlight = false
    private var currentMeetingID: String?
    private var pollTask: Task<Void, Never>?
    private var importStartTime: Date?

    // Phase 5: injected by WorkflowCoordinator
    var recordsService: RecordsIndexService?

    var visibleErrorStatusMessage: String? {
        let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }

    var visibleImportStatusMessage: String? {
        let message = importStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }

    var visibleAnalysisStatusMessage: String? {
        let message = analysisStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }

    var canCancelImport: Bool {
        sessionPhase == .processing && currentJobID != nil
    }

    init(
        rpcClient: InsightRPCClientProtocol = InsightRPCClient(),
        sidecarManager: SidecarManager = SidecarManager(),
        analyticsSubmit: @escaping (@escaping (ProductAnalytics) -> Void) -> Void = ProductAnalytics.submit
    ) {
        self.rpcClient = rpcClient
        self.sidecarManager = sidecarManager
        self.analyticsSubmit = analyticsSubmit
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        sidecarManager.stop()
    }

    // MARK: - Import Flow

    func importFile(url: URL) {
        mediaURL = url
        sessionPhase = .processing
        importProgress = 0
        importElapsed = 0
        importStartTime = Date()
        errorMessage = nil
        importStatusMessage = "正在提交导入任务…"
        analysisStatusMessage = nil
        currentJobID = nil
        let provisionalAnalyticsPath = ProductAnalyticsPath.provisional(
            analysisMode: AppConfigStore.shared.config.analysis.mode
        )
        analyticsSubmit { $0.beginWorkflow("import", provisionalPath: provisionalAnalyticsPath) }

        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.sidecarManager.startIfNeeded(ensureReady: { [weak self] in
                    guard let self else { return }
                    _ = try self.rpcClient.ensureReady(timeoutSec: 6)
                })
                let analyticsPath = self.refreshAnalysisStatusForImport()
                self.analyticsSubmit { $0.resolveWorkflow("import", path: analyticsPath) }
                let title = url.deletingPathExtension().lastPathComponent
                let result = try self.rpcClient.transcriptionImport(filePath: url.path, title: title)
                DispatchQueue.main.async {
                    self.currentJobID = result.jobID
                    self.currentMeetingID = result.meetingID
                    self.importStatusMessage = "已加入转写队列，等待开始…"
                    self.startPolling()
                    self.fetchStatus()
                }
            } catch {
                self.analyticsSubmit {
                    $0.workflowFailed(
                        "import",
                        phase: "preparing",
                        errorCode: "runtime-unavailable",
                        recoveryAction: "retry"
                    )
                }
                DispatchQueue.main.async {
                    self.currentJobID = nil
                    self.importStatusMessage = nil
                    self.errorMessage = error.localizedDescription
                    self.sessionPhase = .selecting
                }
            }
        }
    }

    func cancelImport(reason: String = "cancelled_by_user") {
        guard let jobID = currentJobID else {
            resetToSelecting()
            importStatusMessage = "导入启动已取消。你可以重新选择文件。"
            return
        }

        importStatusMessage = "正在取消导入…"
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.rpcClient.transcriptionCancel(jobID: jobID, reason: reason)
                DispatchQueue.main.async {
                    let message: String
                    if result.state == .pausedByLive {
                        message = "导入已暂停，以优先处理实时录制。你可以稍后重新导入或在转写队列中查看。"
                    } else {
                        message = "导入已取消。你可以重新选择文件。"
                    }
                    self.resetToSelecting()
                    self.importStatusMessage = message
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "取消导入失败：\(error.localizedDescription)"
                    self.importStatusMessage = "取消失败，转写任务可能仍在运行。"
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
        let analyticsPhase = sessionPhase == .reviewing ? "reviewing" : "running"
        analyticsSubmit { $0.workflowCancelled("import", phase: analyticsPhase) }
        pollTask?.cancel()
        pollTask = nil
        sessionPhase = .selecting
        chapters = []
        smartMinutesData = nil
        notes = []
        currentPlaybackTime = nil
        mediaSeekRequest = nil
        transcriptEntries = []
        recordingDuration = 0
        mediaURL = nil
        importProgress = 0
        importElapsed = 0
        errorMessage = nil
        importStatusMessage = nil
        analysisStatusMessage = nil
        exportStatusMessage = nil
        lastExportURL = nil
        currentJobID = nil
        currentMeetingID = nil
        recordsService?.refreshIndex()
    }

    func buildFinalInsight() {
        guard let meetingID = currentMeetingID else { return }
        sessionPhase = .processing
        rpcQueue.async { [weak self] in
            guard let self else { return }
            self.analyticsSubmit { $0.recoveryAttempted("import", phase: "analysis") }
            let analysisStartedAt = DispatchTime.now().uptimeNanoseconds
            do {
                let result = try self.rpcClient.buildFinal(meetingID: meetingID)
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - analysisStartedAt) / 1_000_000)
                DispatchQueue.main.async {
                    self.applyInsightResult(result, analyticsLatencyMilliseconds: analysisLatencyMS)
                    self.sessionPhase = .reviewing
                }
                self.analyticsSubmit { $0.recoveryCompleted("import", phase: "analysis", succeeded: true) }
            } catch {
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - analysisStartedAt) / 1_000_000)
                self.analyticsSubmit {
                    $0.workflowFailed(
                        "import",
                        phase: "analysis",
                        errorCode: "unknown",
                        recoveryAction: "retry",
                        analysisLatencyMilliseconds: analysisLatencyMS
                    )
                }
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.sessionPhase = .reviewing
                }
            }
        }
    }

    func exportDocument(format: String = "markdown") {
        guard let meetingID = currentMeetingID else { return }
        analyticsSubmit { $0.exportAttempted("import") }
        do {
            if try exportPersistedRecord(format: format, meetingID: meetingID) {
                let recordPath = persistedRecordPath(for: meetingID)
                let duration = recordingDuration
                let hasBlockingError = errorMessage != nil
                analyticsSubmit { analytics in
                    analytics.exportCompleted("import")
                    analytics.workflowCompleted("import", evaluation: .evaluate(recordPath: recordPath, duration: duration, exportCompleted: true, hasBlockingError: hasBlockingError))
                }
                return
            }
        } catch {
            exportStatusMessage = "导出失败：\(error.localizedDescription)"
            analyticsSubmit {
                $0.workflowFailed("import", phase: "exporting", errorCode: "unknown", recoveryAction: "retry")
            }
            return
        }
        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.rpcClient.documentExport(meetingID: meetingID, format: format, outputDir: "")
                DispatchQueue.main.async {
                    self.exportStatusMessage = "已导出 \(URL(fileURLWithPath: result.path).lastPathComponent)"
                    self.lastExportURL = URL(fileURLWithPath: result.path)
                    let recordPath = self.persistedRecordPath(for: meetingID)
                    let duration = self.recordingDuration
                    let hasBlockingError = self.errorMessage != nil
                    self.analyticsSubmit { analytics in
                        analytics.exportCompleted("import")
                        analytics.workflowCompleted("import", evaluation: .evaluate(recordPath: recordPath, duration: duration, exportCompleted: true, hasBlockingError: hasBlockingError))
                    }
                }
            } catch {
                self.analyticsSubmit { analytics in
                    analytics.workflowFailed("import", phase: "exporting", errorCode: "unknown", recoveryAction: "retry")
                }
                DispatchQueue.main.async {
                    self.exportStatusMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func revealInFinder() {
        if let meetingID = currentMeetingID,
           let recordPath = persistedRecordPath(for: meetingID) {
            NSWorkspace.shared.selectFile(recordPath.path, inFileViewerRootedAtPath: recordPath.deletingLastPathComponent().path)
            return
        }
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
        guard let job = selectedJob(from: status) else { return }

        currentMeetingID = job.meetingID
        currentJobID = job.id

        // Update progress
        if let startTime = importStartTime {
            importElapsed = Date().timeIntervalSince(startTime)
        }
        importProgress = Double(job.progress) / 100.0

        // Check completion
        if job.state == .completed {
            pollTask?.cancel()
            pollTask = nil
            currentJobID = nil
            importStatusMessage = nil
            loadCompletedArtifacts(meetingID: job.meetingID)
        } else if job.state == .failed {
            pollTask?.cancel()
            pollTask = nil
            currentJobID = nil
            importStatusMessage = nil
            errorMessage = "转写失败：\(job.error.isEmpty ? "未知错误" : job.error)"
            sessionPhase = .selecting
            analyticsSubmit { analytics in
                analytics.workflowFailed("import", phase: "running", errorCode: "runtime-unavailable", recoveryAction: "retry")
            }
        } else if job.state == .cancelled || job.state == .pausedByLive {
            let message = job.state == .pausedByLive
                ? "导入已暂停，以优先处理实时录制。你可以稍后重新导入或在转写队列中查看。"
                : "导入已取消。你可以重新选择文件。"
            resetToSelecting()
            importStatusMessage = message
        } else {
            importStatusMessage = Self.importStatusMessage(for: job)
        }
    }

    private func applyInsightResult(_ result: InsightRefreshResult, analyticsLatencyMilliseconds: Int? = nil) {
        errorMessage = nil
        applyInsightPackage(result.package)
        analyticsSubmit { analytics in
            analytics.resolveWorkflow(
                "import",
                path: ProductAnalyticsPath(provider: result.provider),
                analysisLatencyMilliseconds: analyticsLatencyMilliseconds
            )
            analytics.recordSaved("import", path: ProductAnalyticsPath(provider: result.provider))
            analytics.reviewOpened("import")
        }
    }

    func applyAnalysisProvidersStatusForImport(_ providers: AnalysisProvidersStatus) {
        analysisStatusMessage = providers.activeReady ? nil : Self.analysisFallbackMessage(for: providers)
    }

    func refreshAnalysisStatusForImport(
        analysisMode: AnalysisMode = AppConfigStore.shared.config.analysis.mode
    ) -> ProductAnalyticsPath {
        if analysisMode == .local {
            DispatchQueue.main.async {
                self.analysisStatusMessage = nil
            }
            return .local
        }
        do {
            let providers = try rpcClient.providersStatus(probeActive: false)
            DispatchQueue.main.async {
                self.applyAnalysisProvidersStatusForImport(providers)
            }
            return ProductAnalyticsPath(providers: providers)
        } catch {
            let message: String
            if Self.isProviderProbeTimeout(error) {
                message = "智能分析探测超时，转写继续；定稿将使用本地提取草稿。"
            } else {
                message = "智能分析状态暂不可用，转写继续；定稿将使用本地提取草稿。"
            }
            DispatchQueue.main.async {
                self.analysisStatusMessage = message
            }
            return .unavailable
        }
    }

    private func applyInsightPackage(_ pkg: InsightPackageV1) {
        let extractedChapters = pkg.timelineBeats.map {
            ChapterSummary(
                timestamp: TimestampNormalizer.normalize($0.timestamp, duration: recordingDuration),
                title: $0.title,
                summary: $0.summary
            )
        }
        chapters = extractedChapters

        smartMinutesData = SmartMinutes(
            structuredSummary: pkg.sessionOverview.overview,
            highlights: pkg.highlightInsights.map(\.quote),
            speakerSummaries: pkg.speakerPerspectives.map {
                SpeakerMinutesSummary(
                    speakerName: $0.speaker,
                    summary: $0.viewpoints.joined(separator: "；")
                )
            },
            keyDecisions: pkg.decisionLedger.map(\.decision),
            actionItems: pkg.actionTracks.map(\.task),
            chapters: extractedChapters
        )
    }

    private func selectedJob(from status: TranscriptionStatusResult) -> TranscriptionJob? {
        if let currentMeetingID {
            if let job = status.jobs.first(where: { $0.meetingID == currentMeetingID }) {
                return job
            }
            if let activeJob = status.activeJob, activeJob.meetingID == currentMeetingID {
                return activeJob
            }
            if let lastCompleted = status.lastCompleted, lastCompleted.meetingID == currentMeetingID {
                return lastCompleted.job
            }
        }

        return status.activeJob ?? status.jobs.first ?? status.lastCompleted?.job
    }

    func loadCompletedArtifacts(meetingID: String) {
        rpcQueue.async { [weak self] in
            guard let self else { return }
            let segments = (try? self.rpcClient.transcriptList(meetingID: meetingID, limit: 2000)) ?? []
            DispatchQueue.main.async {
                if !segments.isEmpty {
                    self.transcriptEntries = Self.transcriptEntries(from: segments)
                }
                let loadedFromRecord = self.loadPersistedArtifactsForCompletedImport(meetingID: meetingID)
                if let recordPath = self.persistedRecordPath(for: meetingID) {
                    self.analyticsSubmit { analytics in
                        analytics.recordSaved(
                            "import",
                            path: ProductAnalyticsPath.persistedRecord(at: recordPath)
                        )
                        analytics.reviewOpened("import")
                    }
                }
                if !self.notes.isEmpty {
                    self.saveNotesToRecord()
                }
                if self.transcriptEntries.isEmpty && !loadedFromRecord {
                    self.errorMessage = "转写已完成，但未能加载逐字稿。请在记录列表中打开该会议或检查本地记录文件。"
                }
                self.recordsService?.refreshIndex()
            }

            self.analyticsSubmit { $0.recoveryAttempted("import", phase: "analysis") }
            let analysisStartedAt = DispatchTime.now().uptimeNanoseconds
            do {
                let insightResult = try self.rpcClient.buildFinal(meetingID: meetingID)
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - analysisStartedAt) / 1_000_000)
                DispatchQueue.main.async {
                    self.applyInsightResult(insightResult, analyticsLatencyMilliseconds: analysisLatencyMS)
                    self.recordsService?.refreshIndex()
                    self.sessionPhase = .reviewing
                }
                self.analyticsSubmit { $0.recoveryCompleted("import", phase: "analysis", succeeded: true) }
            } catch {
                let analysisLatencyMS = Int((DispatchTime.now().uptimeNanoseconds - analysisStartedAt) / 1_000_000)
                self.analyticsSubmit {
                    $0.workflowFailed(
                        "import",
                        phase: "analysis",
                        errorCode: "unknown",
                        recoveryAction: "retry",
                        analysisLatencyMilliseconds: analysisLatencyMS
                    )
                }
                DispatchQueue.main.async {
                    self.errorMessage = "智能纪要生成失败：\(error.localizedDescription)"
                    self.sessionPhase = .reviewing
                }
            }
        }
    }

    @discardableResult
    func loadPersistedArtifactsForCompletedImport(meetingID: String) -> Bool {
        guard let recordPath = persistedRecordPath(for: meetingID) else { return false }

        currentMeetingID = meetingID
        var loaded = false
        if let metadata = loadMetadata(from: recordPath) {
            recordingDuration = metadata.duration
            loaded = true
        }

        if let persistedMedia = MeetingAssetSnapshot.canonicalMediaURL(in: recordPath) {
            mediaURL = persistedMedia
            loaded = true
        }

        let loadedNotes = NotesFileIO.read(from: recordPath.appendingPathComponent("notes.md"))
        if !loadedNotes.isEmpty {
            notes = loadedNotes
            loaded = true
        }

        if transcriptEntries.isEmpty, let entries = loadTranscriptEntries(from: recordPath) {
            transcriptEntries = entries
            loaded = true
        }

        if smartMinutesData == nil {
            if let package = loadInsightPackage(from: recordPath) {
                applyInsightPackage(package)
                loaded = true
            } else if let minutes = loadMinutes(from: recordPath) {
                smartMinutesData = minutes
                chapters = minutes.chapters
                loaded = true
            }
        }

        return loaded
    }

    private func exportPersistedRecord(format: String, meetingID: String) throws -> Bool {
        guard persistedRecordPath(for: meetingID) != nil else {
            return false
        }

        if !notes.isEmpty {
            saveNotesToRecord()
        }
        let url = try RecordDocumentExporter.exportIfPersistedRecordExists(
            format: format,
            meetingID: meetingID,
            recordsService: recordsService
        )
        guard let url else { return false }
        lastExportURL = url
        exportStatusMessage = "已导出 \(url.lastPathComponent)"
        return true
    }

    private func persistedRecordPath(for meetingID: String) -> URL? {
        recordsService?.recordFolderURL(for: meetingID)
    }

    private func loadMetadata(from recordPath: URL) -> RecordMetadata? {
        let url = recordPath.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordMetadata.self, from: data)
    }

    private func loadTranscriptEntries(from recordPath: URL) -> [TranscriptEntry]? {
        let url = recordPath.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let entries = rows.compactMap { row -> TranscriptEntry? in
            guard let text = row["text"] as? String, !text.isEmpty else { return nil }
            let startMs = (row["start_ms"] as? Int) ?? 0
            return TranscriptEntry(
                timestamp: TimeInterval(startMs) / 1000.0,
                speaker: row["speaker"] as? String,
                text: text
            )
        }
        return entries.isEmpty ? nil : entries
    }

    private func loadInsightPackage(from recordPath: URL) -> InsightPackageV1? {
        let url = recordPath.appendingPathComponent("insight_package.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InsightPackageV1.self, from: data)
    }

    private func loadMinutes(from recordPath: URL) -> SmartMinutes? {
        let url = recordPath.appendingPathComponent("minutes.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let summary = (dict["structured_summary"] as? String) ?? ""
        let highlights = (dict["highlights"] as? [String]) ?? []
        let keyDecisions = (dict["key_decisions"] as? [String]) ?? []
        let actionItems = (dict["action_items"] as? [String]) ?? []
        let timeline = (dict["timeline_beats"] as? [[String: Any]]) ?? []
        let loadedChapters = timeline.compactMap { item -> ChapterSummary? in
            let title = (item["title"] as? String) ?? ""
            let body = (item["summary"] as? String) ?? ""
            guard !title.isEmpty || !body.isEmpty else { return nil }
            return ChapterSummary(
                timestamp: TimestampNormalizer.normalize((item["timestamp"] as? String) ?? "", duration: recordingDuration),
                title: title.isEmpty ? body : title,
                summary: body
            )
        }

        guard !summary.isEmpty || !highlights.isEmpty || !keyDecisions.isEmpty || !actionItems.isEmpty || !loadedChapters.isEmpty else {
            return nil
        }
        return SmartMinutes(
            structuredSummary: summary,
            highlights: highlights,
            keyDecisions: keyDecisions,
            actionItems: actionItems,
            chapters: loadedChapters
        )
    }

    private static func transcriptEntries(from segments: [TranscriptSegment]) -> [TranscriptEntry] {
        segments.map { segment in
            TranscriptEntry(
                timestamp: TimeInterval(segment.startMs) / 1000.0,
                speaker: segment.speaker,
                text: segment.text
            )
        }
    }

    private static func importStatusMessage(for job: TranscriptionJob) -> String {
        let progress = max(0, min(100, job.progress))
        let stage = userVisibleStage(job.stage, state: job.state)
        return "\(stage) · \(progress)%"
    }

    private static func userVisibleStage(_ rawStage: String, state: TranscriptionJobState) -> String {
        let stage = rawStage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch stage {
        case "queued":
            return "等待转写队列"
        case "starting":
            return "准备本地转写"
        case "transcribing":
            return "正在生成逐字稿"
        case "persisting":
            return "正在保存会议资产"
        case "building_final":
            return "正在生成智能纪要"
        default:
            switch state {
            case .queued:
                return "等待转写队列"
            case .running:
                return "正在处理导入"
            case .completed:
                return "导入已完成"
            case .failed:
                return "导入失败"
            case .pausedByLive:
                return "导入已暂停"
            case .cancelled:
                return "导入已取消"
            }
        }
    }

    private static func analysisFallbackMessage(for providers: AnalysisProvidersStatus) -> String {
        let selected = providers.vendors.first { $0.vendor == providers.selectedVendor }
        let reason: String
        if selected?.hasAPIKey == false || providers.activeProbeErrorCode == .missingKey {
            reason = "缺少 API Key"
        } else if selected?.modelReady == false {
            reason = "模型未配置"
        } else if selected?.configured == false || providers.activeProbeErrorCode == .missingConfiguration {
            reason = "配置未完成"
        } else if !providers.activeProbeMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reason = providers.activeProbeMessage
        } else {
            reason = "服务暂不可用"
        }
        return "智能分析未配置（\(providers.selectedVendor.displayName)：\(reason)），转写继续；定稿将使用本地提取草稿。"
    }

    private static func isProviderProbeTimeout(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("调用超时: analysis.provider.probe")
            || lower.contains("调用超时: analysis.providers.status")
            || lower.contains("probe_timeout")
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
        mediaSeekRequest = MediaSeekRequest(time: chapter.timestamp)
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
        mediaSeekRequest = MediaSeekRequest(time: entry.timestamp)
    }

    func onSeek(to time: TimeInterval) {
        currentPlaybackTime = time
        mediaSeekRequest = MediaSeekRequest(time: time)
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

    var recordingTime: TimeInterval { currentPlaybackTime ?? 0 }

    func onNoteCreated(_ text: String, at time: TimeInterval) {
        let note = TimestampedNote(text: text, timestamp: time)
        notes.append(note)
        saveNotesToRecord()
    }

    func onNoteUpdated(_ note: TimestampedNote) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[idx] = note
        saveNotesToRecord()
    }

    func onNoteTapped(_ note: TimestampedNote) {
        currentPlaybackTime = note.timestamp
        mediaSeekRequest = MediaSeekRequest(time: note.timestamp)
    }
}
