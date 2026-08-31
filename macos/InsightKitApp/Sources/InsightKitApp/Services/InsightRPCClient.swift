import Foundation
import Darwin

final class InsightRPCClient {
    enum RPCError: LocalizedError {
        case socketCreateFailed
        case socketPathTooLong
        case connectFailed(String)
        case sendFailed
        case receiveFailed
        case timeout(String)
        case invalidResponse
        case remoteError(String)
        case persistentNotConnected
        case handshakeFailed(String)

        var errorDescription: String? {
            switch self {
            case .socketCreateFailed:
                return "无法创建本地 socket。"
            case .socketPathTooLong:
                return "socket 路径过长。"
            case .connectFailed(let reason):
                return "连接 Insight 侧车失败: \(reason)"
            case .sendFailed:
                return "向 Insight 侧车发送请求失败。"
            case .receiveFailed:
                return "读取 Insight 侧车响应失败。"
            case .timeout(let method):
                return "调用超时: \(method)"
            case .invalidResponse:
                return "Insight 侧车响应格式无效。"
            case .remoteError(let message):
                return "Insight 侧车错误: \(message)"
            case .persistentNotConnected:
                return "持久连接未建立。"
            case .handshakeFailed(let reason):
                return "持久连接握手失败: \(reason)"
            }
        }
    }

    struct Config {
        var socketPath: String
        var timeoutSec: Int
        /// 专用于 asr.transcribe_chunk 的超时（模型推理可能远超全局超时）
        var asrChunkTimeoutSec: Int
        /// 专用于最终媒体转写的超时（录制完成后按媒体时间轴重建最终转写）
        var asrMediaTimeoutSec: Int
        /// 专用于 provider 探测的超时（短超时 + 禁重试，避免阻塞主流程）
        var providerProbeTimeoutSec: Int
        /// 专用于 insight.build_final 的超时（最终洞察可能需要完整 provider 生成）
        var finalInsightTimeoutSec: Int
        var maxRetries: Int
        var breakerThreshold: Int
        var breakerCooldownSec: Int

        static func `default`() -> Config {
            Config(
                socketPath: InsightRuntimeDefaults.socketPath,
                timeoutSec: Int(ProcessInfo.processInfo.environment["INSIGHTKIT_RPC_TIMEOUT_SEC"] ?? "8") ?? 8,
                asrChunkTimeoutSec: Int(ProcessInfo.processInfo.environment["INSIGHTKIT_ASR_CHUNK_TIMEOUT_SEC"] ?? "120") ?? 120,
                asrMediaTimeoutSec: Int(ProcessInfo.processInfo.environment["INSIGHTKIT_ASR_MEDIA_TIMEOUT_SEC"] ?? "900") ?? 900,
                providerProbeTimeoutSec: Int(ProcessInfo.processInfo.environment["INSIGHTKIT_PROVIDER_PROBE_RPC_TIMEOUT_SEC"] ?? "6") ?? 6,
                finalInsightTimeoutSec: Int(ProcessInfo.processInfo.environment["INSIGHTKIT_FINAL_INSIGHT_RPC_TIMEOUT_SEC"] ?? "60") ?? 60,
                maxRetries: Int(ProcessInfo.processInfo.environment["INSIGHTKIT_RPC_MAX_RETRIES"] ?? "1") ?? 1,
                breakerThreshold: Int(ProcessInfo.processInfo.environment["INSIGHTKIT_RPC_BREAKER_THRESHOLD"] ?? "4") ?? 4,
                breakerCooldownSec: Int(ProcessInfo.processInfo.environment["INSIGHTKIT_RPC_BREAKER_COOLDOWN"] ?? "10") ?? 10
            )
        }
    }

    private let config: Config
    private let stateQueue = DispatchQueue(label: "InsightKit.RPCClient.State")
    /// Dedicated queue for blocking socket I/O – keeps the Swift cooperative
    /// thread pool free so SwiftUI and other async work never stalls.
    private let ioQueue = DispatchQueue(label: "InsightKit.RPCClient.IO", qos: .userInitiated)
    private var consecutiveFailures = 0
    private var breakerOpenedAt: Date?

    // MARK: - Persistent connection state
    private var persistentFD: Int32 = -1
    private var persistentReader: RPCFrameBuffer?
    private(set) var usePersistent = false

    init(config: Config = .default()) {
        self.config = config
    }

    // MARK: - Persistent connection lifecycle

    /// Open a persistent NDJSON connection and perform the handshake.
    /// After success, all RPC calls route through the persistent socket.
    func connectPersistent() throws {
        disconnectPersistent()
        let fd = try openUnixSocket(timeoutSec: config.timeoutSec)

        var hsLine = try JSONEncoder().encode(RPCHandshake(version: "1.0", push: true))
        hsLine.append(UInt8(ascii: "\n"))
        let hsSent = hsLine.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if hsSent <= 0 { Darwin.close(fd); throw RPCError.sendFailed }

        let reader = RPCFrameBuffer()
        var rawBuf = [UInt8](repeating: 0, count: 4096)
        var ackReceived = false
        while !ackReceived {
            let n = Darwin.read(fd, &rawBuf, rawBuf.count)
            if n < 0 {
                Darwin.close(fd)
                let isTimeout = errno == EAGAIN || errno == EWOULDBLOCK
                throw RPCError.handshakeFailed(isTimeout ? "timeout waiting for ack" : "read error: \(String(cString: strerror(errno)))")
            }
            if n == 0 { Darwin.close(fd); throw RPCError.handshakeFailed("connection closed before ack") }
            for frame in reader.append(Data(rawBuf[0..<n])) {
                guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                      obj["insightkit"] != nil
                else { Darwin.close(fd); throw RPCError.handshakeFailed("invalid ack payload") }
                ackReceived = true
            }
        }
        self.persistentFD = fd
        self.persistentReader = reader
        self.usePersistent = true
    }

    /// Close the persistent connection and revert to short-lived sockets.
    func disconnectPersistent() {
        if persistentFD >= 0 { Darwin.close(persistentFD); persistentFD = -1 }
        persistentReader = nil
        usePersistent = false
    }

    var isPersistentConnected: Bool { usePersistent && persistentFD >= 0 }

    func sessionStart(meetingID: String, title: String, source: String) throws {
        _ = try callWithRetry(method: "session.start", params: [
            "meeting_id": meetingID,
            "title": title,
            "source": source,
        ])
    }

    func sessionStop(meetingID: String) throws {
        _ = try callWithRetry(method: "session.stop", params: ["meeting_id": meetingID])
    }

    func sessionStopForFinalization(meetingID: String, leaseToken: String) throws {
        _ = try callWithRetry(method: "session.stop", params: [
            "meeting_id": meetingID,
            "await_record_save": true,
            "finalization_lease_token": leaseToken,
        ])
    }

    func sessionFinalizationAbort(meetingID: String, leaseToken: String) throws {
        _ = try callWithRetry(method: "session.finalization.abort", params: [
            "meeting_id": meetingID,
            "finalization_lease_token": leaseToken,
        ])
    }

    func transcriptDelta(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int {
        guard !segments.isEmpty else { return 0 }
        let encoder = JSONEncoder()
        let data = try encoder.encode(segments)
        let rawSegments = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []

        let result = try callWithRetry(method: "transcript.delta", params: [
            "meeting_id": meetingID,
            "segments": rawSegments,
        ])
        return result["ingested"] as? Int ?? 0
    }

    func transcriptReplace(meetingID: String, segments: [RPCSegmentDelta]) throws -> Int {
        let encoder = JSONEncoder()
        let data = try encoder.encode(segments)
        let rawSegments = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []

        let result = try callProductAction(
            method: "runtime.transcript.replace",
            legacyMethod: "transcript.replace",
            params: [
                "meeting_id": meetingID,
                "segments": rawSegments,
            ]
        )
        return result["replaced"] as? Int ?? 0
    }

    func transcriptList(meetingID: String, limit: Int = 1000) throws -> [TranscriptSegment] {
        let result = try callWithRetry(method: "transcript.list", params: [
            "meeting_id": meetingID,
            "limit": limit,
        ])
        let rows = (result["segments"] as? [[String: Any]]) ?? []
        return rows.map { row in
            TranscriptSegment(
                startMs: (row["start_ms"] as? Int) ?? 0,
                endMs: (row["end_ms"] as? Int) ?? 0,
                speaker: ((row["speaker"] as? String) ?? "").isEmpty ? "未标注" : ((row["speaker"] as? String) ?? ""),
                source: (row["source"] as? String) ?? "",
                text: (row["text"] as? String) ?? ""
            )
        }
    }

    func refreshLive(meetingID: String, windowSec: Int = 120) throws -> InsightRefreshResult {
        var params: [String: Any] = [
            "meeting_id": meetingID,
            "window_sec": windowSec,
        ]
        for (key, value) in AppConfigStore.shared.activeProviderParams() {
            params[key] = value
        }
        let result = try callWithRetry(method: "insight.refresh_live", params: params)
        return try decodePackageResult(result)
    }

    func buildFinal(meetingID: String) throws -> InsightRefreshResult {
        var params: [String: Any] = [
            "meeting_id": meetingID,
        ]
        for (key, value) in AppConfigStore.shared.activeProviderParams() {
            params[key] = value
        }
        let result = try callProductAction(
            method: "smart_minutes.generate",
            legacyMethod: "insight.build_final",
            params: params,
            overrideTimeoutSec: max(config.timeoutSec, config.finalInsightTimeoutSec)
        )
        return try decodePackageResult(result)
    }

    func documentExport(meetingID: String, format: String = "markdown", outputDir: String = "") throws -> DocumentExportResult {
        var params: [String: Any] = [
            "meeting_id": meetingID,
            "format": format,
            "output_dir": outputDir,
        ]
        for (key, value) in AppConfigStore.shared.activeProviderParams() {
            params[key] = value
        }
        let result = try callWithRetry(method: "document.export", params: params)
        let path = (result["path"] as? String) ?? ""
        let resolvedFormat = (result["format"] as? String) ?? format
        guard !path.isEmpty else {
            throw RPCError.invalidResponse
        }
        return DocumentExportResult(path: path, format: resolvedFormat)
    }

    func transcriptionImport(filePath: String, title: String = "") throws -> TranscriptionImportResult {
        var params: [String: Any] = [
            "file_path": filePath,
            "title": title,
        ]
        for (key, value) in AppConfigStore.shared.activeProviderParams() {
            params[key] = value
        }
        let result = try callWithRetry(method: "transcription.import_file", params: params)
        let jobID = (result["job_id"] as? String) ?? ""
        let meetingID = (result["meeting_id"] as? String) ?? ""
        let stateRaw = (result["state"] as? String) ?? "queued"
        guard !jobID.isEmpty, !meetingID.isEmpty else {
            throw RPCError.invalidResponse
        }
        return TranscriptionImportResult(jobID: jobID, meetingID: meetingID, state: TranscriptionJobState(apiValue: stateRaw))
    }

    func transcriptionWatchStart(dirs: [String]) throws -> TranscriptionWatchResult {
        let result = try callWithRetry(method: "transcription.watch.start", params: [
            "dirs": dirs,
            "recursive": false,
        ])
        return decodeWatchResult(result)
    }

    func transcriptionWatchStop() throws -> TranscriptionWatchResult {
        let result = try callWithRetry(method: "transcription.watch.stop", params: [:])
        return decodeWatchResult(result)
    }

    func transcriptionStatus(limit: Int? = nil) throws -> TranscriptionStatusResult {
        var params: [String: Any] = [:]
        if let limit, limit > 0 {
            params["limit"] = limit
        }
        let result = try callWithRetry(
            method: "transcription.status",
            params: params,
            overrideTimeoutSec: 3
        )
        return try decodeTranscriptionStatus(result)
    }

    func transcriptionCancel(jobID: String, reason: String) throws -> TranscriptionCancelResult {
        let result = try callWithRetry(method: "transcription.cancel_job", params: [
            "job_id": jobID,
            "reason": reason,
        ])
        let resolvedJobID = (result["job_id"] as? String) ?? ""
        let stateRaw = (result["state"] as? String) ?? "cancelled"
        guard !resolvedJobID.isEmpty else {
            throw RPCError.invalidResponse
        }
        return TranscriptionCancelResult(jobID: resolvedJobID, state: TranscriptionJobState(apiValue: stateRaw))
    }

    func sidecarStatus() throws -> [String: Any] {
        try callWithRetry(method: "sidecar.status", params: [:])
    }

    func sidecarVersion() throws -> [String: Any] {
        try callWithRetry(method: "sidecar.version", params: [:])
    }

    func sidecarShutdown() throws -> [String: Any] {
        try callWithRetry(method: "sidecar.shutdown", params: [:])
    }

    func ensureReady(timeoutSec: Int = 6) throws -> [String: Any] {
        try callWithRetry(method: "sidecar.ensure_ready", params: ["timeout_sec": timeoutSec])
    }

    func asrRuntimeStatus(engine: LocalASREngine? = nil) throws -> ASRRuntimeStatus {
        var params: [String: Any] = [:]
        if let engine {
            params["engine"] = engine.rawValue
        }
        let result = try callWithRetry(method: "asr.runtime.status", params: params)
        return decodeASRRuntimeStatus(result)
    }

    func asrRuntimeBootstrap(model: String, engine: LocalASREngine? = nil) throws -> ASRBootstrapResult {
        var params: [String: Any] = ["model": model]
        if let engine {
            params["engine"] = engine.rawValue
        }
        let result = try callWithRetry(method: "asr.runtime.bootstrap", params: params)
        let ok = (result["ok"] as? Bool) ?? false
        let stepsRaw = (result["steps"] as? [[String: Any]]) ?? []
        let steps = stepsRaw.map {
            ASRBootstrapResult.Step(
                name: ($0["name"] as? String) ?? "unknown",
                ok: ($0["ok"] as? Bool) ?? false,
                detail: ($0["detail"] as? String) ?? ""
            )
        }
        let statusRaw = result["status"] as? [String: Any] ?? [:]
        return ASRBootstrapResult(
            ok: ok,
            steps: steps,
            status: decodeASRRuntimeStatus(statusRaw)
        )
    }

    func asrPrewarm(model: String, engine: LocalASREngine? = nil, timeoutSec: Int = 20) throws -> ASRPrewarmResult {
        var params: [String: Any] = [
            "model": model,
            "timeout_sec": max(3, timeoutSec),
        ]
        if let engine {
            params["engine"] = engine.rawValue
        }
        let result = try callWithRetry(
            method: "asr.prewarm",
            params: params,
            overrideTimeoutSec: max(config.timeoutSec, timeoutSec),
            maxRetriesOverride: 0
        )
        let backendRaw = result["backend"] as? [String: Any] ?? [:]
        let warmRaw = result["warm"] as? [String: Any] ?? [:]
        let warmStatus = decodeASRWarmStatus(warmRaw, fallbackPayload: result)
        return ASRPrewarmResult(
            ok: (result["ok"] as? Bool) ?? false,
            engine: (result["engine"] as? String) ?? (engine?.rawValue ?? ""),
            model: (result["model"] as? String) ?? model,
            state: decodeASRWarmState(
                raw: result["state"] as? String,
                ready: warmStatus.ready || ((result["ok"] as? Bool) ?? false)
            ),
            started: (result["started"] as? Bool) ?? false,
            inProgress: (result["in_progress"] as? Bool) ?? warmStatus.inProgress,
            attempt: (result["attempt"] as? Int) ?? warmStatus.attempt,
            watchdogSec: (result["watchdog_sec"] as? Int) ?? max(3, timeoutSec),
            warmMs: (result["warm_ms"] as? Int) ?? 0,
            backend: decodeASRBackendStatus(backendRaw),
            warm: warmStatus,
            error: (result["error"] as? String) ?? ""
        )
    }

    func providersStatus(probeActive: Bool = false) throws -> AnalysisProvidersStatus {
        let result = try callWithRetry(
            method: "analysis.providers.status",
            params: ["probe_active": probeActive],
            overrideTimeoutSec: max(1, config.providerProbeTimeoutSec),
            maxRetriesOverride: 0
        )
        let selectedRaw = (result["selected_vendor"] as? String) ?? ProviderVendor.openai.rawValue
        let selectedVendor = ProviderVendor(rawValue: selectedRaw) ?? .openai
        let activeReady = (result["active_ready"] as? Bool) ?? false
        let activeProbeOK = result["active_probe_ok"] as? Bool
        let probeCodeRaw = ((result["active_probe_error_code"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let activeProbeCode = probeCodeRaw.isEmpty ? nil : (ProviderProbeErrorCode(rawValue: probeCodeRaw) ?? .unknown)
        let activeProbeMessage = (result["active_probe_message"] as? String) ?? ""

        var vendors: [AnalysisProvidersStatus.Vendor] = []
        if let rawMap = result["vendors"] as? [String: Any] {
            for (_, value) in rawMap {
                guard let payload = value as? [String: Any] else { continue }
                let vendorRaw = (payload["vendor"] as? String) ?? ""
                guard let vendor = ProviderVendor(rawValue: vendorRaw) else { continue }
                vendors.append(
                    AnalysisProvidersStatus.Vendor(
                        vendor: vendor,
                        baseURL: (payload["base_url"] as? String) ?? "",
                        modelID: (payload["model_id"] as? String) ?? "",
                        configured: (payload["configured"] as? Bool) ?? false,
                        hasAPIKey: (payload["has_api_key"] as? Bool) ?? false,
                        modelReady: (payload["model_ready"] as? Bool) ?? false
                    )
                )
            }
        }
        vendors.sort { $0.vendor.rawValue < $1.vendor.rawValue }
        return AnalysisProvidersStatus(
            selectedVendor: selectedVendor,
            activeReady: activeReady,
            activeProbeOK: activeProbeOK,
            activeProbeErrorCode: activeProbeCode,
            activeProbeMessage: activeProbeMessage,
            vendors: vendors
        )
    }

    func providerProbe(
        vendor: ProviderVendor,
        model: String,
        baseURL: String,
        forceRefresh: Bool = true
    ) throws -> ProviderProbeResult {
        let result = try callWithRetry(
            method: "analysis.provider.probe",
            params: [
                "provider_vendor": vendor.rawValue,
                "provider_model": model,
                "base_url": baseURL,
                "force_refresh": forceRefresh,
            ]
            ,
            overrideTimeoutSec: max(1, config.providerProbeTimeoutSec),
            maxRetriesOverride: 0
        )
        let vendorRaw = (result["vendor"] as? String) ?? vendor.rawValue
        let resolvedVendor = ProviderVendor(rawValue: vendorRaw) ?? vendor
        let codeRaw = ((result["code"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let code = ProviderProbeErrorCode(rawValue: codeRaw) ?? .unknown
        return ProviderProbeResult(
            ok: (result["ok"] as? Bool) ?? false,
            vendor: resolvedVendor,
            model: (result["model"] as? String) ?? model,
            baseURL: (result["base_url"] as? String) ?? baseURL,
            code: code,
            message: (result["message"] as? String) ?? "",
            hint: (result["hint"] as? String) ?? ""
        )
    }

    func diagnosticsQuickCheck(probeTimeoutSec: Int = 6) throws -> DiagnosticReport {
        let result = try callWithRetry(
            method: "diagnostics.quick_check",
            params: ["probe_timeout_sec": max(1, probeTimeoutSec)],
            overrideTimeoutSec: 20
        )
        let overallRaw = (result["overall"] as? String) ?? "fail"
        let overall = DiagnosticCheckStatus(rawValue: overallRaw) ?? .fail
        let rows = (result["checks"] as? [[String: Any]]) ?? []
        let checks: [DiagnosticCheck] = rows.map { row in
            DiagnosticCheck(
                id: (row["id"] as? String) ?? UUID().uuidString,
                title: (row["title"] as? String) ?? "未知检查项",
                status: DiagnosticCheckStatus(rawValue: (row["status"] as? String) ?? "fail") ?? .fail,
                actionHint: (row["action_hint"] as? String) ?? "",
                details: (row["details"] as? String) ?? "",
                timedOut: (row["timed_out"] as? Bool) ?? false
            )
        }
        return DiagnosticReport(overall: overall, checks: checks)
    }

    func asrTranscribeChunk(wavPath: String, offsetMs: Int, source: String) throws -> [RPCSegmentDelta] {
        let result = try callWithRetry(
            method: "asr.transcribe_chunk",
            params: [
                "wav_path": wavPath,
                "offset_ms": offsetMs,
                "source": source,
            ],
            overrideTimeoutSec: max(config.timeoutSec, config.asrChunkTimeoutSec)
        )
        return decodeSegmentDeltas(from: result["segments"] as? [[String: Any]] ?? [], fallbackSource: source)
    }

    func asrTranscribeMedia(mediaPath: String, source: String = "media") throws -> [RPCSegmentDelta] {
        let result = try callProductAction(
            method: "media.transcribe_final",
            legacyMethod: "asr.transcribe_media",
            params: [
                "media_path": mediaPath,
                "source": source,
            ],
            overrideTimeoutSec: max(config.timeoutSec, config.asrMediaTimeoutSec)
        )
        return decodeSegmentDeltas(from: result["segments"] as? [[String: Any]] ?? [], fallbackSource: source)
    }

    private func decodeSegmentDeltas(from rows: [[String: Any]], fallbackSource: String) -> [RPCSegmentDelta] {
        rows.compactMap { row in
            guard
                let text = row["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            let startMs = (row["start_ms"] as? Int) ?? 0
            let endMs = (row["end_ms"] as? Int) ?? (startMs + 1000)
            let speaker = (row["speaker"] as? String) ?? ""
            let confidence = (row["confidence"] as? Double) ?? ((row["confidence"] as? NSNumber)?.doubleValue ?? 0.0)
            let segSource = (row["source"] as? String) ?? fallbackSource
            return RPCSegmentDelta(
                startMs: startMs,
                endMs: endMs,
                speaker: speaker,
                text: text,
                confidence: confidence,
                source: segSource
            )
        }
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
        analysisMeta: [String: Any]? = nil,
        notesMD: String,
        presentationStatus: LivePresentationCaptureStatus? = nil,
        finalizationLeaseToken: String? = nil
    ) throws -> String {
        var params: [String: Any] = [
            "meeting_id": meetingID,
            "title": title,
            "source_path": sourcePath,
            "segments": segments,
            "media_type": mediaType,
            "record_source": recordSource,
            "duration_sec": durationSec,
            "notes_md": notesMD,
        ]
        if let pkg = insightPackage {
            params["insight_package"] = pkg
        }
        if let analysisMeta {
            params["analysis_meta"] = analysisMeta
        }
        if let presentationStatus {
            params["presentation_status"] = presentationStatus.rawValue
        }
        if let finalizationLeaseToken {
            params["finalization_lease_token"] = finalizationLeaseToken
        }
        let result = try callProductAction(method: "record.save", legacyMethod: "records.save", params: params)
        return (result["record_path"] as? String) ?? ""
    }

    private func decodeWatchResult(_ result: [String: Any]) -> TranscriptionWatchResult {
        let stateRaw = (result["state"] as? String) ?? "stopped"
        let dirs = (result["dirs"] as? [String]) ?? []
        return TranscriptionWatchResult(isRunning: stateRaw == "running", dirs: dirs)
    }

    private func decodeTranscriptionStatus(_ result: [String: Any]) throws -> TranscriptionStatusResult {
        let watcherRaw = result["watcher"] as? [String: Any] ?? [:]
        let watcher = TranscriptionWatcherState(
            isRunning: ((watcherRaw["state"] as? String) ?? "stopped") == "running",
            dirs: (watcherRaw["dirs"] as? [String]) ?? [],
            queueSize: ((result["queue"] as? [[String: Any]]) ?? []).count,
            activeJobID: (result["active_job"] as? [String: Any])?["id"] as? String
        )

        let queue = decodeJobs(result["queue"] as? [[String: Any]] ?? [])
        let jobs = decodeJobs(result["jobs"] as? [[String: Any]] ?? [])
        let activeJob = decodeJobs((result["active_job"] as? [String: Any]).map { [$0] } ?? []).first

        var lastCompleted: TranscriptionLastCompleted? = nil
        if
            let lastRaw = result["last_completed"] as? [String: Any],
            let jobRaw = lastRaw["job"] as? [String: Any],
            let job = decodeJobs([jobRaw]).first
        {
            let updatedAt = parseISODate(lastRaw["updated_at"] as? String)
            lastCompleted = TranscriptionLastCompleted(
                job: job,
                meetingID: (lastRaw["meeting_id"] as? String) ?? job.meetingID,
                segmentsCount: (lastRaw["segments_count"] as? Int) ?? 0,
                updatedAt: updatedAt
            )
        }

        return TranscriptionStatusResult(
            watcher: watcher,
            queue: queue,
            activeJob: activeJob,
            lastCompleted: lastCompleted,
            jobs: jobs
        )
    }

    private func decodeJobs(_ rows: [[String: Any]]) -> [TranscriptionJob] {
        rows.compactMap { row in
            let id = (row["id"] as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let startedAt = parseISODate(row["started_at"] as? String)
            let endedAt = parseISODate(row["ended_at"] as? String)
            return TranscriptionJob(
                id: id,
                meetingID: (row["meeting_id"] as? String) ?? "",
                sourcePath: (row["source_path"] as? String) ?? "",
                title: (row["title"] as? String) ?? "",
                state: TranscriptionJobState(apiValue: (row["state"] as? String) ?? "queued"),
                progress: (row["progress"] as? Int) ?? 0,
                stage: (row["stage"] as? String) ?? "",
                error: (row["error"] as? String) ?? "",
                reason: (row["reason"] as? String) ?? "",
                startedAt: startedAt,
                endedAt: endedAt
            )
        }
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func decodePackageResult(_ result: [String: Any]) throws -> InsightRefreshResult {
        guard let packageAny = result["insight_package"] else {
            throw RPCError.invalidResponse
        }
        let packageData = try JSONSerialization.data(withJSONObject: packageAny)
        let package = try JSONDecoder().decode(InsightPackageV1.self, from: packageData)

        var updatedAt: Date? = nil
        if let updatedAtString = result["updated_at"] as? String {
            updatedAt = ISO8601DateFormatter().date(from: updatedAtString)
        }
        let providerVendor = (result["provider_vendor"] as? String) ?? (result["provider"] as? String) ?? ""
        let providerModel = (result["provider_model"] as? String) ?? ""
        let provider = providerModel.isEmpty ? providerVendor : "\(providerVendor):\(providerModel)"
        let needsReviewCount = (result["needs_review_count"] as? Int) ?? 0
        return InsightRefreshResult(
            package: package,
            updatedAt: updatedAt,
            provider: provider,
            needsReviewCount: needsReviewCount
        )
    }

    private func decodeASRRuntimeStatus(_ result: [String: Any]) -> ASRRuntimeStatus {
        let python = result["python"] as? [String: Any] ?? [:]
        let model = result["model"] as? [String: Any] ?? [:]
        let vad = result["vad"] as? [String: Any] ?? [:]
        let diar = result["speaker_diarization"] as? [String: Any] ?? [:]
        let backend = result["backend"] as? [String: Any] ?? [:]
        let warm = result["warm"] as? [String: Any] ?? [:]
        let profile = result["profile"] as? [String: Any] ?? [:]
        let readyRaw = result["ready_by_engine"] as? [String: Any] ?? [:]
        var readyByEngine: [String: Bool] = [:]
        for (key, value) in readyRaw {
            if let b = value as? Bool {
                readyByEngine[key] = b
            } else if let n = value as? NSNumber {
                readyByEngine[key] = n.boolValue
            }
        }

        return ASRRuntimeStatus(
            ready: (result["ready"] as? Bool) ?? false,
            pythonExecutable: (python["executable"] as? String) ?? "",
            pythonVersion: (python["version"] as? String) ?? "",
            engine: (result["engine"] as? String) ?? "",
            engineOptions: (result["engine_options"] as? [String]) ?? [],
            activeProfile: (result["active_profile"] as? String) ?? "",
            modelName: (model["name"] as? String) ?? "",
            modelPath: (model["path"] as? String) ?? "",
            modelExists: (model["exists"] as? Bool) ?? false,
            vadReady: (vad["ready"] as? Bool) ?? false,
            diarizationReady: (diar["ready"] as? Bool) ?? false,
            diarizationDegraded: (diar["degraded"] as? Bool) ?? false,
            diarizationReason: (diar["reason"] as? String) ?? "",
            readyByEngine: readyByEngine,
            backend: decodeASRBackendStatus(backend),
            warm: decodeASRWarmStatus(warm),
            profile: decodeASRRuntimeProfile(profile)
        )
    }

    private func decodeASRRuntimeProfile(_ payload: [String: Any]) -> ASRRuntimeProfile {
        guard !payload.isEmpty else { return .empty }
        let engineProfiles = payload["engine_profiles"] as? [String: Any] ?? [:]
        let appleSpeechPayload = engineProfiles["apple-speech"] as? [String: Any]
        return ASRRuntimeProfile(
            schemaVersion: (payload["schema_version"] as? Int) ?? 0,
            configuredEngine: (payload["configured_engine"] as? String) ?? "",
            activeEngine: (payload["active_engine"] as? String) ?? "",
            technicalStatus: (payload["technical_status"] as? String) ?? "",
            liveASR: decodeASRRuntimeReadiness(payload["live_asr"] as? [String: Any] ?? [:]),
            finalMediaASR: decodeASRRuntimeReadiness(payload["final_media_asr"] as? [String: Any] ?? [:]),
            userRecoveryHint: (payload["user_recovery_hint"] as? String) ?? "",
            appleSpeech: appleSpeechPayload.map(decodeASREngineProfile)
        )
    }

    private func decodeASRRuntimeReadiness(_ payload: [String: Any]) -> ASRRuntimeReadiness {
        ASRRuntimeReadiness(
            ready: (payload["ready"] as? Bool) ?? false,
            reason: (payload["reason"] as? String) ?? ""
        )
    }

    private func decodeASREngineProfile(_ payload: [String: Any]) -> ASREngineProfile {
        let capabilities = payload["capabilities"] as? [String: Any] ?? [:]
        return ASREngineProfile(
            engine: (payload["engine"] as? String) ?? "",
            displayName: (payload["display_name"] as? String) ?? "",
            selectable: (payload["selectable"] as? Bool) ?? false,
            ready: (payload["ready"] as? Bool) ?? false,
            availabilityState: (payload["availability_state"] as? String) ?? "",
            liveASR: (capabilities["live_asr"] as? Bool) ?? false,
            finalMediaASR: (capabilities["final_media_asr"] as? Bool) ?? false,
            diarization: (capabilities["diarization"] as? Bool) ?? false,
            limitations: (payload["limitations"] as? [String]) ?? [],
            userRecoveryHint: (payload["user_recovery_hint"] as? String) ?? ""
        )
    }

    private func decodeASRBackendStatus(_ payload: [String: Any]) -> ASRBackendStatus {
        ASRBackendStatus(
            configuredDevice: (payload["configured_device"] as? String) ?? (payload["device"] as? String) ?? "auto",
            configuredComputeType: (payload["configured_compute_type"] as? String) ?? (payload["compute_type"] as? String) ?? "int8",
            device: (payload["device"] as? String) ?? "auto",
            computeType: (payload["compute_type"] as? String) ?? "int8",
            resolved: (payload["resolved"] as? String) ?? "",
            supportedComputeTypes: (payload["supported_compute_types"] as? [String]) ?? []
        )
    }

    private func decodeASRWarmStatus(_ payload: [String: Any], fallbackPayload: [String: Any] = [:]) -> ASRWarmStatus {
        let ready = (payload["ready"] as? Bool) ?? (fallbackPayload["ok"] as? Bool) ?? false
        let state = decodeASRWarmState(raw: payload["state"] as? String ?? fallbackPayload["state"] as? String, ready: ready)
        let lastError = (payload["last_error"] as? String) ?? (fallbackPayload["error"] as? String) ?? ""
        return ASRWarmStatus(
            ready: ready,
            state: state,
            inProgress: (payload["in_progress"] as? Bool) ?? (fallbackPayload["in_progress"] as? Bool) ?? state.isInProgress,
            attempt: (payload["attempt"] as? Int) ?? (fallbackPayload["attempt"] as? Int) ?? (ready ? 1 : 0),
            lastWarmMs: (payload["last_warm_ms"] as? Int) ?? (fallbackPayload["warm_ms"] as? Int) ?? 0,
            lastError: lastError
        )
    }

    private func decodeASRWarmState(raw: String?, ready: Bool) -> ASRWarmState {
        if let raw, let state = ASRWarmState(rawValue: raw) {
            return state
        }
        return ready ? .ready : .idle
    }

    private func callWithRetry(
        method: String,
        params: [String: Any],
        overrideTimeoutSec: Int? = nil,
        maxRetriesOverride: Int? = nil
    ) throws -> [String: Any] {
        try checkBreakerState(method: method)
        let countFailureForMethod = shouldCountFailure(method: method)
        let clearBreakerOnSuccess = shouldClearBreakerOnSuccess(method: method)
        let timeoutSec = overrideTimeoutSec.map { max(1, $0) } ?? config.timeoutSec
        let maxRetries = max(0, maxRetriesOverride ?? config.maxRetries)

        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let result = try callSync(method: method, params: params, timeoutSec: timeoutSec)
                if clearBreakerOnSuccess {
                    markSuccess()
                }
                return result
            } catch {
                lastError = error
                if countFailureForMethod {
                    markFailure()
                }
                if attempt >= maxRetries {
                    break
                }
            }
        }

        throw lastError ?? RPCError.timeout(method)
    }

    private func callProductAction(
        method: String,
        legacyMethod: String,
        params: [String: Any],
        overrideTimeoutSec: Int? = nil
    ) throws -> [String: Any] {
        do {
            return try callWithRetry(
                method: method,
                params: params,
                overrideTimeoutSec: overrideTimeoutSec,
                maxRetriesOverride: 0
            )
        } catch RPCError.remoteError(let message)
            where message.localizedCaseInsensitiveContains("method not found") {
            return try callWithRetry(
                method: legacyMethod,
                params: params,
                overrideTimeoutSec: overrideTimeoutSec
            )
        }
    }

    /// Async variant that runs blocking socket I/O on the dedicated `ioQueue`
    /// instead of the Swift cooperative thread pool.
    func callWithRetryAsync(method: String, params: [String: Any], overrideTimeoutSec: Int? = nil) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    let result = try callWithRetry(method: method, params: params, overrideTimeoutSec: overrideTimeoutSec)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func checkBreakerState(method: String) throws {
        if !shouldUseBreaker(method: method) {
            return
        }
        try stateQueue.sync {
            guard let openedAt = breakerOpenedAt else {
                return
            }
            let cooldown = TimeInterval(max(1, config.breakerCooldownSec))
            if Date().timeIntervalSince(openedAt) >= cooldown {
                breakerOpenedAt = nil
                consecutiveFailures = 0
                return
            }
            throw RPCError.timeout("\(method) [circuit-open]")
        }
    }

    private func shouldUseBreaker(method: String) -> Bool {
        // Sidecar lifecycle probes run during startup; they should not be blocked by stale breaker state.
        if method.hasPrefix("sidecar.") {
            return false
        }
        // Provider probing may fail frequently due transient networking/auth; avoid poisoning transport breaker.
        if method == "analysis.provider.probe" || method == "analysis.providers.status" {
            return false
        }
        return true
    }

    private func shouldCountFailure(method: String) -> Bool {
        // Sidecar probes may fail transiently while process/socket is booting; do not poison global circuit.
        if method.hasPrefix("sidecar.") {
            return false
        }
        if method == "analysis.provider.probe" || method == "analysis.providers.status" {
            return false
        }
        return true
    }

    private func shouldClearBreakerOnSuccess(method: String) -> Bool {
        // A successful sidecar handshake indicates transport is healthy and should reopen traffic.
        method == "sidecar.ensure_ready" || !method.hasPrefix("sidecar.")
    }

    private func markSuccess() {
        stateQueue.sync {
            consecutiveFailures = 0
            breakerOpenedAt = nil
        }
    }

    private func markFailure() {
        stateQueue.sync {
            consecutiveFailures += 1
            if consecutiveFailures >= max(1, config.breakerThreshold) {
                breakerOpenedAt = Date()
            }
        }
    }

    private func callSync(method: String, params: [String: Any], timeoutSec: Int? = nil) throws -> [String: Any] {
        // Route through persistent connection when available
        if usePersistent, persistentFD >= 0 {
            return try callPersistent(method: method, params: params, timeoutSec: timeoutSec)
        }

        // Legacy short-lived connection path
        let effectiveTimeout = max(1, timeoutSec ?? config.timeoutSec)
        let fd = try openUnixSocket(timeoutSec: effectiveTimeout)
        defer { _ = close(fd) }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...Int(Int32.max)),
            "method": method,
            "params": params,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        let sent = payloadData.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        if sent <= 0 {
            throw RPCError.sendFailed
        }

        _ = Darwin.shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let readN = Darwin.read(fd, &buffer, buffer.count)
            if readN < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw RPCError.timeout(method)
                }
                throw RPCError.receiveFailed
            }
            if readN == 0 {
                break
            }
            responseData.append(buffer, count: readN)
        }

        guard
            let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            throw RPCError.invalidResponse
        }

        return try extractRPCResult(root)
    }

    // MARK: - Persistent connection RPC

    /// Send an RPC request over the persistent NDJSON socket and wait for the response.
    private func callPersistent(method: String, params: [String: Any], timeoutSec: Int? = nil) throws -> [String: Any] {
        guard persistentFD >= 0, let reader = persistentReader else {
            throw RPCError.persistentNotConnected
        }
        setSocketTimeout(fd: persistentFD, timeoutSec: max(1, timeoutSec ?? config.timeoutSec))

        let requestID = Int.random(in: 1...Int(Int32.max))
        let payload: [String: Any] = ["id": requestID, "method": method, "params": params]
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(UInt8(ascii: "\n"))

        let sent = line.withUnsafeBytes { Darwin.write(persistentFD, $0.baseAddress, $0.count) }
        if sent <= 0 {
            disconnectPersistent()
            throw RPCError.sendFailed
        }

        // Read NDJSON frames until the response matching our request ID arrives.
        var rawBuf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(persistentFD, &rawBuf, rawBuf.count)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw RPCError.timeout(method) }
                disconnectPersistent(); throw RPCError.receiveFailed
            }
            if n == 0 { disconnectPersistent(); throw RPCError.receiveFailed }

            for frame in reader.append(Data(rawBuf[0..<n])) {
                guard let obj = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
                if obj["event"] != nil { continue }
                if let respID = obj["id"] as? Int, respID == requestID {
                    return try extractRPCResult(obj)
                }
            }
        }
    }

    /// Extract `result` from a parsed RPC response, throwing on error payloads.
    private func extractRPCResult(_ root: [String: Any]) throws -> [String: Any] {
        if let err = root["error"] as? [String: Any] {
            throw RPCError.remoteError(err["message"] as? String ?? "unknown error")
        }
        guard let result = root["result"] as? [String: Any] else { throw RPCError.invalidResponse }
        return result
    }

    // MARK: - Socket helpers

    /// Create a Unix domain socket, connect to `config.socketPath`, and configure timeouts.
    /// The caller owns the returned fd and must close it.
    private func openUnixSocket(timeoutSec: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RPCError.socketCreateFailed }
        setSocketTimeout(fd: fd, timeoutSec: max(1, timeoutSec))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = config.socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > capacity {
            Darwin.close(fd)
            throw RPCError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            _ = pathBytes.withUnsafeBytes { src in
                memcpy(buffer.baseAddress, src.baseAddress, min(buffer.count, src.count))
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw RPCError.connectFailed(reason)
        }
        return fd
    }

    private func setSocketTimeout(fd: Int32, timeoutSec: Int) {
        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
    }
}
