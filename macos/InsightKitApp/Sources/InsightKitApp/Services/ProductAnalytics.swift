import Foundation

private final class InMemoryUserDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: defaultName)
    }

    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }
}

final class ProductAnalyticsEvidenceLedger {
    private let url: URL
    private let retentionDays: Int
    private let queue = DispatchQueue(label: "com.yannjy.insightkit.product-analytics-ledger", qos: .utility)
    private var counts: [String: Int] = [:]
    private var environment: String?
    private var windowStart: String?
    private var windowEnd: String?
    private var retentionExpiresAt: String?
    private var offlinePending = 0
    private var optedOut = false
    private var deletionPending = false

    init(url: URL, retentionDays: Int = 30) {
        self.url = url
        self.retentionDays = retentionDays
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            counts = saved["event_counts"] as? [String: Int] ?? [:]
            environment = saved["environment"] as? String
            windowStart = saved["window_start"] as? String
            windowEnd = saved["window_end"] as? String
            retentionExpiresAt = saved["retention_expires_at"] as? String
            offlinePending = saved["offline_pending"] as? Int ?? 0
            optedOut = saved["opted_out"] as? Bool ?? false
            deletionPending = saved["deletion_pending"] as? Bool ?? false
        }
    }

    func record(_ envelope: Data) {
        queue.async {
            guard let object = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
                  let name = object["event_name"] as? String,
                  let environment = object["environment"] as? String,
                  let timestamp = object["timestamp_utc"] as? String,
                  let timestampDate = ISO8601DateFormatter().date(from: timestamp)
            else { return }
            let properties = object["properties"] as? [String: Any] ?? [:]
            let key = [name, properties["workflow"] as? String ?? "none", properties["analysis_mode"] as? String ?? "none"].joined(separator: "|")
            let formatter = ISO8601DateFormatter()
            let expiry = self.retentionExpiresAt.flatMap(formatter.date(from:))
                ?? self.windowStart.flatMap(formatter.date(from:)).map {
                    $0.addingTimeInterval(Double(self.retentionDays) * 86_400)
                }
            if self.optedOut || self.environment.map({ $0 != environment }) == true
                || expiry.map({ timestampDate >= $0 }) == true {
                self.resetWindow()
            }
            self.counts[key, default: 0] += 1
            self.offlinePending += 1
            self.environment = environment
            self.windowStart = min(self.windowStart ?? timestamp, timestamp)
            let end = formatter.string(from: timestampDate.addingTimeInterval(1))
            self.windowEnd = max(self.windowEnd ?? end, end)
            self.retentionExpiresAt = self.retentionExpiresAt
                ?? formatter.string(from: timestampDate.addingTimeInterval(Double(self.retentionDays) * 86_400))
            self.optedOut = false
            self.persist()
        }
    }

    func update(offlinePending: Int, optedOut: Bool = false, deletionPending: Bool = false) {
        queue.async {
            self.offlinePending = max(0, offlinePending)
            self.optedOut = optedOut
            self.deletionPending = deletionPending
            self.persist()
        }
    }

    func acknowledge(_ count: Int) {
        queue.async {
            self.offlinePending = max(0, self.offlinePending - max(0, count))
            self.persist()
        }
    }

    private func resetWindow() {
        counts.removeAll()
        windowStart = nil
        windowEnd = nil
        retentionExpiresAt = nil
        offlinePending = 0
        deletionPending = false
    }

    private func persist() {
        guard let environment, let windowStart, let windowEnd else { return }
        let manifest: [String: Any] = [
            "schema_version": 1, "environment": environment, "window_start": windowStart,
            "window_end": windowEnd, "event_counts": counts, "offline_pending": offlinePending,
            "opted_out": optedOut, "deletion_pending": deletionPending,
            "retention_expires_at": retentionExpiresAt ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

protocol ProductAnalyticsTransport {
    func send(envelopes: [Data], completion: @escaping (Bool) -> Void)
    func cancelAll()
}

struct MeetingAssetWorkflowSuccess {
    let recordReopenable: Bool
    let transcriptSearchable: Bool
    let smartMinutesValid: Bool
    let exportCompleted: Bool
    let hasBlockingError: Bool

    var isSuccessful: Bool {
        recordReopenable && transcriptSearchable && smartMinutesValid && exportCompleted && !hasBlockingError
    }

    static func evaluate(recordPath: URL?, duration: TimeInterval, exportCompleted: Bool, hasBlockingError: Bool) -> Self {
        guard let recordPath else {
            return .init(recordReopenable: false, transcriptSearchable: false, smartMinutesValid: false, exportCompleted: exportCompleted, hasBlockingError: hasBlockingError)
        }
        let snapshot = MeetingAssetSnapshot.load(recordPath: recordPath, duration: duration)
        return .init(
            recordReopenable: snapshot.health.metadata.isReadable && snapshot.health.media.isReadable,
            transcriptSearchable: snapshot.health.transcript.isReadable && !snapshot.transcriptEntries.isEmpty,
            smartMinutesValid: snapshot.health.smartMinutes.isReadable && snapshot.smartMinutes != nil,
            exportCompleted: exportCompleted,
            hasBlockingError: hasBlockingError
        )
    }
}

final class PostHogProductAnalyticsTransport: ProductAnalyticsTransport {
    private let endpoint: URL
    private let projectKey: String
    private let session: URLSession
    private let lock = NSLock()
    private var tasks: [URLSessionDataTask] = []

    init?(host: String, projectKey: String, session: URLSession = .shared) {
        guard !projectKey.isEmpty, let base = URL(string: host), base.scheme == "https", base.host != nil,
              let endpoint = URL(string: "/batch", relativeTo: base) else { return nil }
        self.endpoint = endpoint; self.projectKey = projectKey; self.session = session
    }

    func send(envelopes: [Data], completion: @escaping (Bool) -> Void) {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.makeBatch(envelopes: envelopes, projectKey: projectKey)
            var task: URLSessionDataTask!
            task = session.dataTask(with: request) { [weak self] _, response, _ in
                self?.lock.lock(); self?.tasks.removeAll { $0 === task }; self?.lock.unlock()
                completion((response as? HTTPURLResponse).map { 200..<300 ~= $0.statusCode } ?? false)
            }
            lock.lock(); tasks.append(task); lock.unlock()
            task.resume()
        } catch { DispatchQueue.global(qos: .utility).async { completion(false) } }
    }

    static func makeBatch(envelopes: [Data], projectKey: String) throws -> Data {
        let events = try envelopes.map { data -> [String: Any] in
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = envelope["event_name"] as? String,
                  let timestamp = envelope["timestamp_utc"] as? String,
                  let installationID = envelope["installation_id"] as? String,
                  let appSessionID = envelope["app_session_id"] as? String,
                  let eventSequence = envelope["event_sequence"] as? Int
            else { throw CocoaError(.fileReadCorruptFile) }
            var properties = envelope["properties"] as? [String: Any] ?? [:]
            for key in ["schema_version", "app_version", "app_build", "environment", "consent_version", "installation_id", "app_session_id", "event_sequence"] {
                properties[key] = envelope[key]
            }
            properties["distinct_id"] = installationID
            properties["$insert_id"] = "\(appSessionID):\(eventSequence)"
            properties["$geoip_disable"] = true
            properties["$process_person_profile"] = false
            return ["event": name, "properties": properties, "timestamp": timestamp]
        }
        return try JSONSerialization.data(withJSONObject: ["api_key": projectKey, "batch": events])
    }

    func cancelAll() {
        lock.lock(); let active = tasks; tasks.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }
}

struct ProductAnalyticsPath: Equatable {
    let analysisMode: String
    let providerClass: String

    static let local = ProductAnalyticsPath(analysisMode: "local", providerClass: "local")
    static let unavailable = ProductAnalyticsPath(analysisMode: "local", providerClass: "none")

    init(analysisMode: String, providerClass: String) {
        self.analysisMode = analysisMode
        self.providerClass = providerClass
    }

    init(provider: String?) {
        let vendor = provider?
            .split(separator: ":", maxSplits: 1)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if vendor == "local" || vendor == "local-extractive" || vendor == "stored" || vendor.isEmpty {
            self = vendor.isEmpty ? .unavailable : .local
        } else {
            self.init(analysisMode: "cloud", providerClass: "byok")
        }
    }

    init(providers: AnalysisProvidersStatus?, analysisMode: AnalysisMode? = nil) {
        self = analysisMode == .local
            ? .local
            : providers?.activeReady == true
            ? ProductAnalyticsPath(analysisMode: "cloud", providerClass: "byok")
            : .unavailable
    }

    static func persistedRecord(at recordPath: URL) -> ProductAnalyticsPath {
        let url = recordPath.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let analysis = object["analysis"] as? [String: Any]
        else { return .unavailable }
        return ProductAnalyticsPath(provider: analysis["provider"] as? String)
    }

    static func provisional(analysisMode: AnalysisMode) -> ProductAnalyticsPath {
        analysisMode == .local
            ? .local
            : ProductAnalyticsPath(analysisMode: "cloud", providerClass: "byok")
    }
}

struct ProductAnalyticsContext: Equatable {
    let workflow: String
    let path: ProductAnalyticsPath
    fileprivate let key: String

    init(workflow: String, path: ProductAnalyticsPath, key: String = UUID().uuidString.lowercased()) {
        self.workflow = workflow
        self.path = path
        self.key = key
    }

    init(attempt: ProductAnalyticsAttemptContext, path: ProductAnalyticsPath) {
        self.init(workflow: attempt.workflow, path: path, key: attempt.key)
    }
}

struct ProductAnalyticsAttemptContext: Hashable {
    let workflow: String
    fileprivate let key = UUID().uuidString.lowercased()
}

enum ExternalTelemetryConsentController {
    static func read(_ completion: @escaping (_ enabled: Bool, _ available: Bool) -> Void) {
        ProductAnalytics.submit { completion($0.isEnabled, $0.isAvailable) }
    }

    static func setEnabled(_ enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        ProductAnalytics.submit { analytics in
            do {
                try analytics.setConsent(enabled: enabled)
                completion(.success(analytics.isEnabled))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

/// Privacy-safe product behavior emitter. All data still passes through the sole
/// ExternalTelemetryPrivacyGate; failures are intentionally local and non-blocking.
final class ProductAnalytics {
    enum ConfigurationError: LocalizedError {
        case transportUnavailable

        var errorDescription: String? { "PostHog 尚未配置，无法启用外部遥测。" }
    }
    private struct Attempt {
        var path: ProductAnalyticsPath
        let startedAt: Date
        let sequence: Int
        var recordSavedEmitted = false
        var reviewOpenedEmitted = false
        var completionEmitted = false
        var qualificationFailureEmitted = false
        var terminalEmitted = false
        var analysisLatencyMS: Int?
    }
    private struct PendingRecovery {
        let path: ProductAnalyticsPath
        let sequence: Int
        let phase: String
        var attemptedEmitted = false
    }

    private static let submissionQueue = DispatchQueue(
        label: "com.yannjy.insightkit.product-analytics-submission",
        qos: .utility
    )

    /// Resolves the runtime singleton away from the caller so Keychain, queue
    /// readback, and filesystem setup can never delay a product interaction.
    static func submit(_ operation: @escaping (ProductAnalytics) -> Void) {
        submissionQueue.async {
            operation(shared)
        }
    }

    var isEnabled: Bool { gate.consent.isEnabled && isAvailable }
    var isAvailable: Bool { !requiresTransportForConsent || transport != nil }

    static func configuredPostHogValues(
        process: [String: String],
        bundleInfo: [String: Any],
        environment: TelemetryEnvironment
    ) -> (host: String, projectKey: String)? {
        let environmentKey = environment.rawValue.uppercased().replacingOccurrences(of: "-", with: "_")
        let bundleEnvironment = environment.rawValue
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
        let bundlePrefix = "InsightKitPostHog\(bundleEnvironment)"
        func value(_ processKey: String, _ bundleKey: String) -> String? {
            for raw in [process[processKey], bundleInfo[bundleKey] as? String] {
                let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { return trimmed }
            }
            return nil
        }
        let retentionVerified: Bool = {
            if let raw = process["POSTHOG_\(environmentKey)_RETENTION_VERIFIED"] {
                return ["1", "true", "yes"].contains(raw.lowercased())
            }
            return bundleInfo["\(bundlePrefix)RetentionVerified"] as? Bool ?? false
        }()
        guard retentionVerified,
              let host = value("POSTHOG_\(environmentKey)_HOST", "\(bundlePrefix)Host"),
              let projectKey = value("POSTHOG_\(environmentKey)_PROJECT_KEY", "\(bundlePrefix)ProjectKey")
        else { return nil }
        return (host, projectKey)
    }

    static let shared: ProductAnalytics = {
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo.environment
        let isUITest = process["INSIGHTKIT_UI_TEST_MODE"] == "1"
        #if DEBUG
        let defaultEnvironment = TelemetryEnvironment.development
        #else
        let defaultEnvironment = TelemetryEnvironment.release
        #endif
        let environment = process["INSIGHTKIT_ANALYTICS_ENVIRONMENT"]
            .flatMap(TelemetryEnvironment.init(rawValue:)) ?? defaultEnvironment
        let configuration = try! ExternalTelemetryConfiguration(environment: environment, retentionDays: 30, maxQueueItems: 1_000)
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let storage: URL
        let gate: ExternalTelemetryPrivacyGate
        if isUITest {
            let root = process["INSIGHTKIT_UI_TEST_CAPTURE_ROOT"].map(URL.init(fileURLWithPath:))
                ?? FileManager.default.temporaryDirectory
            storage = root.appendingPathComponent("ProductAnalytics", isDirectory: true)
            let queueKeyLock = NSLock()
            var queueKey: Data?
            gate = ExternalTelemetryPrivacyGate(
                configuration: configuration,
                appVersion: appVersion,
                appBuild: appBuild,
                defaults: InMemoryUserDefaults(),
                storageDirectory: storage,
                readQueueKey: {
                    queueKeyLock.lock()
                    defer { queueKeyLock.unlock() }
                    return queueKey
                },
                saveQueueKey: { data in
                    queueKeyLock.lock()
                    queueKey = data
                    queueKeyLock.unlock()
                },
                deleteQueueKey: {
                    queueKeyLock.lock()
                    queueKey = nil
                    queueKeyLock.unlock()
                }
            )
        } else {
            storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("InsightKit/Telemetry", isDirectory: true)
            gate = ExternalTelemetryPrivacyGate(
                configuration: configuration,
                appVersion: appVersion,
                appBuild: appBuild,
                storageDirectory: storage
            )
        }
        let postHog = configuredPostHogValues(
            process: process,
            bundleInfo: bundle.infoDictionary ?? [:],
            environment: environment
        )
        let transport = isUITest ? nil : postHog.flatMap {
            PostHogProductAnalyticsTransport(host: $0.host, projectKey: $0.projectKey)
        }
        let ledger = ProductAnalyticsEvidenceLedger(
            url: storage.appendingPathComponent("local-evidence-ledger-v1.json"),
            retentionDays: configuration.retentionDays
        )
        return ProductAnalytics(
            gate: gate,
            transport: transport,
            ledger: ledger,
            onWorkflowSignal: SentryDiagnosticsRuntime.shared.capture,
            requiresTransportForConsent: !isUITest
        )
    }()

    private let gate: ExternalTelemetryPrivacyGate
    private let transport: ProductAnalyticsTransport?
    private let requiresTransportForConsent: Bool
    private let ledger: ProductAnalyticsEvidenceLedger?
    private let flushQueue = DispatchQueue(label: "com.yannjy.insightkit.product-analytics-flush", qos: .utility)
    private let stateLock = NSLock()
    private let transportOperationLock = NSLock()
    private var uploadInFlight = false
    private var uploadEpoch: UInt64 = 0
    private var acceptingEvents: Bool
    private var retryAttempts = 0
    private let maxRetryAttempts = 5
    private var flushRequested = false
    private var attempts: [String: Attempt] = [:]
    private var pendingRecoveries: [String: PendingRecovery] = [:]
    private var observedRecordSequences: [String: Int] = [:]
    private var nextAttemptSequenceByWorkflow: [String: Int] = [:]
    private let now: () -> Date
    private let onWorkflowSignal: (ExternalTelemetryWorkflowSignal) -> Void

    init(
        gate: ExternalTelemetryPrivacyGate,
        transport: ProductAnalyticsTransport? = nil,
        ledger: ProductAnalyticsEvidenceLedger? = nil,
        onWorkflowSignal: @escaping (ExternalTelemetryWorkflowSignal) -> Void = { _ in },
        now: @escaping () -> Date = Date.init,
        requiresTransportForConsent: Bool = false
    ) {
        self.gate = gate
        self.transport = transport
        self.requiresTransportForConsent = requiresTransportForConsent
        self.ledger = ledger
        self.onWorkflowSignal = onWorkflowSignal
        self.now = now
        self.acceptingEvents = gate.consent.isEnabled && (!requiresTransportForConsent || transport != nil)
        if gate.consent.isEnabled && !acceptingEvents {
            NotificationCenter.default.post(name: .externalTelemetryConsentWillRevoke, object: nil)
            let evidence = gate.disableAndPurge()
            ledger?.update(
                offlinePending: evidence.remainingItems,
                optedOut: true,
                deletionPending: !evidence.failureCodes.isEmpty || evidence.remainingItems > 0
            )
        }
        if acceptingEvents, transport != nil {
            flushQueue.async { [weak self] in self?.flush() }
        }
    }

    @discardableResult
    func emit(_ name: String, properties: [String: Any]) -> ExternalTelemetryPrivacyGate.RecordResult {
        guard Self.isAllowedProductEvent(name, properties: properties) else { return .rejected }
        stateLock.lock()
        guard acceptingEvents else { stateLock.unlock(); return .disabled }
        let outcome = gate.record(event: .init(name: name, properties: properties)) { [weak self] envelope in
            self?.ledger?.record(envelope)
        }
        let result = outcome.result
        stateLock.unlock()
        if result == .accepted { flush() }
        return result
    }

    func flush() {
        guard let transport else { return }
        stateLock.lock()
        guard acceptingEvents else { stateLock.unlock(); return }
        guard !uploadInFlight else { flushRequested = true; stateLock.unlock(); return }
        uploadInFlight = true
        flushRequested = false
        let epoch = uploadEpoch
        stateLock.unlock()
        flushQueue.async { [self, gate] in
            guard let batch = try? gate.queuedEnvelopes(), !batch.isEmpty else {
                self.finishUpload(epoch: epoch, tryAgain: false)
                return
            }
            self.transportOperationLock.lock()
            self.stateLock.lock()
            let maySend = self.acceptingEvents && self.uploadEpoch == epoch
            if !maySend {
                self.uploadInFlight = false
                self.stateLock.unlock()
                self.transportOperationLock.unlock()
                return
            }
            self.stateLock.unlock()
            transport.send(envelopes: batch) { success in
                let acknowledged = success && ((try? gate.acknowledgeUploadedEnvelopes(batch)) == true)
                self.stateLock.lock()
                if acknowledged, self.acceptingEvents, self.uploadEpoch == epoch {
                    self.ledger?.acknowledge(batch.count)
                }
                self.stateLock.unlock()
                self.finishUpload(epoch: epoch, tryAgain: acknowledged)
                self.stateLock.lock()
                if success { self.retryAttempts = 0 } else { self.retryAttempts += 1 }
                let shouldRetry = !success && self.retryAttempts <= self.maxRetryAttempts && self.acceptingEvents
                self.stateLock.unlock()
                if shouldRetry {
                    self.flushQueue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.flush() }
                }
            }
            self.transportOperationLock.unlock()
        }
    }

    private func finishUpload(epoch: UInt64, tryAgain: Bool) {
        stateLock.lock()
        guard epoch == uploadEpoch else { stateLock.unlock(); return }
        uploadInFlight = false
        let shouldFlush = tryAgain || flushRequested
        flushRequested = false
        stateLock.unlock()
        if shouldFlush { flush() }
    }

    func setConsent(enabled: Bool) throws {
        if enabled {
            guard isAvailable else { throw ConfigurationError.transportUnavailable }
            try gate.setConsent(enabled: true, consentVersion: 1)
            stateLock.lock()
            attempts.removeAll()
            pendingRecoveries.removeAll()
            observedRecordSequences.removeAll()
            uploadEpoch &+= 1
            acceptingEvents = true
            stateLock.unlock()
            _ = emit("telemetry_consent_changed", properties: ["telemetry_enabled": true])
        } else {
            stateLock.lock()
            acceptingEvents = false
            attempts.removeAll()
            pendingRecoveries.removeAll()
            observedRecordSequences.removeAll()
            uploadEpoch &+= 1
            uploadInFlight = false
            stateLock.unlock()
            transportOperationLock.lock()
            transport?.cancelAll()
            transportOperationLock.unlock()
            let evidence = gate.disableAndPurge()
            ledger?.update(
                offlinePending: evidence.remainingItems,
                optedOut: true,
                deletionPending: !evidence.failureCodes.isEmpty || evidence.remainingItems > 0
            )
        }
    }

    func beginWorkflow(_ workflow: String, provisionalPath: ProductAnalyticsPath) {
        beginWorkflow(key: workflow, workflow: workflow, provisionalPath: provisionalPath)
    }

    func beginWorkflow(_ context: ProductAnalyticsAttemptContext, provisionalPath: ProductAnalyticsPath) {
        beginWorkflow(key: context.key, workflow: context.workflow, provisionalPath: provisionalPath)
    }

    private func beginWorkflow(key: String, workflow: String, provisionalPath: ProductAnalyticsPath) {
        let startedAt = now()
        stateLock.lock()
        let epoch = uploadEpoch
        let attemptSequence = (nextAttemptSequenceByWorkflow[workflow] ?? 0) + 1
        nextAttemptSequenceByWorkflow[workflow] = attemptSequence
        stateLock.unlock()
        guard emit(
            "workflow_started",
            properties: properties(
                workflow: workflow,
                path: provisionalPath,
                phase: "preparing",
                attemptSequence: attemptSequence
            )
        ) == .accepted else { return }
        stateLock.lock()
        guard acceptingEvents, uploadEpoch == epoch else { stateLock.unlock(); return }
        attempts[key] = Attempt(path: provisionalPath, startedAt: startedAt, sequence: attemptSequence)
        stateLock.unlock()
        stateLock.lock()
        let recoveryPhase = pendingRecoveries[key]?.phase
        stateLock.unlock()
        if let recoveryPhase {
            recoveryAttempted(key: key, workflow: workflow, phase: recoveryPhase)
        }
    }

    func resolveWorkflow(
        _ workflow: String,
        path: ProductAnalyticsPath,
        analysisLatencyMilliseconds: Int? = nil
    ) {
        resolveWorkflow(key: workflow, path: path, analysisLatencyMilliseconds: analysisLatencyMilliseconds)
    }

    func resolveWorkflow(
        _ context: ProductAnalyticsAttemptContext,
        path: ProductAnalyticsPath,
        analysisLatencyMilliseconds: Int? = nil
    ) {
        resolveWorkflow(key: context.key, path: path, analysisLatencyMilliseconds: analysisLatencyMilliseconds)
    }

    private func resolveWorkflow(key: String, path: ProductAnalyticsPath, analysisLatencyMilliseconds: Int?) {
        stateLock.lock()
        guard var attempt = attempts[key] else { stateLock.unlock(); return }
        attempt.path = path
        if let analysisLatencyMilliseconds {
            attempt.analysisLatencyMS = max(0, analysisLatencyMilliseconds)
        }
        attempts[key] = attempt
        stateLock.unlock()
    }

    func observeRecord(_ context: ProductAnalyticsContext) {
        stateLock.lock()
        guard observedRecordSequences[context.key] == nil else { stateLock.unlock(); return }
        let epoch = uploadEpoch
        let attemptSequence = (nextAttemptSequenceByWorkflow[context.workflow] ?? 0) + 1
        nextAttemptSequenceByWorkflow[context.workflow] = attemptSequence
        stateLock.unlock()
        let values = properties(
            workflow: context.workflow,
            path: context.path,
            phase: "reviewing",
            attemptSequence: attemptSequence
        )
        guard emit("record_reopened", properties: values) == .accepted else { return }
        stateLock.lock()
        guard acceptingEvents, uploadEpoch == epoch else { stateLock.unlock(); return }
        observedRecordSequences[context.key] = attemptSequence
        stateLock.unlock()
        _ = emit("smart_minutes_review_opened", properties: values)
    }

    func registerSearchContext(_ context: ProductAnalyticsContext) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard observedRecordSequences[context.key] == nil else { return }
        if let sequence = attempts[context.key]?.sequence {
            observedRecordSequences[context.key] = sequence
        } else {
            let sequence = (nextAttemptSequenceByWorkflow[context.workflow] ?? 0) + 1
            nextAttemptSequenceByWorkflow[context.workflow] = sequence
            observedRecordSequences[context.key] = sequence
        }
    }

    func recordSaved(_ workflow: String, path: ProductAnalyticsPath? = nil) {
        recordSaved(key: workflow, workflow: workflow, path: path)
    }

    func recordSaved(_ context: ProductAnalyticsAttemptContext, path: ProductAnalyticsPath? = nil) {
        recordSaved(key: context.key, workflow: context.workflow, path: path)
    }

    private func recordSaved(key: String, workflow: String, path: ProductAnalyticsPath?) {
        if let path { resolveWorkflow(key: key, path: path, analysisLatencyMilliseconds: nil) }
        guard let context = context(for: key) else { return }
        stateLock.lock()
        guard attempts[key]?.recordSavedEmitted == false else { stateLock.unlock(); return }
        stateLock.unlock()
        guard emit(
            "record_saved",
            properties: properties(
                workflow: workflow,
                path: context.path,
                phase: "finalizing",
                outcome: "succeeded",
                attemptSequence: context.sequence
            )
        ) == .accepted else { return }
        stateLock.lock()
        attempts[key]?.recordSavedEmitted = true
        stateLock.unlock()
    }

    func reviewOpened(_ workflow: String) {
        reviewOpened(key: workflow, workflow: workflow)
    }

    func reviewOpened(_ context: ProductAnalyticsAttemptContext) {
        reviewOpened(key: context.key, workflow: context.workflow)
    }

    private func reviewOpened(key: String, workflow: String) {
        guard let context = context(for: key) else { return }
        stateLock.lock()
        if attempts[key] != nil {
            guard attempts[key]?.reviewOpenedEmitted == false else { stateLock.unlock(); return }
        }
        stateLock.unlock()
        guard emit(
            "smart_minutes_review_opened",
            properties: properties(
                workflow: workflow,
                path: context.path,
                phase: "reviewing",
                attemptSequence: context.sequence
            )
        ) == .accepted else { return }
        stateLock.lock()
        attempts[key]?.reviewOpenedEmitted = true
        stateLock.unlock()
    }

    func transcriptSearchCompleted(_ context: ProductAnalyticsContext, resultCount: Int) {
        var values = properties(
            workflow: context.workflow,
            path: context.path,
            phase: "reviewing",
            attemptSequence: observedRecordSequence(for: context)
        )
        values["result_count"] = min(max(resultCount, 0), 10_000)
        _ = emit("transcript_search_completed", properties: values)
    }

    func exportAttempted(_ workflow: String) {
        recoveryAttempted(workflow, phase: "exporting")
    }

    func exportAttempted(_ context: ProductAnalyticsAttemptContext) {
        recoveryAttempted(context, phase: "exporting")
    }

    func exportCompleted(_ workflow: String, explicitPath: ProductAnalyticsPath? = nil) {
        if let explicitPath {
            _ = emit("export_completed", properties: properties(workflow: workflow, path: explicitPath, phase: "exporting", outcome: "succeeded"))
            return
        }
        guard let context = context(for: workflow) else { return }
        _ = emit(
            "export_completed",
            properties: properties(
                workflow: workflow,
                path: context.path,
                phase: "exporting",
                outcome: "succeeded",
                attemptSequence: context.sequence
            )
        )
        recoveryCompleted(workflow, phase: "exporting", succeeded: true)
    }

    func exportCompleted(_ context: ProductAnalyticsAttemptContext) {
        guard let attempt = self.context(for: context.key) else { return }
        _ = emit(
            "export_completed",
            properties: properties(
                workflow: context.workflow,
                path: attempt.path,
                phase: "exporting",
                outcome: "succeeded",
                attemptSequence: attempt.sequence
            )
        )
        recoveryCompleted(context, phase: "exporting", succeeded: true)
    }

    func exportCompleted(_ context: ProductAnalyticsContext) {
        guard let attemptSequence = observedRecordSequence(for: context) else { return }
        _ = emit(
            "export_completed",
            properties: properties(
                workflow: context.workflow,
                path: context.path,
                phase: "exporting",
                outcome: "succeeded",
                attemptSequence: attemptSequence
            )
        )
    }

    func workflowCompleted(_ workflow: String, evaluation: MeetingAssetWorkflowSuccess) {
        workflowCompleted(key: workflow, workflow: workflow, evaluation: evaluation)
    }

    func workflowCompleted(_ context: ProductAnalyticsAttemptContext, evaluation: MeetingAssetWorkflowSuccess) {
        workflowCompleted(key: context.key, workflow: context.workflow, evaluation: evaluation)
    }

    private func workflowCompleted(key: String, workflow: String, evaluation: MeetingAssetWorkflowSuccess) {
        guard evaluation.isSuccessful else {
            stateLock.lock()
            guard attempts[key]?.qualificationFailureEmitted == false else { stateLock.unlock(); return }
            attempts[key]?.qualificationFailureEmitted = true
            stateLock.unlock()
            guard workflowFailed(
                key: key,
                workflow: workflow,
                phase: "finalizing",
                errorCode: "unknown",
                recoveryAction: "none",
                analysisLatencyMilliseconds: nil
            ) else {
                stateLock.lock()
                attempts[key]?.qualificationFailureEmitted = false
                stateLock.unlock()
                return
            }
            return
        }
        guard let context = context(for: key) else { return }
        stateLock.lock()
        guard attempts[key]?.completionEmitted == false else { stateLock.unlock(); return }
        stateLock.unlock()
        var values = terminalProperties(workflow: workflow, context: context, phase: "finalizing", outcome: "succeeded")
        values["recovery_action"] = "none"
        guard emit("workflow_completed", properties: values) == .accepted else { return }
        stateLock.lock()
        attempts[key]?.completionEmitted = true
        attempts[key]?.terminalEmitted = true
        let recoveryPhase = pendingRecoveries[key]?.phase
        stateLock.unlock()
        if let recoveryPhase {
            recoveryCompleted(key: key, workflow: workflow, phase: recoveryPhase, succeeded: true)
        }
    }

    func workflowFailed(
        _ workflow: String,
        phase: String,
        errorCode: String,
        recoveryAction: String,
        explicitPath: ProductAnalyticsPath? = nil,
        completingRecovery: Bool = false,
        analysisLatencyMilliseconds: Int? = nil
    ) {
        if let explicitPath {
            if completingRecovery {
                recoveryCompleted(workflow, phase: phase, succeeded: false, explicitPath: explicitPath)
            }
            var values = properties(workflow: workflow, path: explicitPath, phase: phase, outcome: "failed")
            values["error_code"] = errorCode
            values["recovery_action"] = recoveryAction
            _ = emitWorkflowFailure(
                values,
                workflow: workflow,
                path: explicitPath,
                phase: phase,
                errorCode: errorCode,
                recoveryResult: completingRecovery ? .failed : .notAttempted
            )
            return
        }
        workflowFailed(
            key: workflow,
            workflow: workflow,
            phase: phase,
            errorCode: errorCode,
            recoveryAction: recoveryAction,
            analysisLatencyMilliseconds: analysisLatencyMilliseconds
        )
    }

    func workflowFailed(
        _ context: ProductAnalyticsAttemptContext,
        phase: String,
        errorCode: String,
        recoveryAction: String,
        analysisLatencyMilliseconds: Int? = nil
    ) {
        workflowFailed(
            key: context.key,
            workflow: context.workflow,
            phase: phase,
            errorCode: errorCode,
            recoveryAction: recoveryAction,
            analysisLatencyMilliseconds: analysisLatencyMilliseconds
        )
    }

    func workflowFailed(
        _ context: ProductAnalyticsContext,
        phase: String,
        errorCode: String,
        recoveryAction: String,
        completingRecovery: Bool = false
    ) {
        guard let attemptSequence = observedRecordSequence(for: context) else { return }
        if completingRecovery {
            recoveryCompleted(context, phase: phase, succeeded: false)
        }
        var values = properties(
            workflow: context.workflow,
            path: context.path,
            phase: phase,
            outcome: "failed",
            attemptSequence: attemptSequence
        )
        values["error_code"] = errorCode
        values["recovery_action"] = recoveryAction
        _ = emitWorkflowFailure(
            values,
            workflow: context.workflow,
            path: context.path,
            phase: phase,
            errorCode: errorCode,
            recoveryResult: completingRecovery ? .failed : .notAttempted
        )
    }

    @discardableResult
    private func workflowFailed(
        key: String,
        workflow: String,
        phase: String,
        errorCode: String,
        recoveryAction: String,
        analysisLatencyMilliseconds: Int?
    ) -> Bool {
        if let analysisLatencyMilliseconds {
            stateLock.lock()
            attempts[key]?.analysisLatencyMS = max(0, analysisLatencyMilliseconds)
            stateLock.unlock()
        }
        guard let context = context(for: key) else { return false }
        stateLock.lock()
        let pendingRecoveryPhase = pendingRecoveries[key]?.phase
        stateLock.unlock()
        if let pendingRecoveryPhase {
            recoveryCompleted(key: key, workflow: workflow, phase: pendingRecoveryPhase, succeeded: false)
        }
        var values = terminalProperties(workflow: workflow, context: context, phase: phase, outcome: "failed")
        values["error_code"] = errorCode
        values["recovery_action"] = recoveryAction
        guard emitWorkflowFailure(
            values,
            workflow: workflow,
            path: context.path,
            phase: phase,
            errorCode: errorCode,
            recoveryResult: pendingRecoveryPhase == nil ? .notAttempted : .failed
        ) else { return false }
        stateLock.lock()
        attempts[key]?.terminalEmitted = true
        pendingRecoveries[key] = recoveryAction == "none"
            ? nil
            : PendingRecovery(path: context.path, sequence: context.sequence, phase: phase)
        stateLock.unlock()
        return true
    }

    @discardableResult
    private func emitWorkflowFailure(
        _ values: [String: Any],
        workflow: String,
        path: ProductAnalyticsPath,
        phase: String,
        errorCode: String,
        recoveryResult: ExternalTelemetryRecoveryResult
    ) -> Bool {
        if let context = Self.workflowFailureContext(
            workflow: workflow,
            path: path,
            phase: phase,
            errorCode: errorCode,
            recoveryResult: recoveryResult
        ) {
            onWorkflowSignal(.failure(context))
        }
        return emit("workflow_failed", properties: values) == .accepted
    }

    private static func workflowFailureContext(
        workflow: String,
        path: ProductAnalyticsPath,
        phase: String,
        errorCode: String,
        recoveryResult: ExternalTelemetryRecoveryResult
    ) -> ExternalTelemetryWorkflowFailureContext? {
        guard let workflow = ExternalTelemetryWorkflow(rawValue: workflow),
              let phase = ExternalTelemetryPhase(rawValue: phase),
              let provider = ExternalTelemetryProviderClass(rawValue: path.providerClass)
        else { return nil }
        let category: ExternalTelemetryErrorCategory
        switch errorCode {
        case "configuration": category = .configuration
        case "permission-denied": category = .permission
        case "runtime-unavailable", "provider-unavailable": category = .runtime
        case "storage": category = .storage
        case "unknown": category = .unknown
        default: return nil
        }
        return ExternalTelemetryWorkflowFailureContext(
            workflow: workflow,
            phase: phase,
            engineClass: .local,
            providerClass: provider,
            errorCategory: category,
            recoveryResult: recoveryResult
        )
    }

    func workflowCancelled(_ workflow: String, phase: String = "running") {
        workflowCancelled(key: workflow, workflow: workflow, phase: phase)
    }

    func workflowCancelled(_ context: ProductAnalyticsAttemptContext, phase: String = "running") {
        workflowCancelled(key: context.key, workflow: context.workflow, phase: phase)
    }

    private func workflowCancelled(key: String, workflow: String, phase: String) {
        guard let context = context(for: key) else { return }
        stateLock.lock()
        let shouldEmitTerminal = attempts[key]?.terminalEmitted == false
        let recoveryPhase = pendingRecoveries[key]?.phase
        stateLock.unlock()
        if shouldEmitTerminal {
            var values = terminalProperties(workflow: workflow, context: context, phase: phase, outcome: "cancelled")
            values["recovery_action"] = "none"
            _ = emit("workflow_failed", properties: values)
        }
        if let recoveryPhase {
            recoveryCompleted(key: key, workflow: workflow, phase: recoveryPhase, succeeded: false)
        }
        stateLock.lock()
        if attempts[key]?.sequence == context.sequence {
            attempts[key] = nil
            pendingRecoveries[key] = nil
        }
        stateLock.unlock()
    }

    func recoveryAttempted(_ workflow: String, phase: String, explicitPath: ProductAnalyticsPath? = nil) {
        if let explicitPath {
            var values = properties(workflow: workflow, path: explicitPath, phase: phase)
            values["recovery_action"] = "retry"
            _ = emit("recovery_attempted", properties: values)
            return
        }
        recoveryAttempted(key: workflow, workflow: workflow, phase: phase)
    }

    func recoveryAttempted(_ context: ProductAnalyticsAttemptContext, phase: String) {
        recoveryAttempted(key: context.key, workflow: context.workflow, phase: phase)
    }

    func recoveryAttempted(_ context: ProductAnalyticsContext, phase: String) {
        guard let attemptSequence = observedRecordSequence(for: context) else { return }
        var values = properties(
            workflow: context.workflow,
            path: context.path,
            phase: phase,
            attemptSequence: attemptSequence
        )
        values["recovery_action"] = "retry"
        _ = emit("recovery_attempted", properties: values)
    }

    private func recoveryAttempted(key: String, workflow: String, phase: String) {
        stateLock.lock()
        guard let recovery = pendingRecoveries[key], recovery.phase == phase, !recovery.attemptedEmitted else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        var values = properties(
            workflow: workflow,
            path: recovery.path,
            phase: phase,
            attemptSequence: recovery.sequence
        )
        values["recovery_action"] = "retry"
        guard emit("recovery_attempted", properties: values) == .accepted else { return }
        stateLock.lock()
        if pendingRecoveries[key]?.sequence == recovery.sequence {
            pendingRecoveries[key]?.attemptedEmitted = true
        }
        stateLock.unlock()
    }

    func recoveryCompleted(
        _ workflow: String,
        phase: String,
        succeeded: Bool,
        explicitPath: ProductAnalyticsPath? = nil
    ) {
        if let explicitPath {
            var values = properties(workflow: workflow, path: explicitPath, phase: phase, outcome: succeeded ? "succeeded" : "failed")
            values["recovery_action"] = "retry"
            _ = emitRecoveryCompleted(values, workflow: workflow, path: explicitPath, phase: phase, succeeded: succeeded)
            return
        }
        recoveryCompleted(key: workflow, workflow: workflow, phase: phase, succeeded: succeeded)
    }

    func recoveryCompleted(_ context: ProductAnalyticsAttemptContext, phase: String, succeeded: Bool) {
        recoveryCompleted(key: context.key, workflow: context.workflow, phase: phase, succeeded: succeeded)
    }

    func recoveryCompleted(_ context: ProductAnalyticsContext, phase: String, succeeded: Bool) {
        guard let attemptSequence = observedRecordSequence(for: context) else { return }
        var values = properties(
            workflow: context.workflow,
            path: context.path,
            phase: phase,
            outcome: succeeded ? "succeeded" : "failed",
            attemptSequence: attemptSequence
        )
        values["recovery_action"] = "retry"
        _ = emitRecoveryCompleted(
            values,
            workflow: context.workflow,
            path: context.path,
            phase: phase,
            succeeded: succeeded
        )
    }

    private func recoveryCompleted(key: String, workflow: String, phase: String, succeeded: Bool) {
        stateLock.lock()
        guard let recovery = pendingRecoveries[key], recovery.phase == phase else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        var values = properties(
            workflow: workflow,
            path: recovery.path,
            phase: phase,
            outcome: succeeded ? "succeeded" : "failed",
            attemptSequence: recovery.sequence
        )
        values["recovery_action"] = "retry"
        guard emitRecoveryCompleted(
            values,
            workflow: workflow,
            path: context.path,
            phase: phase,
            succeeded: succeeded
        ) else { return }
        stateLock.lock()
        if pendingRecoveries[key]?.sequence == recovery.sequence {
            pendingRecoveries[key] = nil
        }
        stateLock.unlock()
    }

    @discardableResult
    private func emitRecoveryCompleted(
        _ values: [String: Any],
        workflow: String,
        path: ProductAnalyticsPath,
        phase: String,
        succeeded: Bool
    ) -> Bool {
        if let workflow = ExternalTelemetryWorkflow(rawValue: workflow),
           let phase = ExternalTelemetryPhase(rawValue: phase),
           let provider = ExternalTelemetryProviderClass(rawValue: path.providerClass) {
            onWorkflowSignal(.recovery(.init(
                workflow: workflow,
                phase: phase,
                engineClass: .local,
                providerClass: provider,
                result: succeeded ? .succeeded : .failed
            )))
        }
        return emit("recovery_completed", properties: values) == .accepted
    }

    private func context(for key: String) -> (path: ProductAnalyticsPath, startedAt: Date, analysisLatencyMS: Int?, sequence: Int)? {
        stateLock.lock()
        guard let attempt = attempts[key] else { stateLock.unlock(); return nil }
        stateLock.unlock()
        return (attempt.path, attempt.startedAt, attempt.analysisLatencyMS, attempt.sequence)
    }

    private func observedRecordSequence(for context: ProductAnalyticsContext) -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return observedRecordSequences[context.key]
    }

    private func properties(
        workflow: String,
        path: ProductAnalyticsPath,
        phase: String,
        outcome: String? = nil,
        attemptSequence: Int? = nil
    ) -> [String: Any] {
        var values: [String: Any] = [
            "workflow": workflow,
            "analysis_mode": path.analysisMode,
            "provider_class": path.providerClass,
            "phase": phase,
        ]
        if let outcome { values["outcome"] = outcome }
        return values
    }

    private func terminalProperties(
        workflow: String,
        context: (path: ProductAnalyticsPath, startedAt: Date, analysisLatencyMS: Int?, sequence: Int),
        phase: String,
        outcome: String
    ) -> [String: Any] {
        let elapsedMS = max(0, Int(now().timeIntervalSince(context.startedAt) * 1_000))
        var values = properties(workflow: workflow, path: context.path, phase: phase, outcome: outcome)
        values["duration_bucket_ms"] = Self.bucket(elapsedMS, allowed: [1_000, 5_000, 15_000, 30_000, 60_000, 300_000, 900_000, 1_800_000, 3_600_000])
        if let analysisLatencyMS = context.analysisLatencyMS {
            values["latency_bucket_ms"] = Self.bucket(analysisLatencyMS, allowed: [100, 250, 500, 1_000, 5_000, 15_000, 30_000, 60_000, 300_000])
        }
        return values
    }

    private static func bucket(_ value: Int, allowed: [Int]) -> Int {
        allowed.first(where: { value <= $0 }) ?? allowed.last!
    }

    private static func isAllowedProductEvent(_ name: String, properties: [String: Any]) -> Bool {
        guard let allowedProperties = productSchema[name],
              Set(properties.keys).isSubset(of: allowedProperties)
        else { return false }
        if let workflow = properties["workflow"] as? String, !["live", "import"].contains(workflow) { return false }
        if let mode = properties["analysis_mode"] as? String, !["local", "cloud"].contains(mode) { return false }
        if let provider = properties["provider_class"] as? String, !["local", "byok", "none"].contains(provider) { return false }
        return true
    }

    private static let workflowProperties: Set<String> = [
        "workflow", "analysis_mode", "provider_class", "phase", "outcome",
        "error_code", "recovery_action", "duration_bucket_ms", "latency_bucket_ms",
        "retry_count", "result_count", "module_count", "quality_score",
    ]

    private static let productSchema: [String: Set<String>] = [
        "workflow_started": workflowProperties,
        "record_saved": workflowProperties,
        "record_reopened": workflowProperties,
        "transcript_search_completed": workflowProperties,
        "smart_minutes_review_opened": workflowProperties,
        "export_completed": workflowProperties,
        "workflow_completed": workflowProperties,
        "workflow_failed": workflowProperties,
        "recovery_attempted": workflowProperties,
        "recovery_completed": workflowProperties,
        "telemetry_consent_changed": ["telemetry_enabled"],
    ]
}
