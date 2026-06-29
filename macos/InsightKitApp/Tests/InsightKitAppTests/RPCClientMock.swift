import Foundation
@testable import InsightKitApp

final class RPCClientMock: InsightRPCClientProtocol {
    var cancelCalls: [(jobID: String, reason: String)] = []
    var documentExportCalls: [(meetingID: String, format: String, outputDir: String)] = []
    var watchStartCalls: [[String]] = []
    var watchStopCalls = 0
    var importCalls: [(path: String, title: String)] = []
    var asrTranscribeMediaCalls: [(mediaPath: String, source: String)] = []
    var asrTranscribeMediaStub: [RPCSegmentDelta] = []
    var asrTranscribeMediaQueue: [Result<[RPCSegmentDelta], Error>] = []
    var asrTranscribeMediaError: Error?
    var transcriptReplaceCalls: [(meetingID: String, segments: [RPCSegmentDelta])] = []
    var methodCalls: [String] = []
    var recordsSaveCalls: [(
        meetingID: String,
        title: String,
        sourcePath: String,
        insightPackage: [String: Any]?,
        mediaType: String,
        recordSource: String,
        durationSec: Double,
        analysisMeta: [String: Any]?,
        notesMD: String
    )] = []
    var recordsSaveSegments: [[[String: Any]]] = []
    var transcriptionStatusCalls = 0
    var transcriptionStatusDelaySec: TimeInterval = 0
    var transcriptionStatusError: Error?
    var transcriptionCancelError: Error?
    var providersStatusError: Error?
    var providerProbeError: Error?
    var transcriptListStub: [TranscriptSegment] = []
    var buildFinalDelaySec: TimeInterval = 0
    var buildFinalCalls = 0
    var buildFinalError: Error?
    var asrPrewarmError: Error?
    var asrPrewarmCalls: [(model: String, engine: LocalASREngine?, timeoutSec: Int)] = []
    var asrRuntimeStatusQueue: [ASRRuntimeStatus] = []
    var asrPrewarmQueue: [ASRPrewarmResult] = []
    var sidecarVersionStub: [String: Any] = [
        "version": "0.1.0",
        "build": "test",
        "capabilities": [
            "session.start",
            "session.stop",
            "asr.transcribe_chunk",
            "asr.transcribe_media",
            "transcript.replace",
            "insight.refresh_live",
            "insight.build_final",
            "records.save",
            "transcription.status",
            "transcription.import_file",
            "document.export",
        ],
    ]

    var transcriptionStatusStub = TranscriptionStatusResult(
        watcher: TranscriptionWatcherState(),
        queue: [],
        activeJob: nil,
        lastCompleted: nil,
        jobs: []
    )
    var providersStatusStub = AnalysisProvidersStatus(
        selectedVendor: .openai,
        activeReady: true,
        activeProbeOK: true,
        activeProbeErrorCode: .ok,
        activeProbeMessage: "连接成功。",
        vendors: [
            .init(
                vendor: .openai,
                baseURL: "https://api.openai.com/v1",
                modelID: "gpt-4o-mini",
                configured: true,
                hasAPIKey: true,
                modelReady: true
            ),
        ]
    )
    var providerProbeStub = ProviderProbeResult(
        ok: true,
        vendor: .openai,
        model: "gpt-4o-mini",
        baseURL: "https://api.openai.com/v1",
        code: .ok,
        message: "连接成功。",
        hint: ""
    )
    var diagnosticsReportStub = DiagnosticReport(
        overall: .pass,
        checks: [
            DiagnosticCheck(id: "sidecar", title: "侧车服务", status: .pass, actionHint: "", details: "ok", timedOut: false),
        ]
    )

    func sessionStart(meetingID: String, title: String, source: String) throws {}
    func sessionStop(meetingID: String) throws {}
    func transcriptDelta(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int { 0 }
    func transcriptList(meetingID: String, limit: Int) throws -> [TranscriptSegment] {
        Array(transcriptListStub.prefix(limit))
    }
    func refreshLive(meetingID: String, windowSec: Int) throws -> InsightRefreshResult { fakeInsightResult() }
    func buildFinal(meetingID: String) throws -> InsightRefreshResult {
        methodCalls.append("insight.build_final")
        buildFinalCalls += 1
        if buildFinalDelaySec > 0 {
            Thread.sleep(forTimeInterval: buildFinalDelaySec)
        }
        if let buildFinalError {
            throw buildFinalError
        }
        return fakeInsightResult()
    }
    func documentExport(meetingID: String, format: String, outputDir: String) throws -> DocumentExportResult {
        documentExportCalls.append((meetingID: meetingID, format: format, outputDir: outputDir))
        return DocumentExportResult(path: "/tmp/mock.md", format: format)
    }

    func transcriptionImport(filePath: String, title: String) throws -> TranscriptionImportResult {
        importCalls.append((filePath, title))
        return TranscriptionImportResult(jobID: UUID().uuidString, meetingID: "m-1", state: .queued)
    }

    func transcriptionWatchStart(dirs: [String]) throws -> TranscriptionWatchResult {
        watchStartCalls.append(dirs)
        return TranscriptionWatchResult(isRunning: true, dirs: dirs)
    }

    func transcriptionWatchStop() throws -> TranscriptionWatchResult {
        watchStopCalls += 1
        return TranscriptionWatchResult(isRunning: false, dirs: [])
    }

    func transcriptionStatus(limit: Int?) throws -> TranscriptionStatusResult {
        _ = limit
        transcriptionStatusCalls += 1
        if transcriptionStatusDelaySec > 0 {
            Thread.sleep(forTimeInterval: transcriptionStatusDelaySec)
        }
        if let transcriptionStatusError {
            throw transcriptionStatusError
        }
        return transcriptionStatusStub
    }

    func transcriptionCancel(jobID: String, reason: String) throws -> TranscriptionCancelResult {
        if let transcriptionCancelError {
            throw transcriptionCancelError
        }
        cancelCalls.append((jobID, reason))
        return TranscriptionCancelResult(jobID: jobID, state: reason == "preempted_by_live" ? .pausedByLive : .cancelled)
    }

    func sidecarStatus() throws -> [String: Any] {
        ["running": true, "pid": 123, "socket_path": "/tmp/insightkit.sock", "uptime_sec": 10, "ready": true]
    }

    func sidecarVersion() throws -> [String: Any] {
        sidecarVersionStub
    }

    func sidecarShutdown() throws -> [String: Any] {
        ["ok": true, "shutting_down": true]
    }

    func ensureReady(timeoutSec: Int) throws -> [String: Any] {
        ["ready": true]
    }

    func asrRuntimeStatus(engine: LocalASREngine?) throws -> ASRRuntimeStatus {
        if !asrRuntimeStatusQueue.isEmpty {
            return asrRuntimeStatusQueue.removeFirst()
        }
        return ASRRuntimeStatus(
            ready: true,
            pythonExecutable: "/usr/bin/python3",
            pythonVersion: "3.11.0",
            engine: "faster-whisper",
            engineOptions: ["whisper", "funasr", "qwen-mlx"],
            activeProfile: "large-v3",
            modelName: "large-v3",
            modelPath: "/tmp/model",
            modelExists: true,
            vadReady: true,
            diarizationReady: false,
            diarizationDegraded: true,
            diarizationReason: "missing hf token",
            readyByEngine: ["whisper": true, "funasr": false, "qwen-mlx": true],
            backend: ASRBackendStatus(
                configuredDevice: "auto",
                configuredComputeType: "int8",
                device: "auto",
                computeType: "int8",
                resolved: "cpu",
                supportedComputeTypes: ["int8", "float32"]
            ),
            warm: ASRWarmStatus(
                ready: false,
                state: .idle,
                inProgress: false,
                attempt: 0,
                lastWarmMs: 0,
                lastError: ""
            )
        )
    }

    func asrRuntimeBootstrap(model: String, engine: LocalASREngine?) throws -> ASRBootstrapResult {
        ASRBootstrapResult(
            ok: true,
            steps: [
                .init(name: "bootstrap", ok: true, detail: model),
            ],
            status: try asrRuntimeStatus(engine: engine)
        )
    }

    func asrPrewarm(model: String, engine: LocalASREngine?, timeoutSec: Int) throws -> ASRPrewarmResult {
        asrPrewarmCalls.append((model: model, engine: engine, timeoutSec: timeoutSec))
        if let asrPrewarmError {
            throw asrPrewarmError
        }
        if !asrPrewarmQueue.isEmpty {
            return asrPrewarmQueue.removeFirst()
        }
        return ASRPrewarmResult(
            ok: true,
            engine: engine?.rawValue ?? "whisper",
            model: model,
            state: .ready,
            started: true,
            inProgress: false,
            attempt: 1,
            watchdogSec: timeoutSec,
            warmMs: 1200,
            backend: ASRBackendStatus(
                configuredDevice: "auto",
                configuredComputeType: "int8",
                device: "auto",
                computeType: "int8",
                resolved: "cpu",
                supportedComputeTypes: ["int8", "float32"]
            ),
            warm: ASRWarmStatus(
                ready: true,
                state: .ready,
                inProgress: false,
                attempt: 1,
                lastWarmMs: 1200,
                lastError: ""
            ),
            error: ""
        )
    }

    func asrTranscribeChunk(wavPath: String, offsetMs: Int, source: String) throws -> [RPCSegmentDelta] {
        []
    }

    func asrTranscribeMedia(mediaPath: String, source: String) throws -> [RPCSegmentDelta] {
        methodCalls.append("asr.transcribe_media")
        asrTranscribeMediaCalls.append((mediaPath: mediaPath, source: source))
        if !asrTranscribeMediaQueue.isEmpty {
            switch asrTranscribeMediaQueue.removeFirst() {
            case .success(let segments):
                return segments
            case .failure(let error):
                throw error
            }
        }
        if let asrTranscribeMediaError {
            throw asrTranscribeMediaError
        }
        return asrTranscribeMediaStub
    }

    func transcriptReplace(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int {
        methodCalls.append("transcript.replace")
        transcriptReplaceCalls.append((meetingID: meetingID, segments: segments))
        return segments.count
    }

    func providersStatus(probeActive: Bool) throws -> AnalysisProvidersStatus {
        _ = probeActive
        if let providersStatusError {
            throw providersStatusError
        }
        return providersStatusStub
    }

    func providerProbe(vendor: ProviderVendor, model: String, baseURL: String, forceRefresh: Bool) throws -> ProviderProbeResult {
        _ = forceRefresh
        if let providerProbeError {
            throw providerProbeError
        }
        return ProviderProbeResult(
            ok: providerProbeStub.ok,
            vendor: vendor,
            model: model,
            baseURL: baseURL,
            code: providerProbeStub.code,
            message: providerProbeStub.message,
            hint: providerProbeStub.hint
        )
    }

    func diagnosticsQuickCheck(probeTimeoutSec: Int) throws -> DiagnosticReport {
        _ = probeTimeoutSec
        return diagnosticsReportStub
    }

    func recordsSave(
        meetingID: String,
        title: String,
        sourcePath: String,
        segments: [[String: Any]],
        insightPackage: [String: Any]?,
        mediaType: String,
        recordSource: String,
        durationSec: Double,
        analysisMeta: [String: Any]?,
        notesMD: String
    ) throws -> String {
        methodCalls.append("records.save")
        recordsSaveSegments.append(segments)
        recordsSaveCalls.append((
            meetingID: meetingID,
            title: title,
            sourcePath: sourcePath,
            insightPackage: insightPackage,
            mediaType: mediaType,
            recordSource: recordSource,
            durationSec: durationSec,
            analysisMeta: analysisMeta,
            notesMD: notesMD
        ))
        return "/tmp/mock-records/\(meetingID)"
    }

    private func fakeInsightResult() -> InsightRefreshResult {
        let package = InsightPackageV1(
            sessionOverview: .init(title: "demo", overview: "overview", topics: ["t1"]),
            highlightInsights: [],
            speakerPerspectives: [],
            decisionLedger: [],
            actionTracks: [],
            timelineBeats: [],
            provenanceLinks: []
        )
        return InsightRefreshResult(package: package, updatedAt: Date(), provider: "mock", needsReviewCount: 0)
    }
}
