import Foundation
import XCTest
@testable import InsightKitApp

final class SentryDiagnosticsAdapterTests: XCTestCase {
    func testRawFailureContentIsScrubbedBeforeSyntheticTransportReceivesEnvelope() throws {
        let fixture = try Fixture()
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        let result = adapter.capture(.init(
            workflow: .live,
            phase: .running,
            engineClass: .local,
            providerClass: .none,
            errorCategory: .runtime,
            recoveryResult: .succeeded,
            errorMessage: "secret meeting words",
            breadcrumbs: ["/Users/person/private/meeting.m4a"],
            contexts: ["request": "Bearer sk-secret"],
            attachments: [Data("transcript".utf8)]
        ))

        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(transport.waitForEnvelope())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.envelopes[0]) as? [String: Any])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(properties["workflow"] as? String, "live")
        XCTAssertEqual(properties["phase"] as? String, "running")
        XCTAssertEqual(properties["engine_class"] as? String, "local")
        XCTAssertEqual(properties["provider_class"] as? String, "none")
        XCTAssertEqual(properties["error_category"] as? String, "runtime")
        XCTAssertEqual(properties["recovery_result"] as? String, "succeeded")
        XCTAssertNil(properties["error_message"])
        XCTAssertFalse(String(data: transport.envelopes[0], encoding: .utf8)!.contains("secret"))
        XCTAssertEqual(object["app_version"] as? String, "1.2.3")
        XCTAssertEqual(object["app_build"] as? String, "71")
        XCTAssertEqual(object["environment"] as? String, "development")
        let deadline = Date().addingTimeInterval(1)
        while try !fixture.gate.queuedEnvelopes().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(try fixture.gate.queuedEnvelopes().isEmpty)
    }

    func testDisabledGateNeverInvokesTransport() throws {
        let fixture = try Fixture(enable: false)
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.capture(.syntheticFailure), .disabled)
        XCTAssertFalse(transport.waitForEnvelope(timeout: 0.1))
        XCTAssertTrue(transport.envelopes.isEmpty)
    }

    func testUnifiedConsentRevocationCancelsInFlightSentryDelivery() throws {
        let fixture = try Fixture()
        let sentryGate = try fixture.siblingGate(relativePath: "Sentry")
        let transport = BlockingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: sentryGate, transport: transport)
        XCTAssertEqual(adapter.capture(.syntheticFailure), .accepted)
        XCTAssertTrue(transport.waitForAttempt())

        try ProductAnalytics(gate: fixture.gate).setConsent(enabled: false)

        XCTAssertTrue(transport.waitForCancellation())
        XCTAssertTrue(try sentryGate.queuedEnvelopes().isEmpty)
    }

    func testExplicitDisablePurgesWithoutTelemetryEnvironment() throws {
        let fixture = try Fixture()
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "review_opened",
            properties: ["workflow": "live", "phase": "reviewing"]
        )).result, .accepted)
        let deadline = Date().addingTimeInterval(1)
        while try fixture.gate.queuedEnvelopes().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        _ = SentryDiagnosticsRuntime(
            environment: ["INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "0"],
            gateOverride: fixture.gate
        )

        XCTAssertFalse(fixture.gate.consent.isEnabled)
        XCTAssertTrue(try fixture.gate.queuedEnvelopes().isEmpty)
    }

    func testSiblingVendorQueueRecoversAfterSharedKeyRotation() throws {
        let fixture = try Fixture()
        let sentryGate = try fixture.siblingGate(relativePath: "Sentry")
        XCTAssertEqual(sentryGate.record(event: .init(
            name: "workflow_failed",
            properties: [
                "workflow": "live",
                "phase": "running",
                "engine_class": "local",
                "provider_class": "none",
                "error_category": "runtime",
                "recovery_result": "not-attempted",
            ]
        )).result, .accepted)
        let firstDeadline = Date().addingTimeInterval(1)
        while try sentryGate.queuedEnvelopes().isEmpty, Date() < firstDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try sentryGate.queuedEnvelopes().count, 1)

        _ = fixture.gate.disableAndPurge()
        try fixture.gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "review_opened",
            properties: ["workflow": "live", "phase": "reviewing"]
        )).result, .accepted)

        let restartedSentryGate = try fixture.siblingGate(relativePath: "Sentry")
        XCTAssertEqual(restartedSentryGate.record(event: .init(
            name: "release_session_started",
            properties: ["session_status": "ok"]
        )).result, .accepted)
        let secondDeadline = Date().addingTimeInterval(1)
        while try restartedSentryGate.queuedEnvelopes().isEmpty, Date() < secondDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try restartedSentryGate.queuedEnvelopes().count, 1)
    }

    func testThrowingTransportDoesNotEscapeCaptureBoundary() throws {
        let fixture = try Fixture()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: ThrowingSentryTransport())

        XCTAssertEqual(adapter.capture(.syntheticFailure), .accepted)
    }

    func testNewAdapterReplaysGateAuthorizedEnvelopeAfterTransportFailure() throws {
        let fixture = try Fixture()
        let failing = SignalingThrowingSentryTransport()
        let first = SentryDiagnosticsAdapter(gate: fixture.gate, transport: failing)
        XCTAssertEqual(first.captureReleaseSession(.ok), .accepted)
        XCTAssertTrue(failing.waitForAttempt())
        XCTAssertEqual(first.captureReleaseSession(.exited), .accepted)
        XCTAssertTrue(failing.waitForAttempt())

        let recovered = RecordingSentryTransport()
        let restarted = SentryDiagnosticsAdapter(gate: try fixture.restartedGate(), transport: recovered)

        XCTAssertTrue(recovered.waitForEnvelope())
        let replayedNames = try recovered.envelopes.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])["event_name"] as? String
        }
        XCTAssertEqual(replayedNames, ["release_session_ended"])
        let deadline = Date().addingTimeInterval(1)
        while try !fixture.gate.queuedEnvelopes().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(try fixture.gate.queuedEnvelopes().isEmpty)
        _ = restarted
    }

    func testReleaseHealthAndPerformanceUseBoundedApprovedEvents() throws {
        let fixture = try Fixture()
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.captureReleaseSession(.ok), .accepted)
        XCTAssertEqual(adapter.capturePerformance(workflow: .import, phase: .finalizing, durationMilliseconds: 9_999_999), .accepted)
        XCTAssertTrue(transport.waitForEnvelope())
        XCTAssertTrue(transport.waitForEnvelope())
        let text = transport.envelopes.compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("release_session_started"))
        XCTAssertTrue(text.contains("3600000"))
        XCTAssertFalse(text.contains("9999999"))
    }

    func testSuccessfulCleanExitAcknowledgesPairedDurableSessionState() throws {
        let fixture = try Fixture()
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.captureReleaseSession(.ok), .accepted)
        XCTAssertTrue(transport.waitForEnvelope())
        XCTAssertEqual(adapter.captureReleaseSession(.exited), .accepted)
        XCTAssertTrue(transport.waitForEnvelope())
        let deadline = Date().addingTimeInterval(1)
        while try !fixture.gate.queuedEnvelopes().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(try fixture.gate.queuedEnvelopes().isEmpty)
    }

    func testStartupDrainRetainsCurrentProcessOpenSessionMarker() throws {
        let fixture = try Fixture()
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "release_session_started",
            properties: ["session_status": "ok"]
        )).result, .accepted)
        XCTAssertEqual(try fixture.gate.queuedEnvelopes().count, 1)
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertFalse(transport.waitForEnvelope(timeout: 0.1))
        XCTAssertEqual(try fixture.gate.queuedEnvelopes().count, 1)
        _ = adapter
    }

    func testClosingReleaseSessionNeverExceedsGateQueueBound() throws {
        let fixture = try Fixture(maxQueueItems: 2)
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "release_session_started",
            properties: ["session_status": "ok"]
        )).result, .accepted)
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "review_opened",
            properties: ["workflow": "record-review"]
        )).result, .accepted)
        XCTAssertEqual(try fixture.gate.queuedEnvelopes().count, 2)

        let terminal = try XCTUnwrap(fixture.gate.closeReleaseSession(status: "exited"))

        XCTAssertLessThanOrEqual(try fixture.gate.queuedEnvelopes().count, 2)
        XCTAssertTrue(String(decoding: terminal, as: UTF8.self).contains("release_session_ended"))
        XCTAssertTrue(String(decoding: terminal, as: UTF8.self).contains("exited"))
    }

    func testRecoveringManyAbandonedSessionsNeverExceedsGateQueueBound() throws {
        let fixture = try Fixture(maxQueueItems: 3)
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "release_session_started",
            properties: ["session_status": "ok"]
        )).result, .accepted)
        let second = try fixture.restartedGate()
        XCTAssertEqual(second.record(event: .init(
            name: "release_session_started",
            properties: ["session_status": "ok"]
        )).result, .accepted)
        let third = try fixture.restartedGate()
        XCTAssertEqual(third.record(event: .init(
            name: "release_session_started",
            properties: ["session_status": "ok"]
        )).result, .accepted)
        XCTAssertEqual(try fixture.gate.queuedEnvelopes().count, 3)

        let recovery = try fixture.restartedGate()
        try recovery.recoverAbandonedReleaseSessions()

        XCTAssertLessThanOrEqual(try fixture.gate.queuedEnvelopes().count, 3)
        let recovered = try recovery.queuedEnvelopesForDelivery().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(recovered.filter { $0.contains("release_session_ended") && $0.contains("abnormal") }.count, 3)
    }

    func testRuntimeConfigurationIsDefaultOffAndRequiresHTTPSDSN() {
        XCTAssertNil(SentryRuntimeConfiguration.from(environment: [:]))
        XCTAssertNil(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "http://public@example.invalid/71",
        ]))
        XCTAssertNotNil(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid/71",
        ]))
    }

    func testHTTPTransportBuildsSerializableSentryEventAndTransactionEnvelopes() throws {
        let fixture = try Fixture()
        let approved = try XCTUnwrap(fixture.gate.record(event: .init(name: "workflow_completed", properties: [
            "workflow": "live", "phase": "running", "outcome": "succeeded", "duration_bucket_ms": 5_000,
        ])).debugEnvelope)
        let configuration = try XCTUnwrap(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid/prefix/71",
        ]))

        let request = try SentryHTTPTransport(configuration: configuration).makeRequest(
            approvedEnvelope: approved,
            failureStack: []
        )

        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/prefix/api/71/envelope/")
        XCTAssertEqual(request.timeoutInterval, 2)
        let body = try XCTUnwrap(request.httpBody)
        let lines = body.split(separator: 0x0a)
        XCTAssertEqual(lines.count, 3)
        let item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "transaction")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[2])) as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "transaction")
        XCTAssertNil(payload["exception"])
        XCTAssertNotEqual(payload["start_timestamp"] as? String, payload["timestamp"] as? String)
        let tags = try XCTUnwrap(payload["tags"] as? [String: Any])
        XCTAssertTrue(tags.values.allSatisfy { $0 is String })
        XCTAssertEqual(tags["duration_bucket_ms"] as? String, "5000")

        let failure = try XCTUnwrap(fixture.gate.record(event: .init(name: "workflow_failed", properties: [
            "workflow": "live", "phase": "running", "error_category": "runtime",
        ])).debugEnvelope)
        let failureRequest = try SentryHTTPTransport(configuration: configuration).makeRequest(
            approvedEnvelope: failure,
            failureStack: [0x1234]
        )
        let failureLines = try XCTUnwrap(failureRequest.httpBody).split(separator: 0x0a)
        let failurePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failureLines[2])) as? [String: Any])
        let exception = try XCTUnwrap(failurePayload["exception"] as? [String: Any])
        let values = try XCTUnwrap(exception["values"] as? [[String: Any]])
        let stacktrace = try XCTUnwrap(values.first?["stacktrace"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(stacktrace["frames"] as? [[String: Any]]).first?["instruction_addr"] as? String,
            "0x1234"
        )

        let sessionFixture = try Fixture(maxQueueItems: 1)
        XCTAssertEqual(sessionFixture.gate.record(event: .init(
            name: "release_session_started",
            properties: ["session_status": "ok"]
        )).result, .accepted)
        let compactTerminal = try XCTUnwrap(sessionFixture.gate.closeReleaseSession(status: "exited"))
        let sessionRequest = try SentryHTTPTransport(configuration: configuration).makeRequest(
            approvedEnvelope: compactTerminal,
            failureStack: []
        )
        let sessionLines = try XCTUnwrap(sessionRequest.httpBody).split(separator: 0x0a)
        let sessionPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sessionLines[2])) as? [String: Any])
        XCTAssertEqual(sessionPayload["init"] as? Bool, true)
        XCTAssertEqual(sessionPayload["status"] as? String, "exited")
    }
}

private final class RecordingSentryTransport: SentryDiagnosticsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let delivered = DispatchSemaphore(value: 0)
    private(set) var envelopes: [Data] = []

    func send(envelope: Data, failureStack: [UInt64]) throws {
        lock.lock()
        envelopes.append(envelope)
        lock.unlock()
        delivered.signal()
    }

    func waitForEnvelope(timeout: TimeInterval = 1) -> Bool {
        delivered.wait(timeout: .now() + timeout) == .success
    }
}

private final class BlockingSentryTransport: SentryDiagnosticsTransport, @unchecked Sendable {
    private let attempted = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let cancelled = DispatchSemaphore(value: 0)

    func send(envelope: Data, failureStack: [UInt64]) throws {
        attempted.signal()
        _ = release.wait(timeout: .now() + 1)
        throw CocoaError(.userCancelled)
    }

    func cancelAll() { cancelled.signal(); release.signal() }
    func waitForAttempt() -> Bool { attempted.wait(timeout: .now() + 1) == .success }
    func waitForCancellation() -> Bool { cancelled.wait(timeout: .now() + 0.1) == .success }
}

private struct ThrowingSentryTransport: SentryDiagnosticsTransport {
    func send(envelope: Data, failureStack: [UInt64]) throws { throw CocoaError(.fileWriteUnknown) }
}

private final class SignalingThrowingSentryTransport: SentryDiagnosticsTransport, @unchecked Sendable {
    private let attempted = DispatchSemaphore(value: 0)
    func send(envelope: Data, failureStack: [UInt64]) throws {
        attempted.signal()
        throw CocoaError(.fileWriteUnknown)
    }
    func waitForAttempt() -> Bool { attempted.wait(timeout: .now() + 1) == .success }
}

private struct Fixture {
    let gate: ExternalTelemetryPrivacyGate
    private let defaults: UserDefaults
    private let directory: URL
    private let keyBox: QueueKeyBox
    private let maxQueueItems: Int

    init(enable: Bool = true, maxQueueItems: Int = 8) throws {
        let suite = "SentryDiagnosticsAdapterTests-\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        localDefaults.removePersistentDomain(forName: suite)
        let localDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let localKeyBox = QueueKeyBox()
        defaults = localDefaults
        directory = localDirectory
        keyBox = localKeyBox
        self.maxQueueItems = maxQueueItems
        gate = ExternalTelemetryPrivacyGate(
            configuration: try ExternalTelemetryConfiguration(environment: .development, retentionDays: 7, maxQueueItems: maxQueueItems),
            appVersion: "1.2.3",
            appBuild: "71",
            defaults: localDefaults,
            storageDirectory: localDirectory,
            readQueueKey: { localKeyBox.data },
            saveQueueKey: { localKeyBox.data = $0 },
            deleteQueueKey: { localKeyBox.data = nil }
        )
        if enable { try gate.setConsent(enabled: true, consentVersion: 1) }
    }

    func restartedGate() throws -> ExternalTelemetryPrivacyGate {
        ExternalTelemetryPrivacyGate(
            configuration: try ExternalTelemetryConfiguration(
                environment: .development,
                retentionDays: 7,
                maxQueueItems: maxQueueItems
            ),
            appVersion: "1.2.3",
            appBuild: "71",
            defaults: defaults,
            storageDirectory: directory,
            readQueueKey: { keyBox.data },
            saveQueueKey: { keyBox.data = $0 },
            deleteQueueKey: { keyBox.data = nil }
        )
    }

    func siblingGate(relativePath: String) throws -> ExternalTelemetryPrivacyGate {
        ExternalTelemetryPrivacyGate(
            configuration: try ExternalTelemetryConfiguration(
                environment: .development,
                retentionDays: 7,
                maxQueueItems: maxQueueItems
            ),
            appVersion: "1.2.3",
            appBuild: "71",
            defaults: defaults,
            storageDirectory: directory.appendingPathComponent(relativePath, isDirectory: true),
            readQueueKey: { keyBox.data },
            saveQueueKey: { keyBox.data = $0 },
            deleteQueueKey: { keyBox.data = nil }
        )
    }
}

private final class QueueKeyBox: @unchecked Sendable { var data: Data? }
