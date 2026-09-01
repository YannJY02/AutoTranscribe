import Foundation
import XCTest
@testable import InsightKitApp

final class SentryDiagnosticsAdapterTests: XCTestCase {
    private let enabledRuntimeEnvironment = [
        "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
        "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid/71",
        "POSTHOG_DEVELOPMENT_HOST": "https://example.invalid",
        "POSTHOG_DEVELOPMENT_PROJECT_KEY": "phc_test",
        "POSTHOG_DEVELOPMENT_RETENTION_VERIFIED": "1",
    ]

    private func makeFixture(enable: Bool = true, maxQueueItems: Int = 8) throws -> Fixture {
        let fixture = try Fixture(enable: enable, maxQueueItems: maxQueueItems)
        addTeardownBlock { fixture.cleanup() }
        return fixture
    }

    func testRawFailureContentIsScrubbedBeforeSyntheticTransportReceivesEnvelope() throws {
        let fixture = try makeFixture()
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        let result = adapter.capture(.init(
            workflow: .live,
            phase: .running,
            engineClass: .local,
            providerClass: .none,
            errorCategory: .runtime,
            recoveryResult: .succeeded,
            failureStack: [0x1111, 0x2222],
            errorMessage: "secret meeting words",
            breadcrumbs: ["/Users/person/private/meeting.m4a"],
            contexts: ["request": "Bearer sk-secret"],
            attachments: [Data("transcript".utf8)]
        ))

        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(transport.waitForEnvelope())
        XCTAssertEqual(transport.failureStacks, [[0x1111, 0x2222]])
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
        let fixture = try makeFixture(enable: false)
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.capture(.syntheticFailure), .disabled)
        XCTAssertFalse(transport.waitForEnvelope(timeout: 0.1))
        XCTAssertTrue(transport.envelopes.isEmpty)
    }

    func testSyntheticFailureCapturesTheCurrentCallStack() throws {
        let fixture = try makeFixture()
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.capture(.syntheticFailure), .accepted)
        XCTAssertTrue(transport.waitForEnvelope())
        XCTAssertFalse(try XCTUnwrap(transport.failureStacks.first).isEmpty)
    }

    func testHTTPTransportBackfillsStackForReplayedWorkflowFailure() throws {
        let fixture = try makeFixture()
        let approved = try XCTUnwrap(fixture.gate.record(event: .init(
            name: "workflow_failed",
            properties: ["workflow": "live", "phase": "running"]
        )).debugEnvelope)
        let configuration = try XCTUnwrap(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid/71",
        ]))

        let request = try SentryHTTPTransport(configuration: configuration).makeRequest(
            approvedEnvelope: approved,
            failureStack: []
        )

        let lines = try XCTUnwrap(request.httpBody).split(separator: 0x0a)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[2])) as? [String: Any])
        let exception = try XCTUnwrap(payload["exception"] as? [String: Any])
        let values = try XCTUnwrap(exception["values"] as? [[String: Any]])
        let stacktrace = try XCTUnwrap(values.first?["stacktrace"] as? [String: Any])
        XCTAssertFalse(try XCTUnwrap(stacktrace["frames"] as? [[String: Any]]).isEmpty)
    }

    func testUnifiedConsentRevocationCancelsInFlightSentryDelivery() throws {
        let fixture = try makeFixture()
        let sentryGate = try fixture.siblingGate(relativePath: "Sentry")
        let transport = BlockingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: sentryGate, transport: transport)
        XCTAssertEqual(adapter.capture(.syntheticFailure), .accepted)
        XCTAssertTrue(transport.waitForAttempt())

        try ProductAnalytics(gate: fixture.gate).setConsent(enabled: false)

        XCTAssertTrue(transport.waitForCancellation())
        XCTAssertTrue(try sentryGate.queuedEnvelopes().isEmpty)
    }

    func testInvalidConsentRevocationCancelsInFlightSentryDelivery() throws {
        let fixture = try makeFixture()
        let transport = BlockingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)
        XCTAssertEqual(adapter.capture(.syntheticFailure), .accepted)
        XCTAssertTrue(transport.waitForAttempt())

        try fixture.persistInvalidConsent()
        XCTAssertTrue(try fixture.gate.queuedEnvelopes().isEmpty)

        XCTAssertTrue(transport.waitForCancellation())
    }

    func testQueuedDeliveryCannotStartWhileRevocationCancellationIsPaused() throws {
        let fixture = try makeFixture()
        let sentryGate = try fixture.siblingGate(relativePath: "Sentry")
        let transport = PausedCancellationSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: sentryGate, transport: transport)
        XCTAssertEqual(adapter.capture(.syntheticFailure), .accepted)
        XCTAssertTrue(transport.waitForFirstAttempt())
        XCTAssertEqual(adapter.capture(.syntheticFailure), .queueFull)
        let revoked = expectation(description: "revocation completed")
        DispatchQueue.global().async {
            try? ProductAnalytics(gate: fixture.gate).setConsent(enabled: false)
            revoked.fulfill()
        }
        XCTAssertTrue(transport.waitForCancellation())

        XCTAssertFalse(transport.waitForSecondAttempt())

        transport.finishCancellation()
        wait(for: [revoked], timeout: 1)
    }

    func testSameAdapterStartsReleaseSessionAfterOptInAndReenable() throws {
        let fixture = try makeFixture(enable: false)
        let sentryGate = try fixture.siblingGate(relativePath: "Sentry")
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: sentryGate, transport: transport)
        let analytics = ProductAnalytics(gate: fixture.gate)

        try analytics.setConsent(enabled: true)
        XCTAssertTrue(transport.waitForEnvelope())
        try analytics.setConsent(enabled: false)
        try analytics.setConsent(enabled: true)
        XCTAssertTrue(transport.waitForEnvelope())

        let eventNames = try transport.envelopes.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])["event_name"] as? String
        }
        XCTAssertEqual(eventNames, ["release_session_started", "release_session_started"])
        let sessionIDs = try transport.envelopes.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])["app_session_id"] as? String
        }
        XCTAssertNotEqual(sessionIDs[0], sessionIDs[1])
        _ = adapter
    }

    func testEnabledRuntimePurgesConsentWhenPostHogIsUnavailable() throws {
        let fixture = try makeFixture()
        let transport = RecordingSentryTransport()

        _ = SentryDiagnosticsRuntime(
            environment: [
                "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
                "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid/71",
            ],
            gateOverride: fixture.gate,
            transportOverride: transport
        )

        XCTAssertFalse(fixture.gate.consent.isEnabled)
        XCTAssertFalse(transport.waitForEnvelope(timeout: 0.1))
    }

    func testExplicitDisablePurgesWithoutTelemetryEnvironment() throws {
        let fixture = try makeFixture()
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
        let fixture = try makeFixture()
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
        let fixture = try makeFixture()
        let transport = SignalingThrowingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.capture(.syntheticFailure), .accepted)
        XCTAssertTrue(transport.waitForAttempt())
        let deadline = Date().addingTimeInterval(1)
        while adapter.localDeliveryFailureCount < 2, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(adapter.localDeliveryFailureCount, 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(adapter.localDeliveryFailureCount, 2)
    }

    func testTransientDeliveryFailureRetriesWithoutAnotherEvent() throws {
        let fixture = try makeFixture()
        let transport = FailFirstThenPausingSuccessfulSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.capture(.syntheticFailure), .accepted)
        XCTAssertTrue(transport.waitForFailedAttempt())
        XCTAssertTrue(transport.waitForDeliveries(1))
        let deadline = Date().addingTimeInterval(1)
        while try !fixture.gate.queuedEnvelopes().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(try fixture.gate.queuedEnvelopes().isEmpty)
    }

    func testPersistedEnvelopeRetriesAfterDeliveryCapacityBecomesAvailable() throws {
        let fixture = try makeFixture(maxQueueItems: 16)
        let transport = PausingSuccessfulSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(
            adapter.capturePerformance(workflow: .live, phase: .running, durationMilliseconds: 1_000),
            .accepted
        )
        XCTAssertTrue(transport.waitForFirstAttempt())
        XCTAssertEqual(
            adapter.capturePerformance(workflow: .live, phase: .running, durationMilliseconds: 1_000),
            .queueFull
        )

        transport.releaseFirstAttempt()

        XCTAssertTrue(transport.waitForDeliveries(2))
        let deadline = Date().addingTimeInterval(1)
        while try !fixture.gate.queuedEnvelopes().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(try fixture.gate.queuedEnvelopes().isEmpty)
    }

    func testCapacityDrainRetainsReleaseStartUntilTerminalDelivery() throws {
        let fixture = try makeFixture(maxQueueItems: 16)
        let transport = PausingSuccessfulSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(
            adapter.capturePerformance(workflow: .live, phase: .running, durationMilliseconds: 1_000),
            .accepted
        )
        XCTAssertTrue(transport.waitForFirstAttempt())
        XCTAssertEqual(adapter.captureReleaseSession(.ok), .queueFull)

        transport.releaseFirstAttempt()

        XCTAssertTrue(transport.waitForDeliveries(2))
        let startDeadline = Date().addingTimeInterval(1)
        var queued = try fixture.gate.queuedEnvelopes()
        while queued.count != 1, Date() < startDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            queued = try fixture.gate.queuedEnvelopes()
        }
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(queued.first), as: UTF8.self).contains("release_session_started"))

        XCTAssertEqual(adapter.captureReleaseSession(.exited), .accepted)
        XCTAssertTrue(transport.waitForDeliveries(1))
        let endDeadline = Date().addingTimeInterval(1)
        while try !fixture.gate.queuedEnvelopes().isEmpty, Date() < endDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(try fixture.gate.queuedEnvelopes().isEmpty)
    }

    func testPriorSessionTerminalDoesNotClearCurrentStartDeduplication() throws {
        let fixture = try makeFixture(maxQueueItems: 16)
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "release_session_started",
            properties: ["session_status": "ok"]
        )).result, .accepted)
        _ = try XCTUnwrap(fixture.gate.closeReleaseSession(status: "exited"))
        let currentGate = try fixture.restartedGate()
        let transport = FailFirstThenPausingSuccessfulSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: currentGate, transport: transport)
        XCTAssertTrue(transport.waitForFailedAttempt())

        XCTAssertEqual(adapter.captureReleaseSession(.ok), .accepted)
        XCTAssertTrue(transport.waitForDeliveries(1))
        XCTAssertEqual(
            adapter.capturePerformance(workflow: .live, phase: .running, durationMilliseconds: 1_000),
            .accepted
        )
        XCTAssertTrue(transport.waitForPausedAttempt())
        XCTAssertEqual(
            adapter.capturePerformance(workflow: .live, phase: .running, durationMilliseconds: 1_000),
            .queueFull
        )

        transport.releasePausedAttempt()

        XCTAssertTrue(transport.waitForDeliveries(3))
        let drainDeadline = Date().addingTimeInterval(1)
        var queued = try currentGate.queuedEnvelopes()
        while queued.count != 1, Date() < drainDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            queued = try currentGate.queuedEnvelopes()
        }
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(queued.first), as: UTF8.self).contains("release_session_started"))
        XCTAssertEqual(transport.eventNames.filter { $0 == "release_session_started" }.count, 1)
    }

    func testNewAdapterReplaysGateAuthorizedEnvelopeAfterTransportFailure() throws {
        let fixture = try makeFixture()
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
        let fixture = try makeFixture()
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.captureReleaseSession(.ok), .accepted)
        XCTAssertEqual(adapter.capturePerformance(workflow: .import, phase: .finalizing, durationMilliseconds: 9_999_999), .queueFull)
        XCTAssertTrue(transport.waitForEnvelope())
        XCTAssertTrue(transport.waitForEnvelope())
        let text = transport.envelopes.compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("release_session_started"))
        XCTAssertTrue(text.contains("3600000"))
        XCTAssertFalse(text.contains("9999999"))
    }

    func testSuccessfulCleanExitAcknowledgesPairedDurableSessionState() throws {
        let fixture = try makeFixture()
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
        let fixture = try makeFixture()
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

    func testRuntimeStartsReleaseSessionAfterDrainingAFullPriorSessionQueue() throws {
        let fixture = try makeFixture(maxQueueItems: 1)
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "review_opened",
            properties: ["workflow": "live", "phase": "reviewing"]
        )).result, .accepted)
        XCTAssertEqual(try fixture.gate.queuedEnvelopes().count, 1)
        let restartedGate = try fixture.restartedGate()
        let transport = RecordingSentryTransport()
        let runtime = SentryDiagnosticsRuntime(
            environment: enabledRuntimeEnvironment,
            gateOverride: restartedGate,
            transportOverride: transport
        )

        XCTAssertTrue(transport.waitForEnvelope())
        XCTAssertTrue(transport.waitForEnvelope())
        runtime.applicationWillTerminate()
        XCTAssertTrue(transport.waitForEnvelope())

        let eventNames = try transport.envelopes.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])["event_name"] as? String
        }
        XCTAssertEqual(eventNames, ["review_opened", "release_session_started", "release_session_ended"])
    }

    func testFailedFullBacklogReplayStillPersistsTheCurrentReleaseSession() throws {
        let fixture = try makeFixture(maxQueueItems: 1)
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "review_opened",
            properties: ["workflow": "live", "phase": "reviewing"]
        )).result, .accepted)
        XCTAssertEqual(try fixture.gate.queuedEnvelopes().count, 1)
        let restartedGate = try fixture.restartedGate()
        let transport = SignalingThrowingSentryTransport()
        let runtime = SentryDiagnosticsRuntime(
            environment: enabledRuntimeEnvironment,
            gateOverride: restartedGate,
            transportOverride: transport
        )
        XCTAssertTrue(transport.waitForAttempt())

        let startDeadline = Date().addingTimeInterval(1)
        var queued = try restartedGate.queuedEnvelopes()
        while !queued.contains(where: { String(decoding: $0, as: UTF8.self).contains("release_session_started") }),
              Date() < startDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            queued = try restartedGate.queuedEnvelopes()
        }
        XCTAssertTrue(queued.contains { String(decoding: $0, as: UTF8.self).contains("release_session_started") })

        runtime.applicationWillTerminate()
        let terminal = try XCTUnwrap(restartedGate.queuedEnvelopes().first)
        XCTAssertTrue(String(decoding: terminal, as: UTF8.self).contains("release_session_ended"))
    }

    func testTerminationSuppressesAReleaseStartWaitingBehindStartupDrain() throws {
        let fixture = try makeFixture(maxQueueItems: 1)
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "review_opened",
            properties: ["workflow": "live", "phase": "reviewing"]
        )).result, .accepted)
        XCTAssertEqual(try fixture.gate.queuedEnvelopes().count, 1)
        let restartedGate = try fixture.restartedGate()
        let transport = PausingSuccessfulSentryTransport()
        let runtime = SentryDiagnosticsRuntime(
            environment: enabledRuntimeEnvironment,
            gateOverride: restartedGate,
            transportOverride: transport
        )
        XCTAssertTrue(transport.waitForFirstAttempt())

        runtime.applicationWillTerminate()
        transport.releaseFirstAttempt()

        XCTAssertFalse(transport.waitForSecondAttempt())
        XCTAssertTrue(try restartedGate.queuedEnvelopes().isEmpty)
    }

    func testStartupDrainDoesNotRaceCurrentProcessCaptureDelivery() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.gate.record(event: .init(
            name: "review_opened",
            properties: ["workflow": "live", "phase": "reviewing"]
        )).result, .accepted)

        XCTAssertTrue(try fixture.gate.queuedEnvelopesForDelivery().isEmpty)
        XCTAssertEqual(try fixture.restartedGate().queuedEnvelopesForDelivery().count, 1)
    }

    func testClosingReleaseSessionNeverExceedsGateQueueBound() throws {
        let fixture = try makeFixture(maxQueueItems: 2)
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
        let fixture = try makeFixture(maxQueueItems: 3)
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
        XCTAssertNil(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid",
        ]))
        XCTAssertNil(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "https://@example.invalid/71",
        ]))
        XCTAssertNotNil(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid/71",
        ]))
    }

    func testProductAnalyticsSignalsKeepOriginDimensionsWhenItsQueueIsFull() throws {
        let fixture = try makeFixture(maxQueueItems: 1)
        var signals: [ExternalTelemetryWorkflowSignal] = []
        let analytics = ProductAnalytics(gate: fixture.gate, onWorkflowSignal: { signals.append($0) })
        let path = ProductAnalyticsPath(analysisMode: "cloud", providerClass: "byok")

        analytics.workflowFailed("import", phase: "exporting", errorCode: "storage", recoveryAction: "retry", explicitPath: path)
        analytics.workflowFailed("import", phase: "exporting", errorCode: "storage", recoveryAction: "retry", explicitPath: path)
        analytics.recoveryCompleted("import", phase: "exporting", succeeded: true, explicitPath: path)
        analytics.workflowFailed(
            "import",
            phase: "exporting",
            errorCode: "storage",
            recoveryAction: "retry",
            explicitPath: path,
            completingRecovery: true
        )

        XCTAssertGreaterThan(fixture.gate.localDiagnostics.queueFull, 0)
        XCTAssertEqual(signals.count, 5)
        guard case .failure(let failure) = signals[1] else { return XCTFail("expected failure signal") }
        XCTAssertEqual(failure.workflow, .import)
        XCTAssertEqual(failure.phase, .exporting)
        XCTAssertEqual(failure.engineClass, .local)
        XCTAssertEqual(failure.providerClass, .byok)
        XCTAssertEqual(failure.errorCategory, .storage)
        XCTAssertEqual(failure.recoveryResult, .notAttempted)
        guard case .recovery(let recovery) = signals[2] else { return XCTFail("expected recovery signal") }
        XCTAssertEqual(recovery.result, .succeeded)
        guard case .recovery(let failedRecovery) = signals[3] else { return XCTFail("expected failed recovery signal") }
        XCTAssertEqual(failedRecovery.result, .failed)
        guard case .failure(let retriedFailure) = signals[4] else { return XCTFail("expected retried failure signal") }
        XCTAssertEqual(retriedFailure.recoveryResult, .failed)
    }

    func testRecoverySignalProducesSentryEnvelope() throws {
        let fixture = try makeFixture()
        let transport = RecordingSentryTransport()
        let adapter = SentryDiagnosticsAdapter(gate: fixture.gate, transport: transport)

        XCTAssertEqual(adapter.captureRecovery(.init(
            workflow: .live,
            phase: .reviewing,
            engineClass: .local,
            providerClass: .byok,
            result: .failed
        )), .accepted)

        XCTAssertTrue(transport.waitForEnvelope())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.envelopes[0]) as? [String: Any])
        XCTAssertEqual(object["event_name"] as? String, "recovery_completed")
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(properties["recovery_result"] as? String, "failed")

        let configuration = try XCTUnwrap(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid/71",
        ]))
        let request = try SentryHTTPTransport(configuration: configuration).makeRequest(
            approvedEnvelope: transport.envelopes[0],
            failureStack: [0x1234]
        )
        let lines = try XCTUnwrap(request.httpBody).split(separator: 0x0a)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[2])) as? [String: Any])
        XCTAssertEqual(payload["level"] as? String, "warning")
        XCTAssertNil(payload["exception"])
    }

    func testEnabledRuntimeUsesSharedDefaultEnvironmentAndStartsReleaseSession() throws {
        let fixture = try makeFixture()
        let transport = RecordingSentryTransport()

        let runtime = SentryDiagnosticsRuntime(
            environment: enabledRuntimeEnvironment,
            gateOverride: fixture.gate,
            transportOverride: transport
        )

        XCTAssertTrue(transport.waitForEnvelope())
        XCTAssertTrue(String(decoding: transport.envelopes[0], as: UTF8.self).contains("release_session_started"))
        _ = runtime
    }

    func testWorkflowFailureCarriesOriginStackThroughRuntimeToTransport() throws {
        let fixture = try makeFixture()
        let transport = RecordingSentryTransport()
        let runtime = SentryDiagnosticsRuntime(
            environment: enabledRuntimeEnvironment,
            gateOverride: fixture.gate,
            transportOverride: transport
        )
        XCTAssertTrue(transport.waitForEnvelope())
        let analytics = ProductAnalytics(gate: fixture.gate, onWorkflowSignal: runtime.capture)

        ProductAnalytics.submit(failureStack: [0x1111, 0x2222], using: analytics) {
            $0.workflowFailed(
                "live",
                phase: "running",
                errorCode: "runtime-unavailable",
                recoveryAction: "retry",
                explicitPath: .local
            )
        }

        XCTAssertTrue(transport.waitForEnvelope())
        XCTAssertEqual(transport.failureStacks.last, [0x1111, 0x2222])
    }

    func testHTTPTransportRejectsAfterCancellationUntilExplicitResume() throws {
        StubSentryURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubSentryURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let fixture = try makeFixture()
        let approved = try XCTUnwrap(fixture.gate.record(event: .init(
            name: "workflow_failed",
            properties: ["workflow": "live", "phase": "running"]
        )).debugEnvelope)
        let configuration = try XCTUnwrap(SentryRuntimeConfiguration.from(environment: [
            "INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED": "1",
            "INSIGHTKIT_SENTRY_DSN": "https://public@example.invalid/71",
        ]))
        let transport = SentryHTTPTransport(configuration: configuration, session: session)

        transport.cancelAll()
        XCTAssertThrowsError(try transport.send(envelope: approved, failureStack: []))
        XCTAssertEqual(StubSentryURLProtocol.requestCount, 0)
        transport.resume()
        XCTAssertNoThrow(try transport.send(envelope: approved, failureStack: []))
        XCTAssertEqual(StubSentryURLProtocol.requestCount, 1)
    }

    func testHTTPTransportBuildsSerializableSentryEventAndTransactionEnvelopes() throws {
        let fixture = try makeFixture()
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

        let sessionFixture = try makeFixture(maxQueueItems: 1)
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
    private(set) var failureStacks: [[UInt64]] = []

    func send(envelope: Data, failureStack: [UInt64]) throws {
        lock.lock()
        envelopes.append(envelope)
        failureStacks.append(failureStack)
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

private final class PausedCancellationSentryTransport: SentryDiagnosticsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attemptCount = 0
    private let firstAttempt = DispatchSemaphore(value: 0)
    private let secondAttempt = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let cancellationStarted = DispatchSemaphore(value: 0)
    private let cancellationMayFinish = DispatchSemaphore(value: 0)

    func send(envelope: Data, failureStack: [UInt64]) throws {
        lock.lock()
        attemptCount += 1
        let attempt = attemptCount
        lock.unlock()
        if attempt == 1 {
            firstAttempt.signal()
            _ = releaseFirst.wait(timeout: .now() + 1)
        } else {
            secondAttempt.signal()
        }
        throw CocoaError(.userCancelled)
    }

    func cancelAll() {
        cancellationStarted.signal()
        releaseFirst.signal()
        _ = cancellationMayFinish.wait(timeout: .now() + 1)
    }

    func waitForFirstAttempt() -> Bool { firstAttempt.wait(timeout: .now() + 1) == .success }
    func waitForSecondAttempt() -> Bool { secondAttempt.wait(timeout: .now() + 0.1) == .success }
    func waitForCancellation() -> Bool { cancellationStarted.wait(timeout: .now() + 1) == .success }
    func finishCancellation() { cancellationMayFinish.signal() }
}

private final class PausingSuccessfulSentryTransport: SentryDiagnosticsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attemptCount = 0
    private let firstAttempt = DispatchSemaphore(value: 0)
    private let secondAttempt = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let delivered = DispatchSemaphore(value: 0)

    func send(envelope: Data, failureStack: [UInt64]) throws {
        lock.lock()
        attemptCount += 1
        let attempt = attemptCount
        lock.unlock()
        if attempt == 1 {
            firstAttempt.signal()
            _ = releaseFirst.wait(timeout: .now() + 1)
        } else {
            secondAttempt.signal()
        }
        delivered.signal()
    }

    func waitForFirstAttempt() -> Bool { firstAttempt.wait(timeout: .now() + 1) == .success }
    func waitForSecondAttempt() -> Bool { secondAttempt.wait(timeout: .now() + 0.1) == .success }
    func releaseFirstAttempt() { releaseFirst.signal() }
    func waitForDeliveries(_ count: Int) -> Bool {
        (0 ..< count).allSatisfy { _ in delivered.wait(timeout: .now() + 1) == .success }
    }
}

private final class FailFirstThenPausingSuccessfulSentryTransport: SentryDiagnosticsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attemptCount = 0
    private var recordedEnvelopes: [Data] = []
    private let failedAttempt = DispatchSemaphore(value: 0)
    private let pausedAttempt = DispatchSemaphore(value: 0)
    private let releasePaused = DispatchSemaphore(value: 0)
    private let delivered = DispatchSemaphore(value: 0)

    var eventNames: [String] {
        lock.lock()
        let envelopes = recordedEnvelopes
        lock.unlock()
        return envelopes.compactMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["event_name"] as? String
        }
    }

    func send(envelope: Data, failureStack: [UInt64]) throws {
        lock.lock()
        attemptCount += 1
        let attempt = attemptCount
        lock.unlock()
        if attempt == 1 {
            failedAttempt.signal()
            throw CocoaError(.fileWriteUnknown)
        }
        if attempt == 3 {
            pausedAttempt.signal()
            _ = releasePaused.wait(timeout: .now() + 1)
        }
        lock.lock()
        recordedEnvelopes.append(envelope)
        lock.unlock()
        delivered.signal()
    }

    func waitForFailedAttempt() -> Bool { failedAttempt.wait(timeout: .now() + 1) == .success }
    func waitForPausedAttempt() -> Bool { pausedAttempt.wait(timeout: .now() + 1) == .success }
    func releasePausedAttempt() { releasePaused.signal() }
    func waitForDeliveries(_ count: Int) -> Bool {
        (0 ..< count).allSatisfy { _ in delivered.wait(timeout: .now() + 1) == .success }
    }
}

private final class StubSentryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); requests = 0; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SignalingThrowingSentryTransport: SentryDiagnosticsTransport, @unchecked Sendable {
    private let attempted = DispatchSemaphore(value: 0)
    func send(envelope: Data, failureStack: [UInt64]) throws {
        attempted.signal()
        throw CocoaError(.fileWriteUnknown)
    }
    func waitForAttempt() -> Bool { attempted.wait(timeout: .now() + 1) == .success }
}

private final class Fixture {
    private(set) var gate: ExternalTelemetryPrivacyGate!
    private let suite: String
    private var defaults: UserDefaults?
    private let directory: URL
    private let preferencesURL: URL
    private let keyBox: QueueKeyBox
    private let maxQueueItems: Int

    init(enable: Bool = true, maxQueueItems: Int = 8) throws {
        let suite = "SentryDiagnosticsAdapterTests-\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        localDefaults.removePersistentDomain(forName: suite)
        let localDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let localKeyBox = QueueKeyBox()
        self.suite = suite
        defaults = localDefaults
        directory = localDirectory
        preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
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

    func cleanup() {
        guard let defaults else { return }
        _ = gate.disableAndPurge()
        gate = nil
        defaults.removePersistentDomain(forName: suite)
        self.defaults = nil
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: preferencesURL)
    }

    func restartedGate() throws -> ExternalTelemetryPrivacyGate {
        let keyBox = self.keyBox
        let defaults = try XCTUnwrap(defaults)
        return ExternalTelemetryPrivacyGate(
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
        let keyBox = self.keyBox
        let defaults = try XCTUnwrap(defaults)
        return ExternalTelemetryPrivacyGate(
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

    func persistInvalidConsent() throws {
        let malformed = try JSONEncoder().encode(ExternalTelemetryPrivacyGate.Consent(
            isEnabled: true,
            version: 99,
            grantedAt: Date()
        ))
        defaults?.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
    }
}

private final class QueueKeyBox: @unchecked Sendable { var data: Data? }
