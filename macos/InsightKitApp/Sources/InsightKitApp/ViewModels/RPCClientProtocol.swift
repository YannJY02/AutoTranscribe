import Foundation

// MARK: - InsightRPCClientProtocol

protocol InsightRPCClientProtocol {
    func sessionStart(meetingID: String, title: String, source: String) throws
    func sessionStop(meetingID: String) throws
    func transcriptDelta(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int
    func transcriptReplace(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int
    func transcriptList(meetingID: String, limit: Int) throws -> [TranscriptSegment]
    func refreshLive(meetingID: String, windowSec: Int) throws -> InsightRefreshResult
    func buildFinal(meetingID: String) throws -> InsightRefreshResult
    func documentExport(meetingID: String, format: String, outputDir: String) throws -> DocumentExportResult
    func transcriptionImport(filePath: String, title: String) throws -> TranscriptionImportResult
    func transcriptionWatchStart(dirs: [String]) throws -> TranscriptionWatchResult
    func transcriptionWatchStop() throws -> TranscriptionWatchResult
    func transcriptionStatus(limit: Int?) throws -> TranscriptionStatusResult
    func transcriptionCancel(jobID: String, reason: String) throws -> TranscriptionCancelResult
    func sidecarStatus() throws -> [String: Any]
    func sidecarVersion() throws -> [String: Any]
    func sidecarShutdown() throws -> [String: Any]
    func ensureReady(timeoutSec: Int) throws -> [String: Any]
    func asrRuntimeStatus(engine: LocalASREngine?) throws -> ASRRuntimeStatus
    func asrRuntimeBootstrap(model: String, engine: LocalASREngine?) throws -> ASRBootstrapResult
    func asrPrewarm(model: String, engine: LocalASREngine?, timeoutSec: Int) throws -> ASRPrewarmResult
    func asrTranscribeChunk(wavPath: String, offsetMs: Int, source: String) throws -> [RPCSegmentDelta]
    func asrTranscribeMedia(mediaPath: String, source: String) throws -> [RPCSegmentDelta]
    func providersStatus(probeActive: Bool) throws -> AnalysisProvidersStatus
    func providerProbe(vendor: ProviderVendor, model: String, baseURL: String, forceRefresh: Bool) throws -> ProviderProbeResult
    func diagnosticsQuickCheck(probeTimeoutSec: Int) throws -> DiagnosticReport
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
        notesMD: String,
        presentationStatus: LivePresentationCaptureStatus?
    ) throws -> String  // returns record_path
}

extension InsightRPCClientProtocol {
    func transcriptionStatus() throws -> TranscriptionStatusResult {
        try transcriptionStatus(limit: nil)
    }

    func providersStatus() throws -> AnalysisProvidersStatus {
        try providersStatus(probeActive: false)
    }

    func diagnosticsQuickCheck() throws -> DiagnosticReport {
        try diagnosticsQuickCheck(probeTimeoutSec: 6)
    }
}

extension InsightRPCClient: InsightRPCClientProtocol {}

// MARK: - LiveASRServiceProtocol

protocol LiveASRServiceProtocol {
    func transcribe(chunk: AudioChunk, source: String) throws -> [RPCSegmentDelta]
}

extension LiveASRService: LiveASRServiceProtocol {}
