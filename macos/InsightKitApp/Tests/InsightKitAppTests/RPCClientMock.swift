import Foundation
@testable import InsightKitApp

final class RPCClientMock: InsightRPCClientProtocol {
    var cancelCalls: [(jobID: String, reason: String)] = []
    var watchStartCalls: [[String]] = []
    var watchStopCalls = 0
    var importCalls: [(path: String, title: String)] = []
    var transcriptionStatusCalls = 0
    var transcriptionStatusDelaySec: TimeInterval = 0
    var transcriptionStatusError: Error?
    var providersStatusError: Error?
    var providerProbeError: Error?

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
    func transcriptList(meetingID: String, limit: Int) throws -> [TranscriptSegment] { [] }
    func refreshLive(meetingID: String, windowSec: Int) throws -> InsightRefreshResult { fakeInsightResult() }
    func buildFinal(meetingID: String) throws -> InsightRefreshResult { fakeInsightResult() }
    func documentExport(meetingID: String, format: String, outputDir: String) throws -> DocumentExportResult {
        DocumentExportResult(path: "/tmp/mock.md", format: format)
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
        cancelCalls.append((jobID, reason))
        return TranscriptionCancelResult(jobID: jobID, state: reason == "preempted_by_live" ? .pausedByLive : .cancelled)
    }

    func sidecarStatus() throws -> [String: Any] {
        ["running": true, "pid": 123, "socket_path": "/tmp/insightkit.sock", "uptime_sec": 10, "ready": true]
    }

    func sidecarVersion() throws -> [String: Any] {
        ["version": "0.1.0", "build": "test", "capabilities": ["transcription.status"]]
    }

    func sidecarShutdown() throws -> [String: Any] {
        ["ok": true, "shutting_down": true]
    }

    func ensureReady(timeoutSec: Int) throws -> [String: Any] {
        ["ready": true]
    }

    func asrRuntimeStatus(engine: LocalASREngine?) throws -> ASRRuntimeStatus {
        ASRRuntimeStatus(
            ready: true,
            pythonExecutable: "/usr/bin/python3",
            pythonVersion: "3.11.0",
            engine: "faster-whisper",
            engineOptions: ["whisper", "funasr"],
            activeProfile: "large-v3",
            modelName: "large-v3",
            modelPath: "/tmp/model",
            modelExists: true,
            vadReady: true,
            diarizationReady: false,
            diarizationDegraded: true,
            diarizationReason: "missing hf token",
            readyByEngine: ["whisper": true, "funasr": false]
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

    func asrTranscribeChunk(wavPath: String, offsetMs: Int, source: String) throws -> [RPCSegmentDelta] {
        []
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
