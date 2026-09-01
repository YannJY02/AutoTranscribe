import Foundation
import Darwin
import MachO
import CryptoKit

func currentExternalTelemetryFailureStack() -> [UInt64] {
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let count = backtrace(&frames, Int32(frames.count))
    guard count > 0 else { return [] }
    return frames.prefix(Int(count)).compactMap { $0.map { UInt64(UInt(bitPattern: $0)) } }
}

private func mainExecutableFrames(_ frames: [UInt64]) -> [UInt64] {
    guard let mainImage = _dyld_get_image_header(0) else { return [] }
    let mainBase = UnsafeRawPointer(mainImage)
    return frames.filter { address in
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else { return false }
        var info = Dl_info()
        return dladdr(pointer, &info) != 0 && info.dli_fbase == mainBase
    }
}

private func mainExecutableFrameOffsets(_ frames: [UInt64]) -> [UInt64] {
    guard let mainImage = _dyld_get_image_header(0) else { return [] }
    let base = UInt64(UInt(bitPattern: UnsafeRawPointer(mainImage)))
    return mainExecutableFrames(frames).prefix(64).compactMap { address in
        guard address >= base else { return nil }
        return address - base
    }
}

private func mainExecutableFrames(fromOffsets offsets: [UInt64]) -> [UInt64] {
    guard let mainImage = _dyld_get_image_header(0) else { return [] }
    let base = UInt64(UInt(bitPattern: UnsafeRawPointer(mainImage)))
    let candidates = offsets.prefix(64).compactMap { offset -> UInt64? in
        let (address, overflow) = base.addingReportingOverflow(offset)
        return overflow ? nil : address
    }
    return mainExecutableFrames(candidates)
}

private func mainExecutableDebugID() -> String? {
    guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else { return nil }
    let commandStart = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    var offset = 0
    for _ in 0 ..< header.pointee.ncmds {
        let command = commandStart.advanced(by: offset).assumingMemoryBound(to: load_command.self).pointee
        if command.cmd == LC_UUID {
            let uuidCommand = commandStart.advanced(by: offset).assumingMemoryBound(to: uuid_command.self).pointee
            return UUID(uuid: uuidCommand.uuid).uuidString
        }
        offset += Int(command.cmdsize)
    }
    return nil
}

/// Vendor-neutral seam implemented by the local proof transport and, when owner
/// configuration exists, a Sentry SDK transport. It receives only gate-approved JSON.
protocol SentryDiagnosticsTransport {
    func send(envelope: Data, failureStack: [UInt64]) throws
    func cancelAll()
    func resume()
}

extension SentryDiagnosticsTransport {
    func cancelAll() {}
    func resume() {}
}

final class SentryDiagnosticsAdapter {
    enum ReleaseSessionStatus: String { case ok, exited, crashed, abnormal }
    typealias Workflow = ExternalTelemetryWorkflow
    typealias Phase = ExternalTelemetryPhase
    typealias EngineClass = ExternalTelemetryEngineClass
    typealias ProviderClass = ExternalTelemetryProviderClass
    typealias ErrorCategory = ExternalTelemetryErrorCategory
    typealias RecoveryResult = ExternalTelemetryRecoveryResult

    struct Failure {
        let workflow: Workflow
        let phase: Phase
        let engineClass: EngineClass
        let providerClass: ProviderClass
        let errorCategory: ErrorCategory
        let recoveryResult: RecoveryResult
        let failureStack: [UInt64]

        // Deliberately accepted only so callers can hand the adapter vendor-shaped
        // failures. These prohibited fields are never inspected or serialized.
        let errorMessage: String?
        let breadcrumbs: [String]
        let contexts: [String: Any]
        let attachments: [Data]

        init(
            workflow: Workflow,
            phase: Phase,
            engineClass: EngineClass,
            providerClass: ProviderClass,
            errorCategory: ErrorCategory,
            recoveryResult: RecoveryResult,
            failureStack: [UInt64] = currentExternalTelemetryFailureStack(),
            errorMessage: String? = nil,
            breadcrumbs: [String] = [],
            contexts: [String: Any] = [:],
            attachments: [Data] = []
        ) {
            self.workflow = workflow
            self.phase = phase
            self.engineClass = engineClass
            self.providerClass = providerClass
            self.errorCategory = errorCategory
            self.recoveryResult = recoveryResult
            self.failureStack = failureStack
            self.errorMessage = errorMessage
            self.breadcrumbs = breadcrumbs
            self.contexts = contexts
            self.attachments = attachments
        }

        static var syntheticFailure: Failure { Failure(
            workflow: .live,
            phase: .running,
            engineClass: .local,
            providerClass: .none,
            errorCategory: .runtime,
            recoveryResult: .succeeded
        ) }

    }

    private let gate: ExternalTelemetryPrivacyGate
    private let transport: SentryDiagnosticsTransport
    private let deliveryQueue = DispatchQueue(label: "com.yannjy.insightkit.sentry-delivery", qos: .utility)
    private let deliverySlots = DispatchSemaphore(value: 1)
    private let deliveryStateLock = NSLock()
    private let consentReconciliationLock = NSLock()
    private let diagnosticsLock = NSLock()
    private let releaseSessionLock = NSLock()
    private var acceptingDelivery: Bool
    private var capacityDrainNeeded = false
    private var capacityDrainScheduled = false
    private var retainedFailureStacks: [Data: [UInt64]] = [:]
    private var releaseSessionMayStart = true
    private var deliveryFailureCount = 0
    private var consentObservers: [NSObjectProtocol] = []
    private var distributedConsentObservers: [NSObjectProtocol] = []
    private var deliveredRetainedEnvelopes: Set<Data> = []

    var localDeliveryFailureCount: Int {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return deliveryFailureCount
    }

    init(gate: ExternalTelemetryPrivacyGate, transport: SentryDiagnosticsTransport) {
        self.gate = gate
        self.transport = transport
        acceptingDelivery = gate.consent.isEnabled
        consentObservers.append(NotificationCenter.default.addObserver(
            forName: .externalTelemetryConsentWillRevoke,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.reconcileDeliveryWithPersistedConsent() })
        consentObservers.append(NotificationCenter.default.addObserver(
            forName: .externalTelemetryConsentDidEnable,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.reconcileDeliveryWithPersistedConsent() })
        distributedConsentObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: .externalTelemetryConsentWillRevoke,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.reconcileDeliveryWithPersistedConsent() })
        distributedConsentObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: .externalTelemetryConsentDidEnable,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.reconcileDeliveryWithPersistedConsent() })
        reconcileDeliveryWithPersistedConsent()
        deliveryQueue.async { [weak self] in self?.drainPersistedQueue() }
    }

    deinit {
        consentObservers.forEach(NotificationCenter.default.removeObserver)
        distributedConsentObservers.forEach(DistributedNotificationCenter.default().removeObserver)
    }

    private func revokeDelivery() {
        deliveryStateLock.lock()
        let wasAcceptingDelivery = acceptingDelivery
        acceptingDelivery = false
        capacityDrainNeeded = false
        retainedFailureStacks.removeAll()
        deliveryStateLock.unlock()
        guard wasAcceptingDelivery else { return }
        transport.cancelAll()
        deliveryQueue.async { [weak self] in self?.deliveredRetainedEnvelopes.removeAll() }
    }

    private func enableDelivery() {
        deliveryStateLock.lock()
        guard !acceptingDelivery else {
            deliveryStateLock.unlock()
            return
        }
        gate.rotateAppSessionIdentity()
        transport.resume()
        acceptingDelivery = true
        deliveryStateLock.unlock()
        startReleaseSessionAfterDrainingQueue()
    }

    private func reconcileDeliveryWithPersistedConsent() {
        consentReconciliationLock.lock()
        defer { consentReconciliationLock.unlock() }
        if gate.consent.isEnabled { enableDelivery() } else { revokeDelivery() }
    }

    func startReleaseSessionAfterDrainingQueue() {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.releaseSessionLock.lock()
            defer { self.releaseSessionLock.unlock() }
            guard self.releaseSessionMayStart else { return }
            _ = self.captureReleaseSession(.ok)
        }
    }

    func endReleaseSession(_ status: ReleaseSessionStatus) {
        releaseSessionLock.lock()
        releaseSessionMayStart = false
        releaseSessionLock.unlock()
        _ = captureReleaseSession(status)
    }

    private var mayDeliver: Bool {
        deliveryStateLock.lock()
        defer { deliveryStateLock.unlock() }
        return acceptingDelivery
    }

    @discardableResult
    func capture(_ failure: Failure) -> ExternalTelemetryPrivacyGate.RecordResult {
        let imageID = mainExecutableDebugID()
        let offsets = imageID == nil ? [] : mainExecutableFrameOffsets(failure.failureStack)
        let outcome = gate.record(event: .init(name: "workflow_failed", properties: [
            "workflow": failure.workflow.rawValue,
            "phase": failure.phase.rawValue,
            "engine_class": failure.engineClass.rawValue,
            "provider_class": failure.providerClass.rawValue,
            "error_category": failure.errorCategory.rawValue,
            "recovery_result": failure.recoveryResult.rawValue,
        ], failureFrameOffsets: offsets, failureImageID: offsets.isEmpty ? nil : imageID))
        do {
            try gate.incrementReleaseSessionErrorCount()
        } catch {
            recordDeliveryFailure()
        }
        guard outcome.result == .accepted, let envelope = outcome.debugEnvelope else {
            return outcome.result
        }
        guard scheduleDelivery(envelope, failureStack: failure.failureStack, acknowledge: true) else { return .queueFull }
        return outcome.result
    }

    @discardableResult
    func captureReleaseSession(_ status: ReleaseSessionStatus) -> ExternalTelemetryPrivacyGate.RecordResult {
        if status == .ok {
            return deliver(gate.record(event: .init(
                name: "release_session_started",
                properties: [
                    "session_status": status.rawValue,
                    "session_error_count": 0,
                    "session_start_delivered": false,
                ]
            ), replacingOldestWhenFull: true), acknowledge: false)
        }
        let envelope: Data
        do {
            guard let terminal = try gate.closeReleaseSession(status: status.rawValue) else { return .disabled }
            envelope = terminal
        } catch {
            recordDeliveryFailure()
            return .disabled
        }
        scheduleDelivery(envelope, failureStack: [], acknowledge: true)
        return .accepted
    }

    @discardableResult
    func capturePerformance(
        workflow: Workflow,
        phase: Phase,
        durationMilliseconds: Int
    ) -> ExternalTelemetryPrivacyGate.RecordResult {
        let buckets = [1_000, 5_000, 15_000, 30_000, 60_000, 300_000, 900_000, 1_800_000, 3_600_000]
        let bounded = buckets.first(where: { durationMilliseconds <= $0 }) ?? 3_600_000
        return deliver(gate.record(event: .init(name: "workflow_completed", properties: [
            "workflow": workflow.rawValue,
            "phase": phase.rawValue,
            "duration_bucket_ms": bounded,
            "outcome": "succeeded",
        ])))
    }

    @discardableResult
    func captureRecovery(_ recovery: ExternalTelemetryWorkflowRecoveryContext) -> ExternalTelemetryPrivacyGate.RecordResult {
        deliver(gate.record(event: .init(name: "recovery_completed", properties: [
            "workflow": recovery.workflow.rawValue,
            "phase": recovery.phase.rawValue,
            "engine_class": recovery.engineClass.rawValue,
            "provider_class": recovery.providerClass.rawValue,
            "recovery_result": recovery.result.rawValue,
        ])))
    }

    private func deliver(
        _ outcome: ExternalTelemetryPrivacyGate.RecordOutcome,
        acknowledge: Bool = true
    ) -> ExternalTelemetryPrivacyGate.RecordResult {
        guard outcome.result == .accepted, let envelope = outcome.debugEnvelope else { return outcome.result }
        guard scheduleDelivery(envelope, failureStack: [], acknowledge: acknowledge) else { return .queueFull }
        return outcome.result
    }

    @discardableResult
    private func scheduleDelivery(_ envelope: Data, failureStack: [UInt64], acknowledge: Bool) -> Bool {
        guard deliverySlots.wait(timeout: .now()) == .success else {
            retainFailureStack(failureStack, for: envelope)
            markCapacityDrainNeeded()
            return false
        }
        deliveryQueue.async { [weak self, deliverySlots] in
            defer {
                deliverySlots.signal()
                self?.scheduleCapacityDrainIfNeeded()
            }
            guard let self, self.mayDeliver else { return }
            guard self.gate.consent.isEnabled else { return }
            do {
                try self.sendQueuedEnvelope(envelope, failureStack: failureStack, acknowledge: acknowledge)
            } catch {
                self.retainFailureStack(failureStack, for: envelope)
                self.recordDeliveryFailure()
                self.markCapacityDrainNeeded()
            }
        }
        return true
    }

    private func markCapacityDrainNeeded() {
        deliveryStateLock.lock()
        capacityDrainNeeded = true
        deliveryStateLock.unlock()
    }

    private func scheduleCapacityDrainIfNeeded() {
        deliveryStateLock.lock()
        guard acceptingDelivery, capacityDrainNeeded, !capacityDrainScheduled else {
            deliveryStateLock.unlock()
            return
        }
        capacityDrainScheduled = true
        deliveryStateLock.unlock()
        deliveryQueue.async { [weak self] in self?.drainCapacityBacklog() }
    }

    private func drainCapacityBacklog() {
        deliveryStateLock.lock()
        capacityDrainNeeded = false
        deliveryStateLock.unlock()
        defer {
            deliveryStateLock.lock()
            capacityDrainScheduled = false
            let shouldContinue = acceptingDelivery && capacityDrainNeeded
            deliveryStateLock.unlock()
            if shouldContinue { scheduleCapacityDrainIfNeeded() }
        }
        guard mayDeliver, gate.consent.isEnabled else { return }
        let envelopes: [Data]
        do {
            envelopes = try gate.queuedEnvelopes()
            let retained = Set(envelopes)
            deliveryStateLock.lock()
            retainedFailureStacks = retainedFailureStacks.filter { retained.contains($0.key) }
            deliveryStateLock.unlock()
        } catch {
            recordDeliveryFailure()
            return
        }
        for envelope in envelopes {
            guard mayDeliver, gate.consent.isEnabled else { return }
            do {
                try sendQueuedEnvelope(
                    envelope,
                    failureStack: retainedFailureStack(for: envelope),
                    acknowledge: !isReleaseSessionStart(envelope)
                )
            } catch {
                recordDeliveryFailure()
                return
            }
        }
    }

    private func sendQueuedEnvelope(
        _ envelope: Data,
        failureStack: [UInt64],
        acknowledge: Bool
    ) throws {
        guard let currentEnvelope = try gate.currentQueuedEnvelope(matching: envelope) else { return }
        if isDeliveredReleaseSessionStart(currentEnvelope) { return }
        if !acknowledge, deliveredRetainedEnvelopes.contains(currentEnvelope) { return }
        let effectiveFailureStack = failureStack.isEmpty
            ? persistedFailureStack(for: currentEnvelope)
            : failureStack
        try transport.send(envelope: currentEnvelope, failureStack: effectiveFailureStack)
        if acknowledge {
            try gate.acknowledgeQueuedEnvelope(currentEnvelope)
            forgetFailureStack(for: envelope)
            if isReleaseSessionEnd(currentEnvelope),
               let endedSessionID = stringField("app_session_id", in: currentEnvelope) {
                deliveredRetainedEnvelopes = Set(deliveredRetainedEnvelopes.filter {
                    stringField("app_session_id", in: $0) != endedSessionID
                })
            }
        } else {
            try gate.markReleaseSessionStartedDelivered(currentEnvelope)
            deliveredRetainedEnvelopes.insert(currentEnvelope)
            forgetFailureStack(for: envelope)
        }
    }

    private func retainFailureStack(_ failureStack: [UInt64], for envelope: Data) {
        guard !failureStack.isEmpty else { return }
        deliveryStateLock.lock()
        retainedFailureStacks[envelope] = failureStack
        deliveryStateLock.unlock()
    }

    private func retainedFailureStack(for envelope: Data) -> [UInt64] {
        deliveryStateLock.lock()
        defer { deliveryStateLock.unlock() }
        return retainedFailureStacks[envelope] ?? []
    }

    private func forgetFailureStack(for envelope: Data) {
        deliveryStateLock.lock()
        retainedFailureStacks[envelope] = nil
        deliveryStateLock.unlock()
    }

    private func isReleaseSessionStart(_ envelope: Data) -> Bool {
        stringField("event_name", in: envelope) == "release_session_started"
    }

    private func isReleaseSessionEnd(_ envelope: Data) -> Bool {
        stringField("event_name", in: envelope) == "release_session_ended"
    }

    private func isDeliveredReleaseSessionStart(_ envelope: Data) -> Bool {
        guard isReleaseSessionStart(envelope),
              let properties = (try? JSONSerialization.jsonObject(with: envelope) as? [String: Any])?["properties"] as? [String: Any]
        else { return false }
        return properties["session_start_delivered"] as? Bool == true
    }

    private func stringField(_ name: String, in envelope: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: envelope) as? [String: Any])?[name] as? String
    }

    /// Replays only envelopes the central gate can still decrypt and authorize.
    /// Shutdown-time session updates and transient failures remain eventual without
    /// waiting for vendor networking during app termination.
    private func drainPersistedQueue() {
        let envelopes: [Data]
        do {
            try gate.recoverAbandonedReleaseSessions()
            guard mayDeliver, gate.consent.isEnabled else { return }
            envelopes = try gate.queuedEnvelopesForDelivery()
        } catch {
            recordDeliveryFailure()
            return
        }
        for envelope in envelopes {
            guard mayDeliver, gate.consent.isEnabled else { return }
            do {
                try transport.send(envelope: envelope, failureStack: persistedFailureStack(for: envelope))
                try gate.acknowledgeQueuedEnvelope(envelope)
            } catch {
                recordDeliveryFailure()
                return
            }
        }
    }

    private func recordDeliveryFailure() {
        diagnosticsLock.lock()
        deliveryFailureCount += 1
        diagnosticsLock.unlock()
    }

    private func persistedFailureStack(for envelope: Data) -> [UInt64] {
        guard let object = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let values = object["failure_frame_offsets"] as? [NSNumber],
              let persistedImageID = object["failure_image_id"] as? String,
              persistedImageID.caseInsensitiveCompare(mainExecutableDebugID() ?? "") == .orderedSame
        else { return [] }
        return mainExecutableFrames(fromOffsets: values.map(\.uint64Value))
    }

}

/// Deterministic local evidence transport. It does not perform network I/O.
final class LocalSyntheticSentryTransport: SentryDiagnosticsTransport {
    private let outputURL: URL

    init(outputURL: URL) { self.outputURL = outputURL }

    func send(envelope: Data, failureStack: [UInt64]) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try envelope.write(to: outputURL, options: .atomic)
    }
}

struct SentryRuntimeConfiguration: Equatable {
    let dsn: URL

    static func from(environment: [String: String]) -> SentryRuntimeConfiguration? {
        guard environment["INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED"] == "1",
              let rawDSN = environment["INSIGHTKIT_SENTRY_DSN"],
              let dsn = URL(string: rawDSN),
              dsn.scheme == "https",
              let host = dsn.host,
              !host.isEmpty,
              let publicKey = dsn.user,
              !publicKey.isEmpty,
              !dsn.lastPathComponent.isEmpty,
              dsn.lastPathComponent.allSatisfy(\.isNumber)
        else { return nil }
        return SentryRuntimeConfiguration(dsn: dsn)
    }
}

/// Minimal Sentry envelope sender. The SDK's automatic collectors are intentionally
/// absent: no PII, screenshots, replay, view hierarchy, attachments, breadcrumbs,
/// request data, local variables, or raw logs can be collected by this transport.
final class SentryHTTPTransport: SentryDiagnosticsTransport {
    private static let deliveryTimeout: TimeInterval = 10

    private final class DeliveryResult: @unchecked Sendable {
        private let lock = NSLock()
        private var accepted = false
        func setAccepted(_ value: Bool) { lock.lock(); accepted = value; lock.unlock() }
        func isAccepted() -> Bool { lock.lock(); defer { lock.unlock() }; return accepted }
    }
    private let configuration: SentryRuntimeConfiguration
    private let session: URLSession
    private let sessionStateLock = NSLock()
    private var deliveredSessionStarts: [String: String] = [:]
    private let deliveryLock = NSLock()
    private var cancellationGeneration: UInt64 = 0
    private var isCancelled = false
    private var activeTasks: [URLSessionDataTask] = []

    init(configuration: SentryRuntimeConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func send(envelope approvedEnvelope: Data, failureStack: [UInt64]) throws {
        let request = try makeRequest(approvedEnvelope: approvedEnvelope, failureStack: failureStack)
        let finished = DispatchSemaphore(value: 0)
        let result = DeliveryResult()
        deliveryLock.lock()
        let generation = cancellationGeneration
        deliveryLock.unlock()
        var task: URLSessionDataTask!
        task = session.dataTask(with: request) { _, response, error in
            defer { finished.signal() }
            result.setAccepted(
                error == nil
                    && ((response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false)
            )
        }
        deliveryLock.lock()
        guard !isCancelled, generation == cancellationGeneration else {
            deliveryLock.unlock()
            throw TransportError.rejected
        }
        activeTasks.append(task)
        deliveryLock.unlock()
        defer {
            deliveryLock.lock()
            activeTasks.removeAll { $0 === task }
            deliveryLock.unlock()
        }
        task.resume()
        guard finished.wait(timeout: .now() + Self.deliveryTimeout) == .success else {
            task.cancel()
            throw TransportError.timedOut
        }
        guard result.isAccepted() else { throw TransportError.rejected }
        if let approved = try? JSONSerialization.jsonObject(with: approvedEnvelope) as? [String: Any],
           approved["event_name"] as? String == "release_session_started",
           let sessionID = approved["app_session_id"] as? String,
           let timestamp = approved["timestamp_utc"] as? String {
            sessionStateLock.lock()
            deliveredSessionStarts[sessionID] = timestamp
            sessionStateLock.unlock()
        }
    }

    func cancelAll() {
        deliveryLock.lock()
        cancellationGeneration &+= 1
        isCancelled = true
        let tasks = activeTasks
        activeTasks.removeAll()
        deliveryLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    func resume() {
        deliveryLock.lock()
        isCancelled = false
        deliveryLock.unlock()
    }

    func makeRequest(approvedEnvelope: Data, failureStack: [UInt64]) throws -> URLRequest {
        let approved = try JSONSerialization.jsonObject(with: approvedEnvelope) as? [String: Any]
        guard let approved,
              let version = approved["app_version"] as? String,
              let build = approved["app_build"] as? String,
              let environment = approved["environment"] as? String,
              let eventName = approved["event_name"] as? String,
              let timestamp = approved["timestamp_utc"] as? String,
              let installationID = approved["installation_id"] as? String,
              let sessionID = approved["app_session_id"] as? String,
              let eventSequence = approved["event_sequence"] as? Int,
              let properties = approved["properties"] as? [String: Any]
        else { throw TransportError.invalidApprovedEnvelope }
        let eventIdentity = "\(installationID):\(sessionID):\(eventSequence):\(eventName)"
        let eventID = SHA256.hash(data: Data(eventIdentity.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()

        let release = "com.yannjy.insightkit@\(version)+\(build)"
        let isSession = eventName.hasPrefix("release_session_")
        let payload: [String: Any]
        let itemType: String
        if isSession, let status = properties["session_status"] as? String {
            sessionStateLock.lock()
            let deliveredStart = deliveredSessionStarts[sessionID]
            let persistedStart = approved["session_started_utc"] as? String
            let started = persistedStart ?? deliveredStart ?? timestamp
            let persistedDelivered = properties["session_start_delivered"] as? Bool ?? false
            let initializesSession = eventName == "release_session_started" || (!persistedDelivered && deliveredStart == nil)
            let errorCount = properties["session_error_count"] as? Int ?? 0
            sessionStateLock.unlock()
            payload = [
                "sid": sessionID,
                "init": initializesSession,
                "started": started,
                "timestamp": timestamp,
                "status": status,
                "errors": max(errorCount, status == "crashed" ? 1 : 0),
                "attrs": ["release": release, "environment": environment],
            ]
            itemType = "session"
        } else if eventName == "recovery_completed" {
            payload = [
                "event_id": eventID,
                "timestamp": timestamp,
                "platform": "native",
                "level": properties["recovery_result"] as? String == "succeeded" ? "info" : "warning",
                "logger": "insightkit.diagnostics",
                "release": release,
                "dist": build,
                "environment": environment,
                "transaction": eventName,
                "tags": properties.mapValues { String(describing: $0) },
                "message": ["formatted": "InsightKit workflow recovery completed"],
            ]
            itemType = "event"
        } else if eventName == "workflow_completed" {
            let bucket = properties["duration_bucket_ms"] as? Int ?? 1_000
            let formatter = ISO8601DateFormatter()
            let end = formatter.date(from: timestamp) ?? Date()
            let start = end.addingTimeInterval(-Double(bucket) / 1_000)
            payload = [
                "event_id": eventID,
                "timestamp": timestamp,
                "start_timestamp": formatter.string(from: start),
                "platform": "native",
                "type": "transaction",
                "transaction": "workflow_completed",
                "release": release,
                "dist": build,
                "environment": environment,
                "tags": properties.mapValues { String(describing: $0) },
                "contexts": ["trace": [
                    "trace_id": eventID,
                    "span_id": String(eventID.prefix(16)),
                    "op": "insightkit.workflow",
                ]],
                "spans": [],
            ]
            itemType = "transaction"
        } else {
            let frames = mainExecutableFrames(failureStack).reversed().map { address in
                ["instruction_addr": String(format: "0x%llx", address), "in_app": true] as [String: Any]
            }
            var exception: [String: Any] = [
                "type": properties["error_category"] ?? "unknown",
                "value": "InsightKit workflow failure",
            ]
            if !frames.isEmpty { exception["stacktrace"] = ["frames": frames] }
            var failurePayload: [String: Any] = [
                "event_id": eventID,
                "timestamp": timestamp,
                "platform": "native",
                "level": "error",
                "logger": "insightkit.diagnostics",
                "release": release,
                "dist": build,
                "environment": environment,
                "transaction": eventName,
                "tags": properties.mapValues { String(describing: $0) },
                "contexts": ["app": ["app_identifier": "com.yannjy.insightkit", "app_version": version, "app_build": build]],
                "exception": ["values": [exception]],
            ]
            if !frames.isEmpty { failurePayload["debug_meta"] = ["images": Self.mainExecutableDebugImages()] }
            payload = failurePayload
            itemType = "event"
        }
        let eventData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = try JSONSerialization.data(withJSONObject: [
            "event_id": eventID,
            "dsn": configuration.dsn.absoluteString,
        ], options: [.sortedKeys])
        let itemHeader = try JSONSerialization.data(withJSONObject: ["type": itemType, "length": eventData.count])
        var body = Data()
        body.append(header); body.append(0x0a)
        body.append(itemHeader); body.append(0x0a)
        body.append(eventData)

        var request = URLRequest(url: try envelopeURL())
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Self.deliveryTimeout
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func envelopeURL() throws -> URL {
        let projectID = configuration.dsn.lastPathComponent
        var components = URLComponents(url: configuration.dsn, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        let prefix = configuration.dsn.deletingLastPathComponent().path
        components?.path = "\(prefix)/api/\(projectID)/envelope/".replacingOccurrences(of: "//", with: "/")
        guard let url = components?.url else { throw TransportError.invalidDSN }
        return url
    }

    private static func mainExecutableDebugImages() -> [[String: Any]] {
        guard let header = _dyld_get_image_header(0),
              header.pointee.magic == MH_MAGIC_64,
              let debugID = mainExecutableDebugID()
        else { return [] }
        let commandStart = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var offset = 0
        var minimumVMAddress = UInt64.max
        var maximumVMAddress: UInt64 = 0
        for _ in 0 ..< header.pointee.ncmds {
            let command = commandStart.advanced(by: offset).assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == LC_SEGMENT_64 {
                let segment = commandStart.advanced(by: offset).assumingMemoryBound(to: segment_command_64.self).pointee
                if segment.filesize > 0 {
                    minimumVMAddress = min(minimumVMAddress, segment.vmaddr)
                    maximumVMAddress = max(maximumVMAddress, segment.vmaddr + segment.vmsize)
                }
            }
            offset += Int(command.cmdsize)
        }
        guard minimumVMAddress != UInt64.max else { return [] }
        return [[
            "type": "macho",
            "debug_id": debugID,
            "code_id": debugID.replacingOccurrences(of: "-", with: ""),
            "code_file": Bundle.main.executableURL?.lastPathComponent ?? "InsightKit",
            "image_addr": String(format: "0x%llx", UInt64(UInt(bitPattern: header))),
            "image_size": maximumVMAddress - minimumVMAddress,
        ]]
    }

    enum TransportError: Error { case invalidApprovedEnvelope, invalidDSN, timedOut, rejected }
}

/// App-owned lifecycle integration. Environment configuration alone cannot override
/// the privacy gate's persisted opt-in, so both controls must authorize delivery.
final class SentryDiagnosticsRuntime {
    static let shared = SentryDiagnosticsRuntime()
    private let adapter: SentryDiagnosticsAdapter?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gateOverride: ExternalTelemetryPrivacyGate? = nil,
        transportOverride: SentryDiagnosticsTransport? = nil
    ) {
        let explicitSetting = environment["INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED"]
        guard explicitSetting == "0" || explicitSetting == "1" else {
            adapter = nil
            return
        }
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        #if DEBUG
        let defaultEnvironment = TelemetryEnvironment.development
        #else
        let defaultEnvironment = TelemetryEnvironment.release
        #endif
        let telemetryEnvironment = environment["INSIGHTKIT_ANALYTICS_ENVIRONMENT"]
            .flatMap(TelemetryEnvironment.init(rawValue:)) ?? defaultEnvironment
        let storageRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InsightKit/Telemetry/Sentry", isDirectory: true)
        let storage = storageRoot
            .appendingPathComponent(telemetryEnvironment.rawValue, isDirectory: true)
        let legacyQueueExists = gateOverride == nil && Self.hasLegacyQueue(in: storageRoot)
        guard let configuration = try? ExternalTelemetryConfiguration(
            environment: telemetryEnvironment,
            retentionDays: 7,
            maxQueueItems: 64
        ) else {
            adapter = nil
            return
        }
        let purgeGate = gateOverride ?? ExternalTelemetryPrivacyGate(
            configuration: configuration,
            appVersion: version,
            appBuild: build,
            storageDirectory: storageRoot
        )
        if explicitSetting == "0" || legacyQueueExists {
            _ = purgeGate.disableAndPurge()
            adapter = nil
            return
        }
        let gate = gateOverride ?? ExternalTelemetryPrivacyGate(
            configuration: configuration,
            appVersion: version,
            appBuild: build,
            storageDirectory: storage
        )
        guard let postHog = ProductAnalytics.configuredPostHogValues(
            process: environment,
            bundleInfo: bundle.infoDictionary ?? [:],
            environment: telemetryEnvironment
        ), PostHogProductAnalyticsTransport(host: postHog.host, projectKey: postHog.projectKey) != nil else {
            _ = gate.disableAndPurge()
            adapter = nil
            return
        }
        guard let sentry = SentryRuntimeConfiguration.from(environment: environment) else {
            adapter = nil
            return
        }
        adapter = SentryDiagnosticsAdapter(
            gate: gate,
            transport: transportOverride ?? SentryHTTPTransport(configuration: sentry)
        )
        adapter?.startReleaseSessionAfterDrainingQueue()
        if environment["INSIGHTKIT_SENTRY_SYNTHETIC_FAILURE"] == "1" {
            _ = adapter?.capture(.syntheticFailure)
        }
    }

    static func hasLegacyQueue(in storageRoot: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: storageRoot.appendingPathComponent("external-telemetry-queue-v1.json").path
        )
    }

    func applicationWillTerminate() { adapter?.endReleaseSession(.exited) }

    func captureFailure(
        workflow: SentryDiagnosticsAdapter.Workflow,
        phase: SentryDiagnosticsAdapter.Phase,
        engineClass: SentryDiagnosticsAdapter.EngineClass = .local,
        providerClass: SentryDiagnosticsAdapter.ProviderClass,
        errorCategory: SentryDiagnosticsAdapter.ErrorCategory,
        recoveryResult: SentryDiagnosticsAdapter.RecoveryResult
    ) {
        _ = adapter?.capture(.init(
            workflow: workflow,
            phase: phase,
            engineClass: engineClass,
            providerClass: providerClass,
            errorCategory: errorCategory,
            recoveryResult: recoveryResult
        ))
    }

    func capture(_ signal: ExternalTelemetryWorkflowSignal) {
        switch signal {
        case .failure(let context):
            _ = adapter?.capture(.init(
                workflow: context.workflow,
                phase: context.phase,
                engineClass: context.engineClass,
                providerClass: context.providerClass,
                errorCategory: context.errorCategory,
                recoveryResult: context.recoveryResult,
                failureStack: context.failureStack
            ))
        case .recovery(let context):
            _ = adapter?.captureRecovery(context)
        }
    }

    func capturePerformance(workflow: SentryDiagnosticsAdapter.Workflow, phase: SentryDiagnosticsAdapter.Phase, milliseconds: Int) {
        _ = adapter?.capturePerformance(workflow: workflow, phase: phase, durationMilliseconds: milliseconds)
    }
}
