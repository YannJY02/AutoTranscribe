import Foundation
import CryptoKit

extension Notification.Name {
    static let externalTelemetryConsentWillRevoke = Notification.Name(
        "com.yannjy.insightkit.external-telemetry-consent-will-revoke"
    )
    static let externalTelemetryConsentDidEnable = Notification.Name(
        "com.yannjy.insightkit.external-telemetry-consent-did-enable"
    )
}

private func postExternalTelemetryConsentChange(_ name: Notification.Name) {
    NotificationCenter.default.post(name: name, object: nil)
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: nil,
        deliverImmediately: true
    )
}

enum TelemetryEnvironment: String, CaseIterable, Codable {
    case development
    case ownerPilot = "owner-pilot"
    case release
}

enum ExternalTelemetryWorkflow: String { case live, `import`, recordReview = "record-review" }
enum ExternalTelemetryPhase: String { case preparing, running, analysis, finalizing, reviewing, exporting }
enum ExternalTelemetryEngineClass: String { case local, system, remote }
enum ExternalTelemetryProviderClass: String { case local, none, byok, managed }
enum ExternalTelemetryErrorCategory: String { case configuration, permission, runtime, storage, unknown }
enum ExternalTelemetryRecoveryResult: String { case succeeded, failed, notAttempted = "not-attempted" }

struct ExternalTelemetryWorkflowFailureContext {
    let workflow: ExternalTelemetryWorkflow
    let phase: ExternalTelemetryPhase
    let engineClass: ExternalTelemetryEngineClass
    let providerClass: ExternalTelemetryProviderClass
    let errorCategory: ExternalTelemetryErrorCategory
    let recoveryResult: ExternalTelemetryRecoveryResult
    let failureStack: [UInt64]
}

struct ExternalTelemetryWorkflowRecoveryContext {
    let workflow: ExternalTelemetryWorkflow
    let phase: ExternalTelemetryPhase
    let engineClass: ExternalTelemetryEngineClass
    let providerClass: ExternalTelemetryProviderClass
    let result: ExternalTelemetryRecoveryResult
}

enum ExternalTelemetryWorkflowSignal {
    case failure(ExternalTelemetryWorkflowFailureContext)
    case recovery(ExternalTelemetryWorkflowRecoveryContext)
}

struct ExternalTelemetryConfiguration: Equatable {
    let environment: TelemetryEnvironment
    let retentionDays: Int
    let maxQueueItems: Int

    init(environment: TelemetryEnvironment, retentionDays: Int, maxQueueItems: Int) throws {
        guard (1 ... 30).contains(retentionDays), (1 ... 1_000).contains(maxQueueItems) else {
            throw ConfigurationError.invalidBounds
        }
        self.environment = environment
        self.retentionDays = retentionDays
        self.maxQueueItems = maxQueueItems
    }

    enum ConfigurationError: Error {
        case invalidBounds
    }
}

/// The sole boundary through which future analytics, evaluation, and crash adapters may receive data.
/// This type deliberately contains no transport or vendor SDK.
final class ExternalTelemetryPrivacyGate {
    enum ConsentObservationPoint: Equatable {
        case recordInitial
        case recordAdmission
        case persistenceWorker
        case readbackInitial
        case readbackFinal
    }

    private struct ConsentObservation {
        let consent: Consent
        let isInvalid: Bool
        let generation: UInt64
        let durableEpoch: String
    }
    struct Event {
        let name: String
        let properties: [String: Any]
        let failureFrameOffsets: [UInt64]
        let failureImageID: String?

        init(
            name: String,
            properties: [String: Any],
            failureFrameOffsets: [UInt64] = [],
            failureImageID: String? = nil
        ) {
            self.name = name
            self.properties = properties
            self.failureFrameOffsets = failureFrameOffsets
            self.failureImageID = failureImageID
        }
    }

    struct Consent: Codable, Equatable {
        var isEnabled: Bool
        var version: Int
        var grantedAt: Date?
    }

    struct DisableEvidence: Codable, Equatable {
        let externalTelemetryEnabled: Bool
        let purgedItems: Int
        let remainingItems: Int
        let queueFileDeleted: Bool
        let queueKeyErased: Bool
        let failureCodes: [String]
        let evidenceFilePersisted: Bool

        var failureCode: String? { failureCodes.first }

        enum CodingKeys: String, CodingKey {
            case externalTelemetryEnabled
            case purgedItems
            case remainingItems
            case queueFileDeleted
            case queueKeyErased
            case failureCodes
            case evidenceFilePersisted
        }
    }

    struct LocalDiagnostics: Equatable {
        fileprivate(set) var rejected = 0
        fileprivate(set) var queueFull = 0
        fileprivate(set) var expired = 0
        fileprivate(set) var serializationFailed = 0
        fileprivate(set) var queueDeleteFailed = 0
    }

    enum RecordResult: Equatable {
        case disabled
        case rejected
        /// Accepted into the bounded in-memory persistence pipeline. Durability is
        /// established only when the item appears in `queuedEnvelopes()`.
        case accepted
        case queueFull
        case serializationFailed
    }

    struct RecordOutcome {
        let result: RecordResult
        let debugEnvelope: Data?
    }

    private struct Envelope: Codable, Equatable {
        let schemaVersion: Int
        let eventName: String
        let timestampUTC: Date
        let sessionStartedUTC: Date?
        let appVersion: String
        let appBuild: String
        let environment: String
        let consentVersion: Int
        let installationID: String
        let appSessionID: String
        let eventSequence: Int
        let failureFrameOffsets: [UInt64]?
        let failureImageID: String?
        let properties: [String: PropertyValue]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case eventName = "event_name"
            case timestampUTC = "timestamp_utc"
            case sessionStartedUTC = "session_started_utc"
            case appVersion = "app_version"
            case appBuild = "app_build"
            case environment
            case consentVersion = "consent_version"
            case installationID = "installation_id"
            case appSessionID = "app_session_id"
            case eventSequence = "event_sequence"
            case failureFrameOffsets = "failure_frame_offsets"
            case failureImageID = "failure_image_id"
            case properties
        }

        init(
            schemaVersion: Int,
            eventName: String,
            timestampUTC: Date,
            sessionStartedUTC: Date? = nil,
            appVersion: String,
            appBuild: String,
            environment: String,
            consentVersion: Int,
            installationID: String,
            appSessionID: String,
            eventSequence: Int,
            failureFrameOffsets: [UInt64]? = nil,
            failureImageID: String? = nil,
            properties: [String: PropertyValue]
        ) {
            self.schemaVersion = schemaVersion
            self.eventName = eventName
            self.timestampUTC = timestampUTC
            self.sessionStartedUTC = sessionStartedUTC
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.environment = environment
            self.consentVersion = consentVersion
            self.installationID = installationID
            self.appSessionID = appSessionID
            self.eventSequence = eventSequence
            self.failureFrameOffsets = failureFrameOffsets
            self.failureImageID = failureImageID
            self.properties = properties
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            eventName = try container.decode(String.self, forKey: .eventName)
            timestampUTC = try container.decode(Date.self, forKey: .timestampUTC)
            sessionStartedUTC = try container.decodeIfPresent(Date.self, forKey: .sessionStartedUTC)
            appVersion = try container.decode(String.self, forKey: .appVersion)
            appBuild = try container.decode(String.self, forKey: .appBuild)
            environment = try container.decode(String.self, forKey: .environment)
            consentVersion = try container.decode(Int.self, forKey: .consentVersion)
            installationID = try container.decode(String.self, forKey: .installationID)
            appSessionID = try container.decode(String.self, forKey: .appSessionID)
            eventSequence = try container.decodeIfPresent(Int.self, forKey: .eventSequence) ?? 0
            failureFrameOffsets = try container.decodeIfPresent([UInt64].self, forKey: .failureFrameOffsets)
            failureImageID = try container.decodeIfPresent(String.self, forKey: .failureImageID)
            properties = try container.decode([String: PropertyValue].self, forKey: .properties)
        }

        func replacingProperties(_ updates: [String: PropertyValue]) -> Envelope {
            Envelope(
                schemaVersion: schemaVersion,
                eventName: eventName,
                timestampUTC: timestampUTC,
                sessionStartedUTC: sessionStartedUTC,
                appVersion: appVersion,
                appBuild: appBuild,
                environment: environment,
                consentVersion: consentVersion,
                installationID: installationID,
                appSessionID: appSessionID,
                eventSequence: eventSequence,
                failureFrameOffsets: failureFrameOffsets,
                failureImageID: failureImageID,
                properties: properties.merging(updates) { _, replacement in replacement }
            )
        }

        func hasSameIdentity(as other: Envelope) -> Bool {
            eventName == other.eventName
                && environment == other.environment
                && installationID == other.installationID
                && appSessionID == other.appSessionID
                && eventSequence == other.eventSequence
        }
    }

    private enum PropertyValue: Codable, Equatable {
        case string(String)
        case integer(Int)
        case number(Double)
        case boolean(Bool)

        init?(value: Any) {
            switch value {
            case let value as String: self = .string(value)
            case let value as Bool: self = .boolean(value)
            case let value as Int: self = .integer(value)
            case let value as Double: self = .number(value)
            default: return nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .boolean(value) }
            else if let value = try? container.decode(Int.self) { self = .integer(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else { self = .string(try container.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            }
        }
    }

    private enum PropertyRule {
        case enumStrings(Set<String>)
        case enumIntegers(Set<Int>)
        case boundedInteger(ClosedRange<Int>)
        case boundedNumber(ClosedRange<Double>)
        case boolean

        func accepts(_ value: PropertyValue) -> Bool {
            switch (self, value) {
            case (.enumStrings(let allowed), .string(let candidate)):
                return allowed.contains(candidate) && !Self.looksSensitive(candidate)
            case (.enumIntegers(let allowed), .integer(let candidate)): return allowed.contains(candidate)
            case (.boundedInteger(let allowed), .integer(let candidate)): return allowed.contains(candidate)
            // JSONEncoder is the serialization boundary for numeric values. Let it reject
            // non-finite numbers so that path is fail-closed and independently observable.
            case (.boundedNumber(let allowed), .number(let candidate)):
                return !candidate.isFinite || allowed.contains(candidate)
            case (.boundedNumber(let allowed), .integer(let candidate)):
                return allowed.contains(Double(candidate))
            case (.boolean, .boolean): return true
            default: return false
            }
        }

        private static func looksSensitive(_ value: String) -> Bool {
            let lower = value.lowercased()
            if lower.contains("@") || lower.contains("/users/") || lower.contains("\\users\\") {
                return true
            }
            let secretPrefixes = ["sk-", "hf_", "AIza", "Bearer "]
            return secretPrefixes.contains { value.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    /// Contract version 1. Both event names and every property/value are closed sets.
    private static let schemaV1: [String: [String: PropertyRule]] = [
        "workflow_started": commonWorkflowRules,
        "record_saved": commonWorkflowRules,
        "record_reopened": commonWorkflowRules,
        "transcript_search_completed": commonWorkflowRules,
        "smart_minutes_review_opened": commonWorkflowRules,
        "export_completed": commonWorkflowRules,
        "workflow_completed": commonWorkflowRules,
        "workflow_failed": commonWorkflowRules,
        "recovery_attempted": commonWorkflowRules,
        "recovery_completed": commonWorkflowRules,
        "telemetry_consent_changed": ["telemetry_enabled": .boolean],
        "review_opened": commonWorkflowRules,
        "release_session_started": releaseSessionRules(statuses: ["ok"]),
        "release_session_ended": releaseSessionRules(statuses: ["exited", "crashed", "abnormal"]),
        "app_crashed": [
            "error_category": .enumStrings(["runtime", "storage", "unknown"]),
            "phase": .enumStrings(["launch", "preparing", "running", "finalizing", "reviewing"]),
        ],
    ]

    private static let commonWorkflowRules: [String: PropertyRule] = [
        "workflow": .enumStrings(["live", "import", "record-review"]),
        "analysis_mode": .enumStrings(["local", "cloud", "byok-cloud", "disabled"]),
        "engine_class": .enumStrings(["local", "system", "remote"]),
        "provider_class": .enumStrings(["local", "byok", "none", "managed"]),
        "phase": .enumStrings(["launch", "preparing", "running", "finalizing", "analysis", "reviewing", "exporting"]),
        "outcome": .enumStrings(["succeeded", "failed", "cancelled"]),
        "error_code": .enumStrings(["configuration", "permission-denied", "runtime-unavailable", "provider-unavailable", "storage", "unknown"]),
        "error_category": .enumStrings(["configuration", "permission", "runtime", "storage", "unknown"]),
        "recovery_action": .enumStrings(["retry", "open-settings", "restart", "none"]),
        "recovery_result": .enumStrings(["succeeded", "failed", "not-attempted"]),
        "duration_bucket_ms": .enumIntegers([1_000, 5_000, 15_000, 30_000, 60_000, 300_000, 900_000, 1_800_000, 3_600_000]),
        "latency_bucket_ms": .enumIntegers([100, 250, 500, 1_000, 5_000, 15_000, 30_000, 60_000, 300_000]),
        "retry_count": .boundedInteger(0 ... 10),
        "result_count": .boundedInteger(0 ... 10_000),
        "module_count": .boundedInteger(0 ... 100),
        "quality_score": .boundedNumber(0 ... 1),
        "recovered": .boolean,
    ]

    private static func releaseSessionRules(statuses: Set<String>) -> [String: PropertyRule] {
        [
            "session_status": .enumStrings(statuses),
            "session_error_count": .boundedInteger(0 ... 1_000),
            "session_start_delivered": .boolean,
        ]
    }

    private let configuration: ExternalTelemetryConfiguration
    private let appVersion: String
    private let appBuild: String
    private let defaults: UserDefaults
    private let storageDirectory: URL
    private let now: () -> Date
    private let uuid: () -> UUID
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    // One short process-wide transaction linearizes consent, generation, admission, and
    // readback across gate instances. Keychain, filesystem, crypto, and JSON work never
    // runs while this lock is held.
    private static let stateLock = NSLock()
    private static let installationIDLock = NSLock()
    private static let consentTransitionLock = NSLock()
    private static var consentGeneration: UInt64 = 0
    private static var completedRevocationEpoch: String?
    private static var pendingPersistenceItemsByQueue: [String: Int] = [:]
    private static var revocationTasks: [String: RevocationTask] = [:]
    static var revocationTaskCountForTesting: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return revocationTasks.count
    }
    private static let persistenceQueue = DispatchQueue(label: "com.yannjy.insightkit.external-telemetry.persistence")
    private let removeItem: (URL) throws -> Void
    private let readQueueKey: () throws -> Data?
    private let saveQueueKey: (Data) throws -> Void
    private let deleteQueueKey: () throws -> Void
    private let writeData: (Data, URL) throws -> Void
    private let onRecordGuardPassed: () -> Void
    private let onEnableCleanupCompleted: () -> Void
    private let onInvalidConsentGenerationAdvanced: () -> Void
    private let onInvalidConsentGuardPassed: () -> Void
    private let onRevocationCleanupChecked: () -> Void
    private let onRevocationAdmitted: () -> Void
    private let onConsentObserved: (ConsentObservationPoint) -> Void
    private let onRevocationWillComplete: () -> Void
    private let onRevocationJoined: () -> Void
    private let onRevocationEpochRetired: () -> Void
    private let onEnableConsentPersisted: () -> Void
    private let queueURL: URL
    private let persistenceQueueKey: String
    private let consentKey = "insightkit.external-telemetry.consent.v1"
    private let installationIDKey = "insightkit.external-telemetry.installation-id.v1"
    private let consentEpochKey = "insightkit.external-telemetry.consent-epoch.v1"
    private let revocationKey = "insightkit.external-telemetry.revoked.v1"
    private let disableEvidenceFallbackKey = "insightkit.external-telemetry.disable-evidence-fallback.v1"
    private var appSessionID: String
    private let sequenceLock = NSLock()
    private var nextEventSequence = 0
    private var pendingReleaseSessionErrorCounts: [String: Int] = [:]

    private let diagnosticsLock = NSLock()
    private var diagnostics = LocalDiagnostics()
    var localDiagnostics: LocalDiagnostics {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return diagnostics
    }
    let disableEvidenceURL: URL

    var consent: Consent {
        return observeConsent().consent
    }

    private func readConsent() -> Consent {
        observeConsent().consent
    }

    private func observeConsent(_ point: ConsentObservationPoint? = nil) -> ConsentObservation {
        Self.consentTransitionLock.lock()
        let hasRevocation = defaults.object(forKey: revocationKey) != nil
        let data = defaults.data(forKey: consentKey)
        let storeID = defaults.string(forKey: installationIDKey) ?? "uninitialized-installation"
        let consentEpoch = defaults.string(forKey: consentEpochKey) ?? "legacy-consent"
        Self.stateLock.lock()
        let generation = Self.consentGeneration
        Self.stateLock.unlock()
        Self.consentTransitionLock.unlock()
        let value = data.flatMap { try? decoder.decode(Consent.self, from: $0) }
        let isAcceptedEnabled = value?.isEnabled == true
            && value?.version == Self.acceptedConsentVersion
            && value?.grantedAt != nil
            && value!.grantedAt! <= now()
        let isDefaultDisabled = data == nil
            || (value?.isEnabled == false && value?.version == 0 && value?.grantedAt == nil)
        let isAcceptedOptOut = value?.isEnabled == false
            && value?.version == Self.acceptedConsentVersion
            && value?.grantedAt == nil
        let observation = ConsentObservation(
            consent: !hasRevocation && isAcceptedEnabled
                ? value!
                : Consent(isEnabled: false, version: 0, grantedAt: nil),
            isInvalid: hasRevocation || (!isAcceptedEnabled && !isDefaultDisabled && !isAcceptedOptOut),
            generation: generation,
            durableEpoch: "\(storeID):\(consentEpoch)"
        )
        if let point { onConsentObserved(point) }
        return observation
    }

    init(
        configuration: ExternalTelemetryConfiguration,
        appVersion: String,
        appBuild: String,
        defaults: UserDefaults = .standard,
        storageDirectory: URL,
        now: @escaping () -> Date = Date.init,
        uuid: @escaping () -> UUID = UUID.init,
        removeItem: @escaping (URL) throws -> Void = FileManager.default.removeItem(at:),
        readQueueKey: @escaping () throws -> Data? = ExternalTelemetryPrivacyGate.defaultReadQueueKey,
        saveQueueKey: @escaping (Data) throws -> Void = ExternalTelemetryPrivacyGate.defaultSaveQueueKey,
        deleteQueueKey: @escaping () throws -> Void = ExternalTelemetryPrivacyGate.defaultDeleteQueueKey,
        writeData: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) },
        onRecordGuardPassed: @escaping () -> Void = {},
        onEnableCleanupCompleted: @escaping () -> Void = {},
        onInstallationIDMissing: @escaping () -> Void = {},
        onInstallationIDObserved: @escaping () -> Void = {},
        onInvalidConsentGenerationAdvanced: @escaping () -> Void = {},
        onInvalidConsentGuardPassed: @escaping () -> Void = {},
        onRevocationCleanupChecked: @escaping () -> Void = {},
        onRevocationAdmitted: @escaping () -> Void = {},
        onConsentObserved: @escaping (ConsentObservationPoint) -> Void = { _ in },
        onRevocationWillComplete: @escaping () -> Void = {},
        onRevocationJoined: @escaping () -> Void = {},
        onRevocationEpochRetired: @escaping () -> Void = {},
        onEnableConsentPersisted: @escaping () -> Void = {}
    ) {
        self.configuration = configuration
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.defaults = defaults
        self.storageDirectory = storageDirectory
        self.now = now
        self.uuid = uuid
        self.removeItem = removeItem
        self.readQueueKey = readQueueKey
        self.saveQueueKey = saveQueueKey
        self.deleteQueueKey = deleteQueueKey
        self.writeData = writeData
        self.onRecordGuardPassed = onRecordGuardPassed
        self.onEnableCleanupCompleted = onEnableCleanupCompleted
        self.onInvalidConsentGenerationAdvanced = onInvalidConsentGenerationAdvanced
        self.onInvalidConsentGuardPassed = onInvalidConsentGuardPassed
        self.onRevocationCleanupChecked = onRevocationCleanupChecked
        self.onRevocationAdmitted = onRevocationAdmitted
        self.onConsentObserved = onConsentObserved
        self.onRevocationWillComplete = onRevocationWillComplete
        self.onRevocationJoined = onRevocationJoined
        self.onRevocationEpochRetired = onRevocationEpochRetired
        self.onEnableConsentPersisted = onEnableConsentPersisted
        queueURL = storageDirectory.appendingPathComponent("external-telemetry-queue-v1.json")
        persistenceQueueKey = queueURL.standardizedFileURL.path
        disableEvidenceURL = storageDirectory.appendingPathComponent("external-telemetry-disable-evidence-v1.json")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let persistedInstallationID = defaults.string(forKey: installationIDKey).flatMap(UUID.init(uuidString:))
        onInstallationIDObserved()
        if persistedInstallationID == nil {
            onInstallationIDMissing()
        }
        // UUID generation is deliberately outside every process-wide lock. A losing
        // initializer discards its candidate after the dedicated installation CAS.
        var installationCandidate = persistedInstallationID == nil ? uuid().uuidString.lowercased() : nil
        while true {
            Self.installationIDLock.lock()
            if let existing = defaults.string(forKey: installationIDKey),
               let parsed = UUID(uuidString: existing) {
                installationIDFallback = parsed.uuidString.lowercased()
                Self.installationIDLock.unlock()
                break
            }
            if let installationCandidate {
                defaults.set(installationCandidate, forKey: installationIDKey)
                installationIDFallback = installationCandidate
                Self.installationIDLock.unlock()
                break
            }
            Self.installationIDLock.unlock()
            installationCandidate = uuid().uuidString.lowercased()
        }
        appSessionID = uuid().uuidString.lowercased()
    }

    private let installationIDFallback: String

    private var installationID: String {
        Self.installationIDLock.lock()
        defer { Self.installationIDLock.unlock() }
        return defaults.string(forKey: installationIDKey)
            .flatMap(UUID.init(uuidString:))?
            .uuidString.lowercased() ?? installationIDFallback
    }

    private static let queueKeyAccount = "external-telemetry-queue-key-v1"
    static let acceptedConsentVersion = 2

    private static func defaultReadQueueKey() throws -> Data? {
        guard let encoded = try KeychainService().readSecret(
            account: queueKeyAccount,
            interactionPolicy: .failIfInteractionRequired
        ) else { return nil }
        return Data(base64Encoded: encoded)
    }

    private static func defaultSaveQueueKey(_ data: Data) throws {
        try KeychainService().save(secret: data.base64EncodedString(), account: queueKeyAccount)
    }

    private static func defaultDeleteQueueKey() throws {
        try KeychainService().deleteSecret(account: queueKeyAccount)
    }

    func setConsent(enabled: Bool, consentVersion: Int) throws {
        if !enabled {
            _ = disableAndPurge()
            return
        }
        guard consentVersion == Self.acceptedConsentVersion else { throw ConsentError.invalidVersion }
        let wasEnabled = readConsent().isEnabled
        let hadPriorConsentState = defaults.data(forKey: consentKey) != nil
        let value = Consent(isEnabled: true, version: consentVersion, grantedAt: now())
        let encodedValue = try encoder.encode(value)
        let consentEpoch = UUID().uuidString.lowercased()
        let rotatedAppSessionID = hadPriorConsentState ? UUID().uuidString.lowercased() : nil
        Self.stateLock.lock()
        if wasEnabled {
            Self.stateLock.unlock()
            return
        }
        Self.consentGeneration &+= 1
        let enablingGeneration = Self.consentGeneration
        Self.stateLock.unlock()

        try Self.persistenceQueue.sync { try removeQueuedItems() }
        onEnableCleanupCompleted()

        Self.consentTransitionLock.lock()
        Self.stateLock.lock()
        guard enablingGeneration == Self.consentGeneration else {
            Self.stateLock.unlock()
            Self.consentTransitionLock.unlock()
            throw ConsentError.transitionSuperseded
        }
        Self.stateLock.unlock()
        if let rotatedAppSessionID {
            defaults.set(consentEpoch, forKey: installationIDKey)
            sequenceLock.lock()
            appSessionID = rotatedAppSessionID
            nextEventSequence = 0
            sequenceLock.unlock()
        }
        defaults.set(consentEpoch, forKey: consentEpochKey)
        // Keep consent disabled until the new identity epoch is fully established.
        defaults.set(encodedValue, forKey: consentKey)
        onEnableConsentPersisted()
        defaults.removeObject(forKey: revocationKey)
        Self.stateLock.lock()
        Self.revocationTasks.removeAll()
        Self.stateLock.unlock()
        Self.consentTransitionLock.unlock()
        postExternalTelemetryConsentChange(.externalTelemetryConsentDidEnable)
    }

    @discardableResult
    func disableAndPurge() -> DisableEvidence {
        let disabled = Consent(isEnabled: false, version: readConsent().version, grantedAt: nil)
        let encodedDisabled = try? encoder.encode(disabled)
        // Entropy and allocation can block; prepare the candidate before entering either
        // process-wide transition lock, then commit only generation and registry state.
        let revocationToken = uuid().uuidString.lowercased()
        let task = RevocationTask { [self] generation, token in
            purgeInvalidConsentIfCurrent(generation: generation, token: token)
        }
        Self.consentTransitionLock.lock()
        Self.stateLock.lock()
        Self.consentGeneration &+= 1
        let disablingGeneration = Self.consentGeneration
        task.bind(generation: disablingGeneration, token: revocationToken)
        Self.revocationTasks = [revocationToken: task]
        Self.stateLock.unlock()
        defaults.set(revocationToken, forKey: revocationKey)
        defaults.set(encodedDisabled, forKey: consentKey)
        Self.consentTransitionLock.unlock()
        postExternalTelemetryConsentChange(.externalTelemetryConsentWillRevoke)
        onRevocationAdmitted()
        let admission = RevocationAdmission(
            generation: disablingGeneration,
            token: revocationToken,
            task: task,
            didAdvanceGeneration: true
        )
        submitRevocationIfNeeded(admission)
        task.group.wait()
        return task.completedEvidence ?? supersededDisableEvidence()
    }

    private func supersededDisableEvidence() -> DisableEvidence {
        let queueExists = FileManager.default.fileExists(atPath: queueURL.path)
        return DisableEvidence(
            externalTelemetryEnabled: false,
            purgedItems: 0,
            remainingItems: queueExists ? 1 : 0,
            queueFileDeleted: !queueExists,
            queueKeyErased: false,
            failureCodes: ["revocation-superseded"],
            evidenceFilePersisted: false
        )
    }

    private func disableAndPurgePersistedState() -> DisableEvidence {
        let purged = (try? queuedItemCountAcrossFiles()) ?? 0
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        var failures: [String] = []
        do { try persistEncrypted([]) }
        catch { failures.append("queue-tombstone-write-failed") }
        var keyErased = false
        do {
            try deleteQueueKey()
            keyErased = true
        } catch {
            failures.append("queue-key-delete-failed")
            let replacement = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            do {
                try saveQueueKey(replacement)
                keyErased = true
            } catch {
                failures.append("queue-key-replacement-failed")
            }
        }
        let queueFileDeleted: Bool
        do {
            try removeAllQueuedItems()
            queueFileDeleted = true
        } catch {
            queueFileDeleted = false
            failures.append("queue-delete-failed")
        }
        // If every erasure mechanism failed, file presence proves that something remains
        // even when the encrypted queue could not be counted. Never manufacture a zero.
        let remaining = queueFileDeleted || keyErased
            ? 0
            : max(purged, FileManager.default.fileExists(atPath: queueURL.path) ? 1 : 0)
        let actuallyPurged = max(0, purged - remaining)
        let baseEvidence = DisableEvidence(
            externalTelemetryEnabled: false,
            purgedItems: actuallyPurged,
            remainingItems: remaining,
            queueFileDeleted: queueFileDeleted,
            queueKeyErased: keyErased,
            failureCodes: failures,
            evidenceFilePersisted: true
        )
        do {
            try writeData(encoder.encode(baseEvidence), disableEvidenceURL)
            defaults.removeObject(forKey: disableEvidenceFallbackKey)
            return baseEvidence
        } catch {
            let fallback = DisableEvidence(
                externalTelemetryEnabled: false,
                purgedItems: actuallyPurged,
                remainingItems: remaining,
                queueFileDeleted: queueFileDeleted,
                queueKeyErased: keyErased,
                failureCodes: failures,
                evidenceFilePersisted: false
            )
            defaults.set(try? encoder.encode(fallback), forKey: disableEvidenceFallbackKey)
            return fallback
        }
    }

    private func removeQueuedItems() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: queueURL.path) {
            try removeItem(queueURL)
        }
        guard !manager.fileExists(atPath: queueURL.path) else {
            throw PurgeError.queueStillPresent
        }
    }

    private func removeAllQueuedItems() throws {
        let manager = FileManager.default
        let queueURLs = allQueueURLs()
        for url in queueURLs where manager.fileExists(atPath: url.path) {
            try removeItem(url)
        }
        guard queueURLs.allSatisfy({ !manager.fileExists(atPath: $0.path) }) else {
            throw PurgeError.queueStillPresent
        }
    }

    private func allQueueURLs() -> [URL] {
        let manager = FileManager.default
        var urlsByPath = [queueURL.standardizedFileURL.path: queueURL]
        if let enumerator = manager.enumerator(
            at: storageDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where
                url.lastPathComponent == queueURL.lastPathComponent {
                urlsByPath[url.standardizedFileURL.path] = url
            }
        }
        return Array(urlsByPath.values)
    }

    private func queuedItemCountAcrossFiles() throws -> Int {
        guard let keyData = try readQueueKey() else { return 0 }
        let key = SymmetricKey(data: keyData)
        return try allQueueURLs().reduce(into: 0) { count, url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
            let clear = try AES.GCM.open(sealed, using: key)
            count += try decoder.decode([Envelope].self, from: clear).count
        }
    }

    func record(
        event: Event,
        replacingOldestWhenFull: Bool = false,
        onPersisted: ((Data) -> Void)? = nil
    ) -> RecordOutcome {
        let initialObservation = observeConsent(.recordInitial)
        let observedConsent = initialObservation.consent
        let invalidConsent = initialObservation.isInvalid
        onRecordGuardPassed()
        Self.stateLock.lock()
        guard initialObservation.generation == Self.consentGeneration else {
            Self.stateLock.unlock()
            return RecordOutcome(result: .disabled, debugEnvelope: nil)
        }
        let initialGeneration = initialObservation.generation
        let activeConsent = observedConsent
        guard activeConsent.isEnabled else {
            Self.stateLock.unlock()
            if invalidConsent,
               let invalidation = admitInvalidConsentInvalidation(
                expectedGeneration: initialGeneration,
                durableEpoch: initialObservation.durableEpoch
               ) {
                if invalidation.didAdvanceGeneration { onInvalidConsentGenerationAdvanced() }
                submitRevocationIfNeeded(invalidation)
            }
            return RecordOutcome(result: .disabled, debugEnvelope: nil)
        }
        Self.stateLock.unlock()
        guard Self.isValidAppVersion(appVersion), Self.isValidAppBuild(appBuild) else {
            mutateDiagnostics { $0.rejected += 1 }
            return RecordOutcome(result: .rejected, debugEnvelope: nil)
        }
        guard let rules = Self.schemaV1[event.name],
              Set(event.properties.keys).isSubset(of: Set(rules.keys))
        else {
            mutateDiagnostics { $0.rejected += 1 }
            return RecordOutcome(result: .rejected, debugEnvelope: nil)
        }
        guard event.failureFrameOffsets.count <= 64,
              event.failureFrameOffsets.allSatisfy({ $0 <= UInt64(UInt32.max) }),
              event.failureFrameOffsets.isEmpty == (event.failureImageID == nil),
              event.failureImageID.map({ UUID(uuidString: $0) != nil }) ?? true
        else {
            mutateDiagnostics { $0.rejected += 1 }
            return RecordOutcome(result: .rejected, debugEnvelope: nil)
        }

        var properties: [String: PropertyValue] = [:]
        for (key, rawValue) in event.properties {
            guard let value = PropertyValue(value: rawValue), rules[key]?.accepts(value) == true else {
                mutateDiagnostics { $0.rejected += 1 }
                return RecordOutcome(result: .rejected, debugEnvelope: nil)
            }
            properties[key] = value
        }

        let eventContext = allocateEventContext()
        let envelope = Envelope(
            schemaVersion: 1,
            eventName: event.name,
            timestampUTC: now(),
            sessionStartedUTC: nil,
            appVersion: appVersion,
            appBuild: appBuild,
            environment: configuration.environment.rawValue,
            consentVersion: activeConsent.version,
            installationID: installationID,
            appSessionID: eventContext.appSessionID,
            eventSequence: eventContext.eventSequence,
            failureFrameOffsets: event.failureFrameOffsets.isEmpty ? nil : event.failureFrameOffsets,
            failureImageID: event.failureImageID,
            properties: properties
        )

        let debugEnvelope: Data
        do {
            debugEnvelope = try encoder.encode(envelope)
        } catch {
            mutateDiagnostics { $0.serializationFailed += 1 }
            return RecordOutcome(result: .serializationFailed, debugEnvelope: nil)
        }

        let admissionObservation = observeConsent(.recordAdmission)
        let consentBeforeAdmission = admissionObservation.consent
        let invalidConsentBeforeAdmission = admissionObservation.isInvalid
        Self.stateLock.lock()
        guard Self.consentGeneration == initialGeneration,
              consentBeforeAdmission == activeConsent
        else {
            Self.stateLock.unlock()
            if invalidConsentBeforeAdmission {
                scheduleInvalidConsentInvalidation(
                    expectedGeneration: admissionObservation.generation,
                    durableEpoch: admissionObservation.durableEpoch
                )
            }
            return RecordOutcome(result: .disabled, debugEnvelope: nil)
        }
        let pendingPersistenceItems = Self.pendingPersistenceItemsByQueue[persistenceQueueKey, default: 0]
        guard pendingPersistenceItems < configuration.maxQueueItems else {
            Self.stateLock.unlock()
            mutateDiagnostics { $0.queueFull += 1 }
            return RecordOutcome(result: .queueFull, debugEnvelope: nil)
        }
        let generation = Self.consentGeneration
        Self.pendingPersistenceItemsByQueue[persistenceQueueKey] = pendingPersistenceItems + 1
        Self.stateLock.unlock()
        Self.persistenceQueue.async { [self] in
            defer {
                Self.stateLock.lock()
                let remaining = Self.pendingPersistenceItemsByQueue[persistenceQueueKey, default: 1] - 1
                if remaining == 0 {
                    Self.pendingPersistenceItemsByQueue.removeValue(forKey: persistenceQueueKey)
                } else {
                    Self.pendingPersistenceItemsByQueue[persistenceQueueKey] = remaining
                }
                Self.stateLock.unlock()
            }
            let persistenceObservation = observeConsent(.persistenceWorker)
            let persistedConsent = persistenceObservation.consent
            let invalidPersistedConsent = persistenceObservation.isInvalid
            Self.stateLock.lock()
            let stillCurrent = generation == Self.consentGeneration
                && persistedConsent == activeConsent
            Self.stateLock.unlock()
            guard stillCurrent else {
                if invalidPersistedConsent {
                    invalidateQueueForInvalidConsentOnPersistenceQueue(
                        expectedGeneration: persistenceObservation.generation,
                        durableEpoch: persistenceObservation.durableEpoch
                    )
                }
                return
            }
            do {
                var queue = try loadAndExpireQueue()
                if queue.count >= configuration.maxQueueItems {
                    guard replacingOldestWhenFull else {
                        mutateDiagnostics { $0.queueFull += 1 }
                        return
                    }
                    guard let evictable = queue.firstIndex(where: { $0.eventName != "release_session_ended" }) else {
                        mutateDiagnostics { $0.queueFull += 1 }
                        return
                    }
                    queue.remove(at: evictable)
                    mutateDiagnostics { $0.queueFull += 1 }
                }
                var persistedEnvelope = envelope
                if envelope.eventName == "release_session_started",
                   let pendingErrors = pendingReleaseSessionErrorCounts[envelope.appSessionID] {
                    persistedEnvelope = envelope.replacingProperties([
                        "session_error_count": .integer(min(pendingErrors, 1_000)),
                    ])
                }
                queue.append(persistedEnvelope)
                try persist(queue)
                if envelope.eventName == "release_session_started" {
                    pendingReleaseSessionErrorCounts.removeValue(forKey: envelope.appSessionID)
                }
                onPersisted?(try encoder.encode(persistedEnvelope))
            } catch {
                mutateDiagnostics { $0.serializationFailed += 1 }
            }
        }
        return RecordOutcome(result: .accepted, debugEnvelope: debugEnvelope)
    }

    func queuedEnvelopes() throws -> [Data] {
        let initialObservation = observeConsent(.readbackInitial)
        let initialConsent = initialObservation.consent
        let generation = initialObservation.generation
        guard initialConsent.isEnabled else {
            // Unknown/future consent is a contract transition, not a temporary read
            // filter. Use the full cryptographic purge so restoring stale consent bytes
            // cannot replay an old queue.
            if initialObservation.isInvalid {
                onInvalidConsentGuardPassed()
                invalidateQueueForInvalidConsent(
                    expectedGeneration: generation,
                    durableEpoch: initialObservation.durableEpoch
                )
                // Join any already-admitted revocation so readback cannot return before
                // its cryptographic purge has reached a durable result.
                Self.persistenceQueue.sync {}
            }
            return []
        }
        return try Self.persistenceQueue.sync {
            let envelopes = try loadAndExpireQueue().map { try encoder.encode($0) }
            let finalObservation = observeConsent(.readbackFinal)
            let finalConsent = finalObservation.consent
            let invalidFinalConsent = finalObservation.isInvalid
            Self.stateLock.lock()
            let remainsAuthorized = generation == Self.consentGeneration && finalConsent == initialConsent
            Self.stateLock.unlock()
            guard remainsAuthorized else {
                if invalidFinalConsent {
                    invalidateQueueForInvalidConsentOnPersistenceQueue(
                        expectedGeneration: finalObservation.generation,
                        durableEpoch: finalObservation.durableEpoch
                    )
                }
                return []
            }
            return envelopes
        }
    }

    func currentQueuedEnvelope(matching data: Data) throws -> Data? {
        guard let target = try? decoder.decode(Envelope.self, from: data) else { return nil }
        return try queuedEnvelopes().first { encoded in
            guard let candidate = try? decoder.decode(Envelope.self, from: encoded) else { return false }
            return candidate.hasSameIdentity(as: target)
        }
    }

    /// Removes only the exact, already-uploaded prefix. Newer offline events remain queued.
    func acknowledgeUploadedEnvelopes(_ uploaded: [Data]) throws -> Bool {
        guard !uploaded.isEmpty else { return false }
        let admission = observeConsent()
        guard admission.consent.isEnabled else { return false }
        return try Self.persistenceQueue.sync {
            let currentConsent = observeConsent()
            Self.stateLock.lock()
            let remainsAuthorized = admission.generation == Self.consentGeneration
            Self.stateLock.unlock()
            guard remainsAuthorized, currentConsent.consent == admission.consent else { return false }
            let current = try readQueueWithoutExpiry()
            let encoded = try current.map { try encoder.encode($0) }
            guard encoded.starts(with: uploaded) else { return false }
            try persistEncrypted(Array(current.dropFirst(uploaded.count)))
            return true
        }
    }

    /// Startup readback only replays prior sessions. Current-session events already
    /// have a direct delivery scheduled by their capture path.
    func queuedEnvelopesForDelivery() throws -> [Data] {
        try queuedEnvelopes().filter { data in
            guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return false }
            return envelope.appSessionID != appSessionID
        }
    }

    /// Removes one successfully delivered item from the same bounded durable queue.
    /// A consent change between delivery and acknowledgement fails closed and purge owns cleanup.
    func acknowledgeQueuedEnvelope(_ data: Data) throws {
        let observation = observeConsent()
        guard observation.consent.isEnabled,
              let target = try? decoder.decode(Envelope.self, from: data)
        else { return }
        try Self.persistenceQueue.sync {
            var queue = try loadAndExpireQueue()
            guard queue.contains(target), observeConsent().consent == observation.consent else { return }
            if target.eventName == "release_session_ended" {
                queue.removeAll {
                    $0.appSessionID == target.appSessionID
                        && ($0.eventName == "release_session_started" || $0.eventName == "release_session_ended")
                }
            } else {
                queue.remove(at: queue.firstIndex(of: target)!)
            }
            try persist(queue)
        }
    }

    func incrementReleaseSessionErrorCount() throws {
        guard consent.isEnabled else { return }
        try Self.persistenceQueue.sync {
            var queue = try loadAndExpireQueue()
            guard let index = queue.lastIndex(where: {
                $0.eventName == "release_session_started" && $0.appSessionID == appSessionID
            }) else {
                pendingReleaseSessionErrorCounts[appSessionID] = min(
                    pendingReleaseSessionErrorCounts[appSessionID, default: 0] + 1,
                    1_000
                )
                return
            }
            let start = queue[index]
            let current: Int
            if case .integer(let value) = start.properties["session_error_count"] {
                current = value
            } else {
                current = 0
            }
            queue[index] = start.replacingProperties([
                "session_error_count": .integer(min(current + 1, 1_000)),
            ])
            try persist(queue)
        }
    }

    func markReleaseSessionStartedDelivered(_ data: Data) throws {
        guard consent.isEnabled,
              let target = try? decoder.decode(Envelope.self, from: data),
              target.eventName == "release_session_started"
        else { return }
        try Self.persistenceQueue.sync {
            var queue = try loadAndExpireQueue()
            guard let index = queue.firstIndex(where: { $0.hasSameIdentity(as: target) }) else { return }
            let start = queue[index]
            queue[index] = start.replacingProperties(["session_start_delivered": .boolean(true)])
            try persist(queue)
        }
    }

    /// Converts this process's durable open release session into a terminal event.
    /// The original pseudonymous session id and start timestamp remain available to
    /// the vendor adapter; only the terminal event timestamp changes.
    func closeReleaseSession(status: String) throws -> Data? {
        guard ["exited", "abnormal"].contains(status), consent.isEnabled else { return nil }
        return try Self.persistenceQueue.sync {
            var queue = try loadAndExpireQueue()
            guard let index = queue.lastIndex(where: {
                $0.eventName == "release_session_started" && $0.appSessionID == appSessionID
            }) else { return nil }
            let start = queue[index]
            let end = Envelope(
                schemaVersion: start.schemaVersion,
                eventName: "release_session_ended",
                timestampUTC: now(),
                sessionStartedUTC: start.timestampUTC,
                appVersion: start.appVersion,
                appBuild: start.appBuild,
                environment: start.environment,
                consentVersion: start.consentVersion,
                installationID: start.installationID,
                appSessionID: start.appSessionID,
                eventSequence: start.eventSequence,
                properties: start.properties.merging(["session_status": .string(status)]) { _, replacement in replacement }
            )
            queue[index] = end
            try persist(queue)
            return try encoder.encode(end)
        }
    }

    /// Any durable open session from a different process ended without a clean close.
    func recoverAbandonedReleaseSessions() throws {
        guard consent.isEnabled else { return }
        try Self.persistenceQueue.sync {
            var queue = try loadAndExpireQueue()
            var changed = false
            for index in queue.indices where queue[index].eventName == "release_session_started"
                && queue[index].appSessionID != appSessionID {
                let start = queue[index]
                queue[index] = Envelope(
                    schemaVersion: start.schemaVersion,
                    eventName: "release_session_ended",
                    timestampUTC: now(),
                    sessionStartedUTC: start.timestampUTC,
                    appVersion: start.appVersion,
                    appBuild: start.appBuild,
                    environment: start.environment,
                    consentVersion: start.consentVersion,
                    installationID: start.installationID,
                    appSessionID: start.appSessionID,
                    eventSequence: start.eventSequence,
                    properties: start.properties.merging(["session_status": .string("abnormal")]) { _, replacement in replacement }
                )
                changed = true
            }
            if changed { try persist(queue) }
        }
    }

    private static func isValidAppVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{1,4}\.[0-9]{1,4}(?:\.[0-9]{1,4})?$"#, options: .regularExpression) != nil
    }

    private static func isValidAppBuild(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{1,14}$"#, options: .regularExpression) != nil
    }

    private func readQueueWithoutExpiry() throws -> [Envelope] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        guard let keyData = try readQueueKey() else { return [] }
        let data = try Data(contentsOf: queueURL)
        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            let clear = try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
            return try decoder.decode([Envelope].self, from: clear)
        } catch {
            // A rotated shared queue key or tampered payload is irrecoverable. Delete
            // the unreadable vendor queue so a later consent epoch can persist again.
            try removeQueuedItems()
            mutateDiagnostics { $0.rejected += 1 }
            return []
        }
    }

    private func loadAndExpireQueue() throws -> [Envelope] {
        let queue = try readQueueWithoutExpiry()
        let valid = queue.filter(isValidPersistedEnvelope)
        let rejected = queue.count - valid.count
        if rejected > 0 {
            mutateDiagnostics { $0.rejected += rejected }
            try persist(valid)
        }
        let cutoff = now().addingTimeInterval(-Double(configuration.retentionDays) * 86_400)
        let retained = valid.filter {
            $0.timestampUTC >= cutoff
                || ($0.eventName == "release_session_started" && $0.appSessionID == appSessionID)
        }
        let removed = valid.count - retained.count
        if removed > 0 {
            mutateDiagnostics { $0.expired += removed }
            try persist(retained)
        }
        return retained
    }

    private func persist(_ queue: [Envelope]) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        if queue.isEmpty {
            // Make retained content unreadable first, then surface deletion failure to the
            // record boundary where it becomes a local, non-throwing diagnostic outcome.
            try persistEncrypted(queue)
            do {
                try removeQueuedItems()
            } catch {
                mutateDiagnostics { $0.queueDeleteFailed += 1 }
                throw error
            }
        } else {
            try persistEncrypted(queue)
        }
    }

    private func persistEncrypted(_ queue: [Envelope]) throws {
        let keyData: Data
        if let existing = try readQueueKey(), existing.count == 32 {
            keyData = existing
        } else {
            keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try saveQueueKey(keyData)
        }
        let clear = try encoder.encode(queue)
        let sealed = try AES.GCM.seal(clear, using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else { throw PurgeError.queueStillPresent }
        try writeData(combined, queueURL)
    }

    private func isValidPersistedEnvelope(_ envelope: Envelope) -> Bool {
        guard envelope.schemaVersion == 1,
              Self.schemaV1[envelope.eventName] != nil,
              Self.isValidAppVersion(envelope.appVersion),
              Self.isValidAppBuild(envelope.appBuild),
              envelope.environment == configuration.environment.rawValue,
              envelope.consentVersion == readConsent().version,
              envelope.installationID == installationID,
              UUID(uuidString: envelope.appSessionID) != nil,
              envelope.eventSequence >= 0,
              envelope.timestampUTC <= now(),
              (envelope.sessionStartedUTC == nil
                  || (envelope.eventName == "release_session_ended"
                      && envelope.sessionStartedUTC! <= envelope.timestampUTC)),
              let rules = Self.schemaV1[envelope.eventName],
              Set(envelope.properties.keys).isSubset(of: Set(rules.keys))
        else { return false }
        return envelope.properties.allSatisfy { rules[$0.key]?.accepts($0.value) == true }
    }

    private func allocateEventContext() -> (appSessionID: String, eventSequence: Int) {
        sequenceLock.lock()
        nextEventSequence += 1
        let value = (appSessionID, nextEventSequence)
        sequenceLock.unlock()
        return value
    }

    func rotateAppSessionIdentity() {
        let rotatedID = uuid().uuidString.lowercased()
        sequenceLock.lock()
        appSessionID = rotatedID
        nextEventSequence = 0
        sequenceLock.unlock()
    }

    private func mutateDiagnostics(_ mutation: (inout LocalDiagnostics) -> Void) {
        diagnosticsLock.lock()
        mutation(&diagnostics)
        diagnosticsLock.unlock()
    }

    private func invalidateQueueForInvalidConsent(expectedGeneration: UInt64, durableEpoch: String) {
        guard let invalidation = admitInvalidConsentInvalidation(
            expectedGeneration: expectedGeneration,
            durableEpoch: durableEpoch
        ) else {
            return
        }
        if invalidation.didAdvanceGeneration { onInvalidConsentGenerationAdvanced() }
        submitRevocationIfNeeded(invalidation)
        invalidation.task.group.wait()
    }

    private func scheduleInvalidConsentInvalidation(expectedGeneration: UInt64, durableEpoch: String) {
        guard let invalidation = admitInvalidConsentInvalidation(
            expectedGeneration: expectedGeneration,
            durableEpoch: durableEpoch
        ) else {
            return
        }
        if invalidation.didAdvanceGeneration { onInvalidConsentGenerationAdvanced() }
        submitRevocationIfNeeded(invalidation)
    }

    private func invalidateQueueForInvalidConsentOnPersistenceQueue(expectedGeneration: UInt64, durableEpoch: String) {
        guard let invalidation = admitInvalidConsentInvalidation(
            expectedGeneration: expectedGeneration,
            durableEpoch: durableEpoch
        ) else {
            return
        }
        if invalidation.didAdvanceGeneration { onInvalidConsentGenerationAdvanced() }
        executeRevocationIfNeeded(invalidation)
    }

    private final class RevocationTask {
        let group = DispatchGroup()
        private let lock = NSLock()
        private let execution: (UInt64, String) -> DisableEvidence?
        private var submitted = false
        private var executing = false
        private var evidence: DisableEvidence?
        private var creationGeneration: UInt64?
        private var token: String?

        init(execution: @escaping (UInt64, String) -> DisableEvidence?) {
            self.execution = execution
            group.enter()
        }

        var completedEvidence: DisableEvidence? {
            lock.lock()
            defer { lock.unlock() }
            return evidence
        }

        func bind(generation: UInt64, token: String) {
            lock.lock()
            precondition(creationGeneration == nil && self.token == nil)
            creationGeneration = generation
            self.token = token
            lock.unlock()
        }

        func claimSubmission() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !submitted else { return false }
            submitted = true
            return true
        }

        func claimExecution() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !executing else { return false }
            executing = true
            return true
        }

        func execute() -> DisableEvidence? {
            lock.lock()
            let generation = creationGeneration
            let token = token
            lock.unlock()
            guard let generation, let token else { return nil }
            return execution(generation, token)
        }

        func complete(with evidence: DisableEvidence?) {
            lock.lock()
            self.evidence = evidence
            lock.unlock()
            group.leave()
        }
    }

    private struct RevocationAdmission {
        let generation: UInt64
        let token: String
        let task: RevocationTask
        let didAdvanceGeneration: Bool
    }

    private func admitInvalidConsentInvalidation(expectedGeneration: UInt64, durableEpoch: String) -> RevocationAdmission? {
        let disabled = Consent(isEnabled: false, version: 0, grantedAt: nil)
        let encodedDisabled = try? encoder.encode(disabled)
        Self.consentTransitionLock.lock()
        if let token = defaults.string(forKey: revocationKey) {
            Self.stateLock.lock()
            if let task = Self.revocationTasks[token] {
                let generation = Self.consentGeneration
                Self.stateLock.unlock()
                Self.consentTransitionLock.unlock()
                onRevocationJoined()
                return RevocationAdmission(generation: generation, token: token, task: task, didAdvanceGeneration: false)
            }
            guard expectedGeneration == Self.consentGeneration else {
                Self.stateLock.unlock()
                Self.consentTransitionLock.unlock()
                return nil
            }
            Self.consentGeneration &+= 1
            let generation = Self.consentGeneration
            let task = RevocationTask { [self] generation, token in
                purgeInvalidConsentIfCurrent(generation: generation, token: token)
            }
            task.bind(generation: generation, token: token)
            Self.revocationTasks = [token: task]
            Self.stateLock.unlock()
            Self.consentTransitionLock.unlock()
            postExternalTelemetryConsentChange(.externalTelemetryConsentWillRevoke)
            onRevocationAdmitted()
            return RevocationAdmission(generation: generation, token: token, task: task, didAdvanceGeneration: true)
        }
        Self.stateLock.lock()
        guard expectedGeneration == Self.consentGeneration,
              durableEpoch != Self.completedRevocationEpoch else {
            Self.stateLock.unlock()
            Self.consentTransitionLock.unlock()
            return nil
        }
        Self.consentGeneration &+= 1
        let invalidationGeneration = Self.consentGeneration
        Self.stateLock.unlock()
        // This lightweight durable barrier closes the process-exit window before the
        // asynchronous Keychain and file purge. Explicit consent enablement is the only
        // transition allowed to clear it without proving erasure.
        let revocationToken = UUID().uuidString.lowercased()
        let task = RevocationTask { [self] generation, token in
            purgeInvalidConsentIfCurrent(generation: generation, token: token)
        }
        task.bind(generation: invalidationGeneration, token: revocationToken)
        Self.stateLock.lock()
        Self.revocationTasks = [revocationToken: task]
        Self.stateLock.unlock()
        defaults.set(revocationToken, forKey: revocationKey)
        defaults.set(encodedDisabled, forKey: consentKey)
        Self.consentTransitionLock.unlock()
        postExternalTelemetryConsentChange(.externalTelemetryConsentWillRevoke)
        onRevocationAdmitted()
        return RevocationAdmission(generation: invalidationGeneration, token: revocationToken, task: task, didAdvanceGeneration: true)
    }

    private func submitRevocationIfNeeded(_ invalidation: RevocationAdmission) {
        guard invalidation.task.claimSubmission() else { return }
        Self.persistenceQueue.async { [self] in executeRevocationIfNeeded(invalidation) }
    }

    private func executeRevocationIfNeeded(_ invalidation: RevocationAdmission) {
        guard invalidation.task.claimExecution() else { return }
        let evidence = invalidation.task.execute()
        onRevocationWillComplete()
        if evidence?.remainingItems == 0 || evidence == nil {
            Self.stateLock.lock()
            if Self.revocationTasks[invalidation.token] === invalidation.task {
                Self.revocationTasks.removeValue(forKey: invalidation.token)
            }
            Self.stateLock.unlock()
        }
        invalidation.task.complete(with: evidence)
    }

    private func purgeInvalidConsentIfCurrent(generation: UInt64, token: String) -> DisableEvidence? {
        Self.stateLock.lock()
        let stillCurrent = generation == Self.consentGeneration
        Self.stateLock.unlock()
        guard stillCurrent else { return nil }
        // Invalid consent always rotates the cryptographic boundary, even if queue
        // validation already removed the file. Restoring stale consent bytes must not
        // make an earlier key usable again.
        let evidence = disableAndPurgePersistedState()
        guard evidence.remainingItems == 0 else { return evidence }
        onRevocationCleanupChecked()
        Self.consentTransitionLock.lock()
        let tokenRemainsCurrent = defaults.string(forKey: revocationKey) == token
        let storeID = defaults.string(forKey: installationIDKey) ?? "uninitialized-installation"
        let consentEpoch = defaults.string(forKey: consentEpochKey) ?? "legacy-consent"
        Self.stateLock.lock()
        let remainsCurrent = generation == Self.consentGeneration
        let retiredEpoch = remainsCurrent && tokenRemainsCurrent
        if retiredEpoch {
            // Publish retirement in the same transaction that removes the durable token.
            // A participant that cached this invalid epoch can observe neither state as
            // absent and recreate purge work in between them.
            Self.completedRevocationEpoch = "\(storeID):\(consentEpoch)"
        }
        Self.stateLock.unlock()
        if retiredEpoch { defaults.removeObject(forKey: revocationKey) }
        Self.consentTransitionLock.unlock()
        if retiredEpoch { onRevocationEpochRetired() }
        return evidence
    }

    enum ConsentError: Error {
        case invalidVersion
        case transitionSuperseded
    }

    enum PurgeError: Error {
        case queueStillPresent
    }
}
