import XCTest
import CryptoKit
@testable import InsightKitApp

final class ExternalTelemetryPrivacyGateTests: XCTestCase {
    private final class SuccessfulTransport: ProductAnalyticsTransport {
        let sent = XCTestExpectation(description: "sent")
        private(set) var envelopes: [Data] = []
        func send(envelopes: [Data], completion: @escaping (Bool) -> Void) {
            self.envelopes = envelopes
            sent.fulfill()
            completion(true)
        }
        func cancelAll() {}
    }

    private final class DelayedTransport: ProductAnalyticsTransport {
        let sent = XCTestExpectation(description: "sent")
        private(set) var sendCount = 0
        private(set) var cancelled = false
        private var completion: ((Bool) -> Void)?
        func send(envelopes: [Data], completion: @escaping (Bool) -> Void) {
            sendCount += 1; self.completion = completion
            if sendCount == 1 { sent.fulfill() }
        }
        func cancelAll() { cancelled = true }
        func complete(_ success: Bool) { completion?(success) }
    }

    func testProductAnalyticsAllowsOnlyOneBatchInFlightAndCancelsBeforeOptOutPurge() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let transport = DelayedTransport()
        let analytics = ProductAnalytics(gate: gate, transport: transport)
        XCTAssertEqual(analytics.emit("workflow_started", properties: ["workflow": "live"]), .accepted)
        XCTAssertEqual(analytics.emit("record_saved", properties: ["workflow": "live"]), .accepted)
        wait(for: [transport.sent], timeout: 2)

        XCTAssertEqual(transport.sendCount, 1)
        try analytics.setConsent(enabled: false)
        XCTAssertTrue(transport.cancelled)
        transport.complete(true)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testUnifiedConsentRevocationPurgesProductAndSentryQueues() throws {
        let productGate = makeGate(storageDirectory: root)
        let sentryRoot = root.appendingPathComponent("Sentry", isDirectory: true)
        let sentryGate = makeGate(storageDirectory: sentryRoot)
        try productGate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(productGate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(sentryGate.record(event: .init(name: "app_crashed", properties: [
            "error_category": "runtime", "phase": "running",
        ])).result, .accepted)
        XCTAssertEqual(try productGate.queuedEnvelopes().count, 1)
        XCTAssertEqual(try sentryGate.queuedEnvelopes().count, 1)
        let revoked = expectation(description: "all external telemetry transports notified")
        let observer = NotificationCenter.default.addObserver(
            forName: .externalTelemetryConsentWillRevoke,
            object: nil,
            queue: nil
        ) { _ in revoked.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try ProductAnalytics(gate: productGate).setConsent(enabled: false)

        wait(for: [revoked], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("external-telemetry-queue-v1.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sentryRoot.appendingPathComponent("external-telemetry-queue-v1.json").path
        ))
    }

    func testWorkflowCompletionRequiresEveryDeterministicMeetingAssetCriterion() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        analytics.beginWorkflow("live", provisionalPath: .local)
        analytics.workflowCompleted("live", evaluation: .evaluate(
            recordPath: nil, duration: 0, exportCompleted: true, hasBlockingError: false
        ))
        let objects = try queuedObjects(gate)
        XCTAssertEqual(objects.map { $0["event_name"] as? String }, ["workflow_started"])
    }

    func testLocalEvidenceLedgerStoresOnlyAggregateCounts() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let analytics = ProductAnalytics(gate: gate, ledger: ProductAnalyticsEvidenceLedger(url: ledgerURL))
        XCTAssertEqual(analytics.emit("workflow_started", properties: ["workflow": "live", "analysis_mode": "local"]), .accepted)
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ledgerURL.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        let data = try Data(contentsOf: ledgerURL)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("workflow_started|live|local"))
        XCTAssertFalse(text.contains("installation_id"))
        XCTAssertFalse(text.contains("app_session_id"))
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(first["window_start"])
        XCTAssertNotNil(first["window_end"])
        XCTAssertEqual(first["offline_pending"] as? Int, 1)

        let reloaded = ProductAnalyticsEvidenceLedger(url: ledgerURL)
        let envelope = try XCTUnwrap(gate.record(event: .init(name: "workflow_started", properties: ["workflow": "live", "analysis_mode": "local"])).debugEnvelope)
        reloaded.record(envelope)
        var reloadedCount = 0
        while Date() < deadline {
            if let latest = try? JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any],
               let counts = latest["event_counts"] as? [String: Int] {
                reloadedCount = counts["workflow_started|live|local"] ?? 0
                if reloadedCount == 2 { break }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(reloadedCount, 2)
    }

    func testConcurrentLedgerAdmissionCannotOverwriteOptOutState() throws {
        let gate = makeGate(maxQueueItems: 100)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let ledgerURL = root.appendingPathComponent("concurrent-ledger.json")
        let analytics = ProductAnalytics(gate: gate, ledger: ProductAnalyticsEvidenceLedger(url: ledgerURL))
        XCTAssertEqual(analytics.emit("workflow_started", properties: ["workflow": "live", "analysis_mode": "local"]), .accepted)
        let group = DispatchGroup()
        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                _ = analytics.emit("workflow_started", properties: ["workflow": "live", "analysis_mode": "local"])
                group.leave()
            }
        }
        try analytics.setConsent(enabled: false)
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        let deadline = Date().addingTimeInterval(2)
        var manifest: [String: Any] = [:]
        while Date() < deadline {
            if let data = try? Data(contentsOf: ledgerURL),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               value["opted_out"] as? Bool == true {
                manifest = value
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(manifest["opted_out"] as? Bool, true)
        XCTAssertEqual(manifest["offline_pending"] as? Int, 0)
    }

    func testLedgerAcknowledgementPreservesNewerPendingAdmission() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let ledgerURL = root.appendingPathComponent("ack-ledger.json")
        let transport = DelayedTransport()
        let analytics = ProductAnalytics(
            gate: gate, transport: transport,
            ledger: ProductAnalyticsEvidenceLedger(url: ledgerURL)
        )
        XCTAssertEqual(analytics.emit("workflow_started", properties: ["workflow": "live"]), .accepted)
        wait(for: [transport.sent], timeout: 2)
        XCTAssertEqual(analytics.emit("record_saved", properties: ["workflow": "live"]), .accepted)
        transport.complete(true)

        let deadline = Date().addingTimeInterval(2)
        var pending = -1
        while Date() < deadline {
            if let data = try? Data(contentsOf: ledgerURL),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                pending = value["offline_pending"] as? Int ?? -1
                if pending == 1 { break }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(pending, 1)
    }

    func testLedgerRemainsPendingWhenUploadedQueueAcknowledgementCannotPersist() throws {
        let writes = LockedValue(0)
        let gate = makeGate(writeData: { data, url in
            let attempt = writes.withValue { value -> Int in value += 1; return value }
            if attempt >= 2 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try gate.setConsent(enabled: true, consentVersion: 1)
        let ledgerURL = root.appendingPathComponent("failed-ack-ledger.json")
        let transport = SuccessfulTransport()
        let analytics = ProductAnalytics(gate: gate, transport: transport, ledger: ProductAnalyticsEvidenceLedger(url: ledgerURL))
        XCTAssertEqual(analytics.emit("workflow_started", properties: ["workflow": "live"]), .accepted)
        wait(for: [transport.sent], timeout: 2)

        let deadline = Date().addingTimeInterval(2)
        var pending = -1
        while Date() < deadline {
            if let data = try? Data(contentsOf: ledgerURL),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                pending = value["offline_pending"] as? Int ?? -1
                if pending == 1 { break }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)
    }

    func testProductAnalyticsFlushesAcceptedEnvelopeAndAcknowledgesIt() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let transport = SuccessfulTransport()
        let analytics = ProductAnalytics(gate: gate, transport: transport)

        XCTAssertEqual(analytics.emit("workflow_started", properties: ["workflow": "live", "analysis_mode": "local"]), .accepted)
        wait(for: [transport.sent], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        while !(try gate.queuedEnvelopes()).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }

        XCTAssertEqual(transport.envelopes.count, 1)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testProductAnalyticsV1AcceptsExactCustomEventFamily() throws {
        let gate = makeGate(maxQueueItems: 11)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        let names = [
            "workflow_started", "record_saved", "record_reopened",
            "transcript_search_completed", "smart_minutes_review_opened",
            "export_completed", "workflow_completed", "workflow_failed",
            "recovery_attempted", "recovery_completed", "telemetry_consent_changed",
        ]

        for name in names {
            let properties: [String: Any] = name == "telemetry_consent_changed"
                ? ["telemetry_enabled": true]
                : ["workflow": "live", "analysis_mode": "cloud"]
            XCTAssertEqual(analytics.emit(name, properties: properties), .accepted, name)
        }
        XCTAssertEqual(try gate.queuedEnvelopes().count, names.count)
    }

    func testCentralGateAcceptsSentryEventsButProductAnalyticsRejectsThem() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)

        XCTAssertEqual(
            gate.record(event: .init(name: "app_crashed", properties: [
                "error_category": "runtime", "phase": "running",
            ])).result,
            .accepted
        )
        XCTAssertEqual(
            analytics.emit("app_crashed", properties: [
                "error_category": "runtime", "phase": "running",
            ]),
            .rejected
        )
        for name in ["$pageview", "$autocapture"] {
            XCTAssertEqual(gate.record(event: .init(name: name, properties: [:])).result, .rejected, name)
        }
    }

    func testResolvedAttemptUsesActualPathAndEmitsOneCompletionAcrossRepeatedExports() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        var clock = Date(timeIntervalSince1970: 1_000)
        let analytics = ProductAnalytics(gate: gate, now: { clock })
        analytics.beginWorkflow(
            "live",
            provisionalPath: ProductAnalyticsPath(analysisMode: "cloud", providerClass: "byok")
        )
        analytics.resolveWorkflow("live", path: .local, analysisLatencyMilliseconds: 2_500)
        analytics.recordSaved("live")
        analytics.reviewOpened("live")
        clock = clock.addingTimeInterval(3)
        analytics.exportCompleted("live")
        analytics.workflowCompleted("live", evaluation: MeetingAssetWorkflowSuccess(
            recordReopenable: true,
            transcriptSearchable: true,
            smartMinutesValid: true,
            exportCompleted: true,
            hasBlockingError: false
        ))
        analytics.exportCompleted("live")
        analytics.workflowCompleted("live", evaluation: MeetingAssetWorkflowSuccess(
            recordReopenable: true,
            transcriptSearchable: true,
            smartMinutesValid: true,
            exportCompleted: true,
            hasBlockingError: false
        ))

        let objects = try gate.queuedEnvelopes().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let workflowEvents = objects.filter { ($0["event_name"] as? String) != "telemetry_consent_changed" }
        let started = try XCTUnwrap(workflowEvents.first { $0["event_name"] as? String == "workflow_started" })
        XCTAssertEqual((started["properties"] as? [String: Any])?["analysis_mode"] as? String, "cloud")
        XCTAssertTrue(workflowEvents.filter { $0["event_name"] as? String != "workflow_started" }.allSatisfy {
            let properties = $0["properties"] as? [String: Any]
            return properties?["analysis_mode"] as? String == "local"
                && properties?["provider_class"] as? String == "local"
        })
        let completions = objects.filter { $0["event_name"] as? String == "workflow_completed" }
        XCTAssertEqual(completions.count, 1)
        let terminal = try XCTUnwrap(completions.first?["properties"] as? [String: Any])
        XCTAssertEqual(terminal["latency_bucket_ms"] as? Int, 5_000)
        XCTAssertNotNil(terminal["duration_bucket_ms"])
    }

    func testRecordObservationUsesExplicitPersistedPathAfterFailedAttempt() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        analytics.beginWorkflow(
            "import",
            provisionalPath: ProductAnalyticsPath(analysisMode: "cloud", providerClass: "byok")
        )
        analytics.workflowFailed("import", phase: "analysis", errorCode: "provider-unavailable", recoveryAction: "none")
        let record = ProductAnalyticsContext(workflow: "import", path: .local)
        analytics.observeRecord(record)
        analytics.exportCompleted("import", explicitPath: record.path)

        let recordEvents = try queuedObjects(gate).filter {
            ["record_reopened", "smart_minutes_review_opened", "export_completed"]
                .contains($0["event_name"] as? String ?? "")
        }
        XCTAssertEqual(recordEvents.count, 3)
        XCTAssertTrue(recordEvents.allSatisfy {
            let properties = $0["properties"] as? [String: Any]
            return properties?["analysis_mode"] as? String == "local"
                && properties?["provider_class"] as? String == "local"
        })
    }

    func testRepeatedRecordObservationKeepsOneSequenceAndAllowsTranscriptSearch() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        let context = ProductAnalyticsContext(workflow: "import", path: .local, key: "stable-record")

        analytics.observeRecord(context)
        analytics.observeRecord(context)
        analytics.transcriptSearchCompleted(context, resultCount: 3)

        let names = try queuedObjects(gate).compactMap { $0["event_name"] as? String }
        XCTAssertEqual(names, ["record_reopened", "smart_minutes_review_opened", "transcript_search_completed"])
    }

    func testSearchContextReusesStartedAttemptWithoutEmittingFakeRecordReopen() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        let attempt = ProductAnalyticsAttemptContext(workflow: "import")
        analytics.beginWorkflow(attempt, provisionalPath: .local)
        let context = ProductAnalyticsContext(attempt: attempt, path: .local)

        analytics.registerSearchContext(context)
        analytics.transcriptSearchCompleted(context, resultCount: 3)

        let events = try queuedObjects(gate)
        XCTAssertEqual(events.compactMap { $0["event_name"] as? String }, [
            "workflow_started", "transcript_search_completed",
        ])
        XCTAssertTrue(events.allSatisfy {
            ($0["properties"] as? [String: Any])?["attempt_sequence"] as? Int == 1
        })
    }

    func testRequiredTransportBlocksConsentInsteadOfQueueingEventsLocallyForever() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        let analytics = ProductAnalytics(gate: gate, requiresTransportForConsent: true)

        XCTAssertFalse(analytics.isAvailable)
        XCTAssertFalse(analytics.isEnabled)
        XCTAssertThrowsError(try analytics.setConsent(enabled: true))
        XCTAssertFalse(analytics.isEnabled)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testPostHogRuntimeConfigurationUsesBundleDefaultsAndEnvironmentOverrides() throws {
        let bundled = try XCTUnwrap(ProductAnalytics.configuredPostHogValues(
            process: [:],
            bundleInfo: [
                "InsightKitPostHogHost": "https://bundled.example",
                "InsightKitPostHogProjectKey": "phc_bundled",
            ],
            environment: .release
        ))
        XCTAssertEqual(bundled.host, "https://bundled.example")
        XCTAssertEqual(bundled.projectKey, "phc_bundled")

        let overridden = try XCTUnwrap(ProductAnalytics.configuredPostHogValues(
            process: [
                "POSTHOG_RELEASE_HOST": "https://override.example",
                "POSTHOG_RELEASE_PROJECT_KEY": "phc_override",
            ],
            bundleInfo: [
                "InsightKitPostHogHost": "https://bundled.example",
                "InsightKitPostHogProjectKey": "phc_bundled",
            ],
            environment: .release
        ))
        XCTAssertEqual(overridden.host, "https://override.example")
        XCTAssertEqual(overridden.projectKey, "phc_override")
    }

    func testImportSubmissionFailureStillClosesStartedAttempt() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        let rpc = RPCClientMock()
        rpc.transcriptionImportError = NSError(domain: "test", code: 1)
        let viewModel = ImportSessionViewModel(
            rpcClient: rpc,
            analyticsSubmit: { operation in operation(analytics) }
        )

        viewModel.importFile(url: root.appendingPathComponent("fixture.wav"))
        let completed = expectation(description: "import failure published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { completed.fulfill() }
        wait(for: [completed], timeout: 1)

        let names = try queuedObjects(gate).compactMap { $0["event_name"] as? String }
        XCTAssertEqual(names, ["workflow_started", "workflow_failed"])
    }

    func testQueuedImportSubmissionFailureStillClosesStartedAttempt() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        let rpc = RPCClientMock()
        rpc.transcriptionImportError = NSError(domain: "test", code: 1)
        let viewModel = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false,
            analyticsSubmit: { operation in operation(analytics) }
        )

        viewModel.importFile(path: "/tmp/fixture.wav")
        let completed = expectation(description: "queued import failure published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { completed.fulfill() }
        wait(for: [completed], timeout: 1)

        let names = try queuedObjects(gate).compactMap { $0["event_name"] as? String }
        XCTAssertEqual(names, ["workflow_started", "workflow_failed"])
    }

    func testLiveStartupFailureStillClosesStartedAttempt() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        let socketPath = "/tmp/insightkit-missing-sidecar-\(UUID().uuidString).sock"
        let viewModel = LiveSessionViewModel(
            rpcClient: RPCClientMock(),
            sidecarManager: SidecarManager(
                pythonBinary: "/definitely/missing-python",
                socketPath: socketPath,
                startupTimeoutSec: 3
            ),
            micCapture: MicCaptureService(),
            systemAudioCapture: SystemAudioCaptureService(),
            mixBus: AudioMixBus(),
            chunkAssembler: ChunkAssembler(),
            asrService: LiveASRService(),
            analyticsSubmit: { operation in operation(analytics) }
        )

        viewModel.startLiveSession()
        let completed = expectation(description: "live startup failure published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { completed.fulfill() }
        wait(for: [completed], timeout: 5)

        let names = try queuedObjects(gate).compactMap { $0["event_name"] as? String }
        XCTAssertEqual(names, ["workflow_started", "workflow_failed"])
        viewModel.shutdown()
    }

    func testTelemetryDisclosureDoesNotPromiseUnenforcedRemoteRetentionOrSentryDelivery() {
        XCTAssertFalse(SettingsView.externalTelemetryDisclosure.contains("Sentry"))
        XCTAssertFalse(SettingsView.externalTelemetryDisclosure.contains("匿名"))
        XCTAssertFalse(SettingsView.externalTelemetryDisclosure.contains("远端原始数据最多保留 30 天"))
        XCTAssertTrue(SettingsView.externalTelemetryDisclosure.contains("本地加密待发队列最多保留 30 天"))
        XCTAssertTrue(SettingsView.externalTelemetryDisclosure.contains("跨会话稳定的随机安装标识"))
    }

    func testFailedExportRecoveryEmitsClosedFailedPair() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        analytics.beginWorkflow("live", provisionalPath: .local)
        analytics.workflowFailed("live", phase: "exporting", errorCode: "storage", recoveryAction: "retry")
        analytics.exportAttempted("live")
        analytics.workflowFailed("live", phase: "exporting", errorCode: "storage", recoveryAction: "retry")

        let events = try queuedObjects(gate)
        let names = events.compactMap { $0["event_name"] as? String }
        XCTAssertEqual(names.filter { $0 == "recovery_attempted" }.count, 1)
        let completed = try XCTUnwrap(events.first { $0["event_name"] as? String == "recovery_completed" })
        XCTAssertEqual((completed["properties"] as? [String: Any])?["outcome"] as? String, "failed")
    }

    func testAnalysisFailureUsesMeasuredProviderLatencyBucket() throws {
        let gate = makeGate(maxQueueItems: 10)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        analytics.beginWorkflow(
            "import",
            provisionalPath: ProductAnalyticsPath(analysisMode: "cloud", providerClass: "byok")
        )
        analytics.workflowFailed(
            "import",
            phase: "analysis",
            errorCode: "unknown",
            recoveryAction: "retry",
            analysisLatencyMilliseconds: 2_500
        )

        let failure = try XCTUnwrap(queuedObjects(gate).first { $0["event_name"] as? String == "workflow_failed" })
        XCTAssertEqual((failure["properties"] as? [String: Any])?["latency_bucket_ms"] as? Int, 5_000)
    }

    func testSameWorkflowCanTrackIndependentJobAttemptsWithoutUploadingJobKeys() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        let first = ProductAnalyticsAttemptContext(workflow: "import")
        let second = ProductAnalyticsAttemptContext(workflow: "import")

        analytics.beginWorkflow(first, provisionalPath: ProductAnalyticsPath(analysisMode: "cloud", providerClass: "byok"))
        analytics.beginWorkflow(second, provisionalPath: .local)
        analytics.workflowFailed(first, phase: "analysis", errorCode: "provider-unavailable", recoveryAction: "none")
        analytics.recordSaved(second)
        analytics.reviewOpened(second)
        analytics.exportCompleted(second)
        analytics.workflowCompleted(second, evaluation: MeetingAssetWorkflowSuccess(
            recordReopenable: true,
            transcriptSearchable: true,
            smartMinutesValid: true,
            exportCompleted: true,
            hasBlockingError: false
        ))

        let objects = try queuedObjects(gate)
        let starts = objects.filter { $0["event_name"] as? String == "workflow_started" }
        XCTAssertEqual(starts.compactMap { ($0["properties"] as? [String: Any])?["attempt_sequence"] as? Int }, [1, 2])
        let failure = try XCTUnwrap(objects.first { $0["event_name"] as? String == "workflow_failed" })
        XCTAssertEqual((failure["properties"] as? [String: Any])?["analysis_mode"] as? String, "cloud")
        XCTAssertEqual((failure["properties"] as? [String: Any])?["attempt_sequence"] as? Int, 1)
        let completion = try XCTUnwrap(objects.first { $0["event_name"] as? String == "workflow_completed" })
        XCTAssertEqual((completion["properties"] as? [String: Any])?["analysis_mode"] as? String, "local")
        XCTAssertEqual((completion["properties"] as? [String: Any])?["attempt_sequence"] as? Int, 2)
        let serialized = String(data: try JSONSerialization.data(withJSONObject: objects), encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("job_id"))
        XCTAssertFalse(serialized.contains("meeting_id"))
        XCTAssertFalse(serialized.contains("attempt_id"))
    }

    func testAttemptSequenceRemainsMonotonicAcrossConsentEpochsInOneAppSession() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        analytics.beginWorkflow(ProductAnalyticsAttemptContext(workflow: "import"), provisionalPath: .local)
        try analytics.setConsent(enabled: false)
        try analytics.setConsent(enabled: true)
        analytics.beginWorkflow(ProductAnalyticsAttemptContext(workflow: "import"), provisionalPath: .local)

        let start = try XCTUnwrap(queuedObjects(gate).first { $0["event_name"] as? String == "workflow_started" })
        XCTAssertEqual((start["properties"] as? [String: Any])?["attempt_sequence"] as? Int, 2)
    }

    func testReopenedRecordRecoveryUsesOneNonPrivateAttemptOrdinal() throws {
        let gate = makeGate(maxQueueItems: 20)
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        let context = ProductAnalyticsContext(workflow: "import", path: .local)
        analytics.observeRecord(context)
        analytics.workflowFailed(context, phase: "reviewing", errorCode: "storage", recoveryAction: "retry")
        analytics.recoveryAttempted(context, phase: "reviewing")
        analytics.recoveryCompleted(context, phase: "reviewing", succeeded: true)

        let events = try queuedObjects(gate)
        XCTAssertEqual(events.count, 5)
        XCTAssertTrue(events.allSatisfy {
            ($0["properties"] as? [String: Any])?["attempt_sequence"] as? Int == 1
        })
    }

    func testConsentEpochClearsUnacceptedAndPriorWorkflowState() throws {
        let gate = makeGate(maxQueueItems: 20)
        let analytics = ProductAnalytics(gate: gate)
        analytics.beginWorkflow("live", provisionalPath: .local)
        try analytics.setConsent(enabled: true)
        analytics.workflowFailed("live", phase: "running", errorCode: "unknown", recoveryAction: "none")
        analytics.beginWorkflow("live", provisionalPath: .local)
        try analytics.setConsent(enabled: false)
        try analytics.setConsent(enabled: true)
        analytics.workflowFailed("live", phase: "running", errorCode: "unknown", recoveryAction: "none")

        let names = try queuedObjects(gate).compactMap { $0["event_name"] as? String }
        XCTAssertEqual(names, ["telemetry_consent_changed"])
    }

    func testProductAnalyticsV1AcceptsApprovedLowCardinalityDimensions() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)

        let outcome = analytics.emit("workflow_failed", properties: [
            "workflow": "import", "analysis_mode": "local", "provider_class": "none",
            "phase": "analysis", "outcome": "failed", "error_code": "provider-unavailable",
            "recovery_action": "retry", "duration_bucket_ms": 5_000,
            "latency_bucket_ms": 1_000, "retry_count": 1, "result_count": 3,
            "module_count": 2,
        ])

        XCTAssertEqual(outcome, .accepted)
    }

    func testProductAnalyticsV1RejectsLegacyUnapprovedProperties() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let analytics = ProductAnalytics(gate: gate)
        for property in ["error_category", "recovered"] {
            XCTAssertEqual(analytics.emit("workflow_failed", properties: [property: true]), .rejected)
        }
    }

    func testSuccessfulUploadAcknowledgesOnlyUploadedQueuePrefix() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        let uploaded = try gate.queuedEnvelopes()
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)

        XCTAssertTrue(try gate.acknowledgeUploadedEnvelopes(uploaded))

        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)
    }

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var root: URL!
    private var queueKey: LockedValue<Data?>!

    override func setUpWithError() throws {
        suiteName = "ExternalTelemetryPrivacyGateTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        queueKey = LockedValue(nil)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testExternalTelemetryIsPersistedOptInAndDefaultsOff() throws {
        let gate = makeGate()

        XCTAssertFalse(gate.consent.isEnabled)
        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])

        try gate.setConsent(enabled: true, consentVersion: 1)
        let reloaded = makeGate()
        XCTAssertTrue(reloaded.consent.isEnabled)
        XCTAssertEqual(reloaded.consent.version, 1)
        XCTAssertNotNil(reloaded.consent.grantedAt)
    }

    func testAllowedEventProducesExactVersionedDebugEnvelopeWithoutNetworkTransport() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let gate = makeGate(now: { now }, uuid: uuidSequence([
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
        ]))
        try gate.setConsent(enabled: true, consentVersion: 1)

        let outcome = gate.record(event: validEvent())

        XCTAssertEqual(outcome.result, .accepted)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(outcome.debugEnvelope)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "schema_version", "event_name", "timestamp_utc", "app_version", "app_build",
            "environment", "consent_version", "installation_id", "app_session_id", "event_sequence", "properties",
        ])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["event_name"] as? String, "workflow_completed")
        XCTAssertEqual(object["environment"] as? String, "development")
        XCTAssertEqual(object["installation_id"] as? String, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(object["app_session_id"] as? String, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(object["event_sequence"] as? Int, 1)
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(properties["workflow"] as? String, "import")
        XCTAssertEqual(properties["analysis_mode"] as? String, "local")
        XCTAssertEqual(properties["phase"] as? String, "finalizing")
        XCTAssertEqual(properties["outcome"] as? String, "succeeded")
        XCTAssertEqual(properties["duration_bucket_ms"] as? Int, 5_000)
        XCTAssertEqual(properties["result_count"] as? Int, 3)
        XCTAssertFalse(String(data: try XCTUnwrap(outcome.debugEnvelope), encoding: .utf8)!.contains(root.path))
    }

    func testBoundaryRejectsEveryProhibitedPropertyClassAndSecretShapedValue() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let prohibited: [(String, Any)] = [
            ("transcript", "spoken words"), ("notes", "private"), ("prompt", "instructions"),
            ("completion", "answer"), ("media", "audio bytes"), ("filename", "meeting.m4a"),
            ("path", "/Users/alice/meeting.m4a"), ("meeting_id", "meeting-123"),
            ("record_id", "record-123"), ("content_hash", "abcdef"), ("participant", "Alice"),
            ("speaker_name", "Bob"), ("email", "alice@example.com"),
            ("provider_payload", ["raw": "body"]), ("message", "raw exception"),
            ("log", "console output"), ("workflow", "sk-abcdefghijklmnop"),
            ("phase", "hf_abcdefghijklmnop"), ("outcome", "alice@example.com"),
            ("recovery_action", "/Users/alice/private"),
        ]

        for (key, value) in prohibited {
            let outcome = gate.record(event: .init(name: "workflow_failed", properties: [key: value]))
            XCTAssertEqual(outcome.result, .rejected, "Expected rejection for \(key)")
        }
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertEqual(gate.localDiagnostics.rejected, prohibited.count)
    }

    func testUnknownEventPropertyAndEnumValueFailClosed() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)

        XCTAssertEqual(gate.record(event: .init(name: "made_up", properties: [:])).result, .rejected)
        XCTAssertEqual(gate.record(event: .init(name: "review_opened", properties: ["mystery": true])).result, .rejected)
        XCTAssertEqual(gate.record(event: .init(name: "review_opened", properties: ["workflow": "other"])).result, .rejected)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testDisablePurgesQueueAndWritesDeterministicReadbackEvidence() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)

        let evidence = gate.disableAndPurge()

        XCTAssertEqual(evidence.purgedItems, 1)
        XCTAssertEqual(evidence.remainingItems, 0)
        XCTAssertFalse(evidence.externalTelemetryEnabled)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        let saved = try JSONDecoder().decode(
            ExternalTelemetryPrivacyGate.DisableEvidence.self,
            from: Data(contentsOf: gate.disableEvidenceURL)
        )
        XCTAssertEqual(saved, evidence)
        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
    }

    func testQueueIsBoundedDropsWhenFullAndExpiresItemsAtRetentionLimit() throws {
        var now = Date(timeIntervalSince1970: 1_788_000_000)
        let gate = makeGate(now: { now }, maxQueueItems: 2, retentionDays: 1)
        try gate.setConsent(enabled: true, consentVersion: 1)

        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(gate.record(event: validEvent()).result, .queueFull)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 2)

        now.addTimeInterval(86_401)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertEqual(gate.localDiagnostics.queueFull, 1)
        XCTAssertEqual(gate.localDiagnostics.expired, 2)
    }

    func testSerializationFailureIsDroppedWithoutThrowingOrQueueing() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)

        let outcome = gate.record(event: .init(
            name: "workflow_completed",
            properties: ["quality_score": Double.nan]
        ))

        XCTAssertEqual(outcome.result, .serializationFailed)
        XCTAssertNil(outcome.debugEnvelope)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertEqual(gate.localDiagnostics.serializationFailed, 1)
    }

    func testRetentionDeleteFailureIsLocalNonThrowingAndLeavesNoReadableEnvelope() throws {
        var now = Date(timeIntervalSince1970: 1_788_000_000)
        let gate = makeGate(
            now: { now },
            retentionDays: 1,
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        now.addTimeInterval(86_401)

        let outcome = gate.record(event: validEvent())

        XCTAssertEqual(outcome.result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertEqual(gate.localDiagnostics.queueDeleteFailed, 1)
        XCTAssertEqual(gate.localDiagnostics.serializationFailed, 1)
    }

    func testEnvironmentConfigurationIsExplicitAndRetentionNeverExceedsThirtyDays() throws {
        XCTAssertEqual(Set(TelemetryEnvironment.allCases.map(\.rawValue)), ["development", "owner-pilot", "release"])
        for environment in TelemetryEnvironment.allCases {
            let config = try ExternalTelemetryConfiguration(environment: environment, retentionDays: 30, maxQueueItems: 1)
            XCTAssertEqual(config.environment, environment)
            XCTAssertEqual(config.retentionDays, 30)
        }
        XCTAssertThrowsError(try ExternalTelemetryConfiguration(environment: .release, retentionDays: 31, maxQueueItems: 1))
        XCTAssertThrowsError(try ExternalTelemetryConfiguration(environment: .development, retentionDays: 0, maxQueueItems: 1))
        XCTAssertThrowsError(try ExternalTelemetryConfiguration(environment: .development, retentionDays: 1, maxQueueItems: 0))
        XCTAssertThrowsError(try ExternalTelemetryConfiguration(environment: .development, retentionDays: 1, maxQueueItems: 1_001))
    }

    func testInvalidPersistedInstallationIdentifierIsRotatedBeforeItCanEnterEnvelope() throws {
        defaults.set("record-derived-secret", forKey: "insightkit.external-telemetry.installation-id.v1")
        let gate = makeGate(uuid: uuidSequence([
            "33333333-3333-4333-8333-333333333333",
            "44444444-4444-4444-8444-444444444444",
        ]))
        try gate.setConsent(enabled: true, consentVersion: 1)

        let outcome = gate.record(event: validEvent())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(outcome.debugEnvelope)) as? [String: Any])

        XCTAssertEqual(object["installation_id"] as? String, "33333333-3333-4333-8333-333333333333")
        XCTAssertNotEqual(object["installation_id"] as? String, "record-derived-secret")
    }

    func testMalformedPersistedConsentFailsClosed() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 0, grantedAt: nil)),
            forKey: "insightkit.external-telemetry.consent.v1"
        )

        let gate = makeGate()

        XCTAssertFalse(gate.consent.isEnabled)
        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
    }

    func testPersistedConsentRejectsUnknownVersionAndFutureGrant() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for consent in [
            ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 2, grantedAt: now),
            ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 1, grantedAt: now.addingTimeInterval(1)),
        ] {
            defaults.set(try encoder.encode(consent), forKey: "insightkit.external-telemetry.consent.v1")
            let gate = makeGate(now: { now })
            XCTAssertFalse(gate.consent.isEnabled)
            XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        }
    }

    func testRecordCryptographicallyInvalidatesMalformedDisabledConsent() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
                isEnabled: false,
                version: 99,
                grantedAt: Date().addingTimeInterval(3_600)
            )),
            forKey: "insightkit.external-telemetry.consent.v1"
        )

        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        let deadline = Date().addingTimeInterval(2)
        while queueKey.get() != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertNil(queueKey.get())
    }

    func testPurgeFailureMakesQueuedItemsUnreadableAndWritesPrivacySafeEvidence() throws {
        let gate = makeGate(removeItem: { _ in throw CocoaError(.fileWriteNoPermission) })
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)

        let evidence = gate.disableAndPurge()

        XCTAssertFalse(evidence.queueFileDeleted)
        XCTAssertEqual(evidence.failureCode, "queue-delete-failed")
        XCTAssertEqual(evidence.remainingItems, 0)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        let persisted = try JSONDecoder().decode(
            ExternalTelemetryPrivacyGate.DisableEvidence.self,
            from: Data(contentsOf: gate.disableEvidenceURL)
        )
        XCTAssertEqual(persisted, evidence)
        XCTAssertFalse(String(data: try Data(contentsOf: gate.disableEvidenceURL), encoding: .utf8)!.contains("permission"))
        XCTAssertFalse(gate.consent.isEnabled)
        XCTAssertNil(queueKey.get())
        let queueData = try Data(contentsOf: root.appendingPathComponent("external-telemetry-queue-v1.json"))
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: queueData), using: SymmetricKey(data: Data(repeating: 0, count: 32))))
    }

    func testCompoundPurgeFailureReportsUnreadableStateAndEveryFailedErasureStep() throws {
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        let gate = makeGate(
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) },
            writeData: { data, url in
                if url == queueURL, FileManager.default.fileExists(atPath: url.path) {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: url, options: .atomic)
            },
            saveQueueKey: { data in
                try self.queueKey.withValue {
                    if $0 == nil { $0 = data }
                    else { throw CocoaError(.fileWriteNoPermission) }
                }
            },
            deleteQueueKey: { throw CocoaError(.fileWriteNoPermission) }
        )
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)
        let originalKey = try XCTUnwrap(queueKey.get())
        let acceptedConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))

        let evidence = gate.disableAndPurge()

        XCTAssertEqual(evidence.purgedItems, 0, "items that remain readable with the original key were not purged")
        XCTAssertEqual(evidence.remainingItems, 1)
        XCTAssertFalse(evidence.queueKeyErased)
        XCTAssertEqual(evidence.failureCodes, [
            "queue-tombstone-write-failed", "queue-key-delete-failed",
            "queue-key-replacement-failed", "queue-delete-failed",
        ])
        XCTAssertEqual(queueKey.get(), originalKey)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertNoThrow(try AES.GCM.open(
            AES.GCM.SealedBox(combined: Data(contentsOf: queueURL)),
            using: SymmetricKey(data: originalKey)
        ))
        XCTAssertNotNil(defaults.object(forKey: "insightkit.external-telemetry.revoked.v1"))

        defaults.set(acceptedConsent, forKey: "insightkit.external-telemetry.consent.v1")
        let restartedGate = makeGate(
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) },
            deleteQueueKey: { throw CocoaError(.fileWriteNoPermission) }
        )
        XCTAssertFalse(restartedGate.consent.isEnabled)
        XCTAssertEqual(restartedGate.record(event: validEvent()).result, .disabled)
    }

    func testDisablePersistsEvidenceFallbackWhenJSONEvidenceWriteFails() throws {
        let gate = makeGate(writeData: { data, url in
            if url.lastPathComponent.contains("disable-evidence") { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)

        let evidence = gate.disableAndPurge()

        XCTAssertFalse(evidence.evidenceFilePersisted)
        XCTAssertNotNil(defaults.data(forKey: "insightkit.external-telemetry.disable-evidence-fallback.v1"))
    }

    func testTamperedPersistedQueueCannotBypassAllowlistReadback() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        let key = SymmetricKey(data: try XCTUnwrap(queueKey.get()))
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: queueURL)), using: key)
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: clear) as? [[String: Any]])
        var properties = try XCTUnwrap(objects[0]["properties"] as? [String: Any])
        properties["transcript"] = "private words"
        objects[0]["properties"] = properties
        let tampered = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        let sealed = try XCTUnwrap(AES.GCM.seal(tampered, using: key).combined)
        try sealed.write(to: queueURL, options: .atomic)

        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertEqual(gate.localDiagnostics.rejected, 1)
    }

    func testPersistedQueueRejectsSubstitutedIdentifiersAndFutureTimestamp() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let gate = makeGate(now: { now })
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)

        try mutateQueuedEnvelope { object in
            object["installation_id"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        }
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertEqual(gate.localDiagnostics.rejected, 1)

        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)
        try mutateQueuedEnvelope { object in
            object["timestamp_utc"] = "2099-01-01T00:00:00Z"
        }
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertEqual(gate.localDiagnostics.rejected, 2)
    }

    func testDisableIgnoresInvalidConsentVersion() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)

        XCTAssertNoThrow(try gate.setConsent(enabled: false, consentVersion: 0))
        XCTAssertFalse(gate.consent.isEnabled)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testRecordReturnsWithoutWaitingForPersistenceAndDisablePreventsPostDisableWriteBack() throws {
        let writeStarted = expectation(description: "queue write started")
        let permitWrite = DispatchSemaphore(value: 0)
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        let firstGate = makeGate(writeData: { data, url in
            if url == queueURL {
                writeStarted.fulfill()
                permitWrite.wait()
            }
            try data.write(to: url, options: .atomic)
        })
        let secondGate = makeGate()
        try firstGate.setConsent(enabled: true, consentVersion: 1)
        let startedAt = Date()
        XCTAssertEqual(firstGate.record(event: validEvent()).result, .accepted)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.05)
        wait(for: [writeStarted], timeout: 2)

        let disabled = expectation(description: "disable finished")
        DispatchQueue.global().async {
            _ = secondGate.disableAndPurge()
            disabled.fulfill()
        }
        permitWrite.signal()
        wait(for: [disabled], timeout: 2)

        XCTAssertEqual(firstGate.record(event: validEvent()).result, .disabled)
        XCTAssertEqual(try secondGate.queuedEnvelopes(), [])
    }

    func testOfflineQueueSurvivesSecondEnabledGateAndRestartWithNewSessionIdentifier() throws {
        let first = makeGate(uuid: uuidSequence([
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
        ]))
        try first.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(first.record(event: validEvent()).result, .accepted)

        let second = makeGate(uuid: uuidSequence([
            "33333333-3333-4333-8333-333333333333",
        ]))
        let queued = try second.queuedEnvelopes()
        XCTAssertEqual(queued.count, 1)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: queued[0]) as? [String: Any])
        XCTAssertEqual(persisted["app_session_id"] as? String, "22222222-2222-4222-8222-222222222222")

        let newOutcome = second.record(event: validEvent())
        let newEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(newOutcome.debugEnvelope)) as? [String: Any])
        XCTAssertEqual(newEnvelope["app_session_id"] as? String, "33333333-3333-4333-8333-333333333333")
        XCTAssertNotEqual(newEnvelope["app_session_id"] as? String, persisted["app_session_id"] as? String)
        XCTAssertEqual(try second.queuedEnvelopes().count, 2)
    }

    func testQueueIsBoundToCurrentEnvironmentAndConsentContract() throws {
        let development = makeGate(environment: .development)
        try development.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(development.record(event: validEvent()).result, .accepted)

        let release = makeGate(environment: .release)
        XCTAssertEqual(try release.queuedEnvelopes(), [])

        XCTAssertEqual(release.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try release.queuedEnvelopes().count, 1)
        let acceptedConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 2, grantedAt: Date())),
            forKey: "insightkit.external-telemetry.consent.v1"
        )
        XCTAssertEqual(try release.queuedEnvelopes(), [])
        defaults.set(acceptedConsent, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try release.queuedEnvelopes(), [], "stale consent restoration must not replay the old queue")
    }

    func testDiagnosticsSnapshotsRemainDeterministicDuringConcurrentRecording() throws {
        let gate = makeGate(maxQueueItems: 10)
        try gate.setConsent(enabled: true, consentVersion: 1)

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            _ = gate.record(event: .init(name: "unknown", properties: [:]))
            _ = gate.localDiagnostics
        }
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            _ = gate.record(event: validEvent())
            _ = gate.localDiagnostics
        }

        XCTAssertEqual(try gate.queuedEnvelopes().count, 10)
        XCTAssertEqual(gate.localDiagnostics.rejected, 100)
        XCTAssertEqual(gate.localDiagnostics.queueFull, 90)
    }

    func testPendingPersistenceAdmissionIsBoundedAndTruthfulWhileWorkerIsBlocked() throws {
        let writeStarted = expectation(description: "persistence worker blocked")
        let permitWrite = DispatchSemaphore(value: 0)
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        var shouldBlockWrite = true
        let gate = makeGate(maxQueueItems: 2, writeData: { data, url in
            if url == queueURL, shouldBlockWrite {
                shouldBlockWrite = false
                writeStarted.fulfill()
                permitWrite.wait()
            }
            try data.write(to: url, options: .atomic)
        })
        try gate.setConsent(enabled: true, consentVersion: 1)

        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        wait(for: [writeStarted], timeout: 2)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(gate.record(event: validEvent()).result, .queueFull)

        permitWrite.signal()
        XCTAssertEqual(try gate.queuedEnvelopes().count, 2)
    }

    func testPreDisableRecordCannotJoinNewGenerationAfterDisableEnableABA() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_788_000_000)
        let guardPassed = expectation(description: "record passed initial consent guard")
        let permitAdmission = DispatchSemaphore(value: 0)
        let recordingGate = makeGate(now: { fixedNow }, onRecordGuardPassed: {
            guardPassed.fulfill()
            permitAdmission.wait()
        })
        try recordingGate.setConsent(enabled: true, consentVersion: 1)
        let outcome = LockedValue<ExternalTelemetryPrivacyGate.RecordResult?>(nil)
        let recordFinished = expectation(description: "record finished")
        DispatchQueue.global().async {
            outcome.set(recordingGate.record(event: self.validEvent()).result)
            recordFinished.fulfill()
        }
        wait(for: [guardPassed], timeout: 2)

        let disablingGate = makeGate(now: { fixedNow })
        _ = disablingGate.disableAndPurge()
        let reenablingGate = makeGate(now: { fixedNow })
        try reenablingGate.setConsent(enabled: true, consentVersion: 1)
        permitAdmission.signal()
        wait(for: [recordFinished], timeout: 2)

        XCTAssertEqual(outcome.get(), .disabled)
        XCTAssertEqual(try reenablingGate.queuedEnvelopes(), [])
    }

    func testRecordObservingInvalidConsentCryptographicallyPurgesWithoutReadbackCall() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)
        let acceptedConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date())),
            forKey: "insightkit.external-telemetry.consent.v1"
        )

        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        let deadline = Date().addingTimeInterval(2)
        while queueKey.get() != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertNil(queueKey.get(), "record must schedule durable key erasure when persisted consent is invalid")

        defaults.set(acceptedConsent, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testReadbackRechecksGenerationAfterDisableBeforeReturningBatch() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)

        let readStarted = expectation(description: "readback entered encrypted queue")
        let permitRead = DispatchSemaphore(value: 0)
        var shouldBlockRead = true
        let guarded = makeGate(readQueueKey: {
            if shouldBlockRead {
                shouldBlockRead = false
                readStarted.fulfill()
                permitRead.wait()
            }
            return self.queueKey.get()
        })
        let returned = LockedValue<[Data]>([])
        let readFinished = expectation(description: "readback finished")
        DispatchQueue.global().async {
            returned.set((try? guarded.queuedEnvelopes()) ?? [])
            readFinished.fulfill()
        }
        wait(for: [readStarted], timeout: 2)

        let disableFinished = expectation(description: "disable finished")
        DispatchQueue.global().async {
            _ = seed.disableAndPurge()
            disableFinished.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while guarded.consent.isEnabled, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertFalse(guarded.consent.isEnabled)
        permitRead.signal()
        wait(for: [readFinished, disableFinished], timeout: 2)

        XCTAssertEqual(returned.get(), [], "an opt-out must not yield a batch admitted by an earlier readback guard")
    }

    func testReadbackGuardCannotReturnStaleBatchAcrossDisableEnableABA() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)

        let readStarted = expectation(description: "readback guard entered queue")
        let permitRead = DispatchSemaphore(value: 0)
        var shouldBlockRead = true
        let reader = makeGate(readQueueKey: {
            if shouldBlockRead {
                shouldBlockRead = false
                readStarted.fulfill()
                permitRead.wait()
            }
            return self.queueKey.get()
        })
        let returned = LockedValue<[Data]>([])
        let readFinished = expectation(description: "readback finished")
        DispatchQueue.global().async {
            returned.set((try? reader.queuedEnvelopes()) ?? [])
            readFinished.fulfill()
        }
        wait(for: [readStarted], timeout: 2)

        let disableFinished = expectation(description: "disable finished")
        DispatchQueue.global().async {
            _ = seed.disableAndPurge()
            disableFinished.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while reader.consent.isEnabled, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertFalse(reader.consent.isEnabled)

        let enablingGate = makeGate()
        let enableFinished = expectation(description: "new consent enable finished")
        DispatchQueue.global().async {
            try? enablingGate.setConsent(enabled: true, consentVersion: 1)
            enableFinished.fulfill()
        }
        permitRead.signal()
        wait(for: [readFinished, disableFinished, enableFinished], timeout: 2)

        XCTAssertEqual(returned.get(), [], "generation ABA must not release the pre-disable outbound batch")
        XCTAssertTrue(enablingGate.consent.isEnabled)
    }

    func testConcurrentEarlierEnableCannotWriteTrueAfterDisableCompletes() throws {
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: queueURL)
        let removalStarted = expectation(description: "enable cleanup started")
        let permitRemoval = DispatchSemaphore(value: 0)
        var shouldBlockRemoval = true
        let enablingGate = makeGate(removeItem: { url in
            if shouldBlockRemoval {
                shouldBlockRemoval = false
                removalStarted.fulfill()
                permitRemoval.wait()
            }
            try FileManager.default.removeItem(at: url)
        })
        let enableFinished = expectation(description: "enable finished")
        let enableError = LockedValue<Bool>(false)
        DispatchQueue.global().async {
            do { try enablingGate.setConsent(enabled: true, consentVersion: 1) }
            catch { enableError.set(true) }
            enableFinished.fulfill()
        }
        wait(for: [removalStarted], timeout: 2)

        let disablingGate = makeGate()
        let disableFinished = expectation(description: "disable finished")
        DispatchQueue.global().async {
            _ = disablingGate.disableAndPurge()
            disableFinished.fulfill()
        }
        permitRemoval.signal()
        wait(for: [enableFinished, disableFinished], timeout: 2)

        XCTAssertTrue(enableError.get())
        XCTAssertFalse(enablingGate.consent.isEnabled)
        XCTAssertFalse(disablingGate.consent.isEnabled)
    }

    func testSupersededEnableCannotOverwriteNewerEnableAfterDisableABA() throws {
        let oldEnablePaused = expectation(description: "old enable paused after cleanup")
        let resumeOldEnable = DispatchSemaphore(value: 0)
        let oldEnable = makeGate(onEnableCleanupCompleted: {
            oldEnablePaused.fulfill()
            resumeOldEnable.wait()
        })
        let oldEnableFinished = expectation(description: "old enable finished")
        let oldEnableWasSuperseded = LockedValue(false)
        DispatchQueue.global().async {
            do { try oldEnable.setConsent(enabled: true, consentVersion: 1) }
            catch ExternalTelemetryPrivacyGate.ConsentError.transitionSuperseded {
                oldEnableWasSuperseded.set(true)
            } catch {}
            oldEnableFinished.fulfill()
        }
        wait(for: [oldEnablePaused], timeout: 2)

        let transitionGate = makeGate()
        _ = transitionGate.disableAndPurge()
        try transitionGate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertTrue(transitionGate.consent.isEnabled)

        resumeOldEnable.signal()
        wait(for: [oldEnableFinished], timeout: 2)

        XCTAssertTrue(oldEnableWasSuperseded.get())
        XCTAssertTrue(transitionGate.consent.isEnabled)
        XCTAssertTrue(oldEnable.consent.isEnabled)
    }

    func testDisabledReadbackDoesNotRepeatPurgeOrOverwriteFirstDisableEvidence() throws {
        let deleteKeyCalls = LockedValue(0)
        let gate = makeGate(
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) },
            deleteQueueKey: { deleteKeyCalls.withValue { $0 += 1 } }
        )
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)

        let evidence = gate.disableAndPurge()
        let persistedEvidence = try Data(contentsOf: gate.disableEvidenceURL)
        XCTAssertEqual(deleteKeyCalls.get(), 1)
        XCTAssertFalse(evidence.queueFileDeleted)
        XCTAssertTrue(evidence.queueKeyErased)
        XCTAssertEqual(evidence.failureCodes, ["queue-delete-failed"])

        XCTAssertEqual(try gate.queuedEnvelopes(), [])

        XCTAssertEqual(deleteKeyCalls.get(), 1, "ordinary disabled readback must not rotate the key again")
        XCTAssertEqual(try Data(contentsOf: gate.disableEvidenceURL), persistedEvidence)
    }

    func testConcurrentInstallationInitializationConvergesAcrossGateInstances() throws {
        let bothMissing = DispatchGroup()
        bothMissing.enter()
        bothMissing.enter()
        let releaseInitialization = DispatchSemaphore(value: 0)
        let reachedMissing = LockedValue(0)
        let onInstallationIDMissing = {
            reachedMissing.withValue { count in
                count += 1
                bothMissing.leave()
            }
            releaseInitialization.wait()
        }
        let first = LockedValue<ExternalTelemetryPrivacyGate?>(nil)
        let second = LockedValue<ExternalTelemetryPrivacyGate?>(nil)
        let initialized = expectation(description: "both gates initialized")
        initialized.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            first.set(self.makeGate(
                uuid: self.uuidSequence([
                    "11111111-1111-4111-8111-111111111111",
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                ]),
                onInstallationIDMissing: onInstallationIDMissing
            ))
            initialized.fulfill()
        }
        DispatchQueue.global().async {
            second.set(self.makeGate(
                uuid: self.uuidSequence([
                    "22222222-2222-4222-8222-222222222222",
                    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                ]),
                onInstallationIDMissing: onInstallationIDMissing
            ))
            initialized.fulfill()
        }
        XCTAssertEqual(bothMissing.wait(timeout: .now() + 2), .success)
        releaseInitialization.signal()
        releaseInitialization.signal()
        wait(for: [initialized], timeout: 2)

        let firstGate = try XCTUnwrap(first.get())
        let secondGate = try XCTUnwrap(second.get())
        try firstGate.setConsent(enabled: true, consentVersion: 1)
        let firstOutcome = firstGate.record(event: validEvent())
        let secondOutcome = secondGate.record(event: validEvent())
        XCTAssertEqual(firstOutcome.result, .accepted)
        XCTAssertEqual(secondOutcome.result, .accepted)
        XCTAssertEqual(try firstGate.queuedEnvelopes().count, 2)
        XCTAssertEqual(try secondGate.queuedEnvelopes().count, 2)

        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(firstOutcome.debugEnvelope)) as? [String: Any])
        let secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(secondOutcome.debugEnvelope)) as? [String: Any])
        XCTAssertEqual(firstObject["installation_id"] as? String, secondObject["installation_id"] as? String)
        XCTAssertEqual(firstObject["installation_id"] as? String, defaults.string(forKey: "insightkit.external-telemetry.installation-id.v1"))
    }

    func testRecordInvalidConsentTransitionCannotOverwriteNewerEnable() throws {
        try assertInvalidConsentTransitionCannotOverwriteNewerEnable { gate in
            XCTAssertEqual(gate.record(event: self.validEvent()).result, .disabled)
        }
    }

    func testReadbackInvalidConsentTransitionCannotOverwriteNewerEnable() throws {
        try assertInvalidConsentTransitionCannotOverwriteNewerEnable { gate in
            XCTAssertEqual(try gate.queuedEnvelopes(), [])
        }
    }

    func testReadbackInvalidConsentGuardCannotInvalidateNewerEnable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
                isEnabled: true,
                version: 99,
                grantedAt: Date()
            )),
            forKey: "insightkit.external-telemetry.consent.v1"
        )
        let invalidGuardPassed = expectation(description: "readback observed invalid consent")
        let resumeInvalidationAdmission = DispatchSemaphore(value: 0)
        let reader = makeGate(onInvalidConsentGuardPassed: {
            invalidGuardPassed.fulfill()
            resumeInvalidationAdmission.wait()
        })
        let readFinished = expectation(description: "readback finished")
        DispatchQueue.global().async {
            XCTAssertEqual(try? reader.queuedEnvelopes(), [])
            readFinished.fulfill()
        }
        wait(for: [invalidGuardPassed], timeout: 2)

        let enablingGate = makeGate()
        try enablingGate.setConsent(enabled: true, consentVersion: 1)
        resumeInvalidationAdmission.signal()
        wait(for: [readFinished], timeout: 2)

        XCTAssertTrue(enablingGate.consent.isEnabled)
        XCTAssertTrue(reader.consent.isEnabled)
    }

    func testInvalidConsentBarrierPurgesAnAlreadyAuthorizedBlockedWriteBeforeRestore() throws {
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        let writeStarted = expectation(description: "authorized queue write started")
        let permitWrite = DispatchSemaphore(value: 0)
        var shouldBlockWrite = true
        let gate = makeGate(writeData: { data, url in
            if url == queueURL, shouldBlockWrite {
                shouldBlockWrite = false
                writeStarted.fulfill()
                permitWrite.wait()
            }
            try data.write(to: url, options: .atomic)
        })
        try gate.setConsent(enabled: true, consentVersion: 1)
        let acceptedConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        wait(for: [writeStarted], timeout: 2)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 2, grantedAt: Date())),
            forKey: "insightkit.external-telemetry.consent.v1"
        )
        let barrierFinished = expectation(description: "invalid consent barrier finished")
        DispatchQueue.global().async {
            XCTAssertEqual(try? gate.queuedEnvelopes(), [])
            barrierFinished.fulfill()
        }
        permitWrite.signal()
        wait(for: [barrierFinished], timeout: 2)

        defaults.set(acceptedConsent, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testRecordSecondConsentObservationInvalidatesAndPurgesBeforeStaleConsentRestore() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let malformed = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
            isEnabled: true,
            version: 99,
            grantedAt: Date()
        ))
        var mutateOnGuard = false
        let gate = makeGate(onRecordGuardPassed: {
            if mutateOnGuard {
                self.defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
            }
        })
        try gate.setConsent(enabled: true, consentVersion: 1)
        let acceptedConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)

        mutateOnGuard = true
        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        let deadline = Date().addingTimeInterval(2)
        while queueKey.get() != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertNil(queueKey.get(), "the second consent observation must cryptographically purge")

        defaults.set(acceptedConsent, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testReadbackFinalConsentObservationInvalidatesAndPurgesBeforeStaleConsentRestore() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        let acceptedConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let malformed = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
            isEnabled: true,
            version: 99,
            grantedAt: Date()
        ))
        var mutateOnKeyRead = true
        let reader = makeGate(readQueueKey: {
            if mutateOnKeyRead {
                mutateOnKeyRead = false
                self.defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
            }
            return self.queueKey.get()
        })

        XCTAssertEqual(try reader.queuedEnvelopes(), [])
        XCTAssertNil(queueKey.get(), "the final readback observation must cryptographically purge")

        defaults.set(acceptedConsent, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testRecordInvalidationPersistsRestartBarrierBeforeAsyncCryptographicPurge() throws {
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        let persistenceStarted = expectation(description: "persistence worker blocked")
        let releasePersistence = DispatchSemaphore(value: 0)
        let shouldBlockWrite = LockedValue(true)
        var mutateOnGuard = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let malformed = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
            isEnabled: true,
            version: 99,
            grantedAt: Date()
        ))
        let gate = makeGate(
            writeData: { data, url in
                let shouldBlock = shouldBlockWrite.withValue { value in
                    defer { value = false }
                    return value && url == queueURL
                }
                if shouldBlock {
                    persistenceStarted.fulfill()
                    releasePersistence.wait()
                }
                try data.write(to: url, options: .atomic)
            },
            onRecordGuardPassed: {
                if mutateOnGuard {
                    self.defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
                }
            }
        )
        try gate.setConsent(enabled: true, consentVersion: 1)
        let acceptedConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        wait(for: [persistenceStarted], timeout: 2)

        mutateOnGuard = true
        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        XCTAssertNotNil(defaults.object(forKey: "insightkit.external-telemetry.revoked.v1"))

        defaults.set(acceptedConsent, forKey: "insightkit.external-telemetry.consent.v1")
        let restartedGate = makeGate()
        XCTAssertFalse(restartedGate.consent.isEnabled)
        XCTAssertEqual(restartedGate.record(event: validEvent()).result, .disabled)

        releasePersistence.signal()
        XCTAssertEqual(try restartedGate.queuedEnvelopes(), [])
        XCTAssertNil(queueKey.get())
    }

    func testBlockingUUIDGenerationOnOneInstanceDoesNotDelayAnotherInstancesRecord() throws {
        let activeGate = makeGate()
        try activeGate.setConsent(enabled: true, consentVersion: 1)
        defaults.removeObject(forKey: "insightkit.external-telemetry.installation-id.v1")
        let uuidStarted = expectation(description: "UUID generation started")
        let releaseUUID = DispatchSemaphore(value: 0)
        let shouldBlockUUID = LockedValue(true)
        let initializationFinished = expectation(description: "blocked initialization finished")
        DispatchQueue.global().async {
            _ = self.makeGate(uuid: {
                let shouldBlock = shouldBlockUUID.withValue { value in
                    defer { value = false }
                    return value
                }
                if shouldBlock {
                    uuidStarted.fulfill()
                    releaseUUID.wait()
                }
                return UUID()
            })
            initializationFinished.fulfill()
        }
        wait(for: [uuidStarted], timeout: 2)

        let recordFinished = expectation(description: "unrelated record remained non-blocking")
        let result = LockedValue<ExternalTelemetryPrivacyGate.RecordResult?>(nil)
        DispatchQueue.global().async {
            result.set(activeGate.record(event: self.validEvent()).result)
            recordFinished.fulfill()
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [recordFinished], timeout: 0.2),
            .completed,
            "UUID generation must execute outside the process-wide state lock"
        )
        releaseUUID.signal()
        wait(for: [initializationFinished], timeout: 2)
        XCTAssertNotNil(result.get())
    }

    func testBlockingPersistenceOnOneInstanceDoesNotDelayAnotherInstancesRecord() throws {
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        let persistenceStarted = expectation(description: "persistence started")
        let releasePersistence = DispatchSemaphore(value: 0)
        let shouldBlockWrite = LockedValue(true)
        let blockingGate = makeGate(writeData: { data, url in
            let shouldBlock = shouldBlockWrite.withValue { value in
                defer { value = false }
                return value && url == queueURL
            }
            if shouldBlock {
                persistenceStarted.fulfill()
                releasePersistence.wait()
            }
            try data.write(to: url, options: .atomic)
        })
        try blockingGate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(blockingGate.record(event: validEvent()).result, .accepted)
        wait(for: [persistenceStarted], timeout: 2)

        let otherGate = makeGate()
        let recordFinished = expectation(description: "unrelated record remained non-blocking")
        let result = LockedValue<ExternalTelemetryPrivacyGate.RecordResult?>(nil)
        DispatchQueue.global().async {
            result.set(otherGate.record(event: self.validEvent()).result)
            recordFinished.fulfill()
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [recordFinished], timeout: 0.2),
            .completed,
            "persistence work must execute outside the process-wide state lock"
        )
        releasePersistence.signal()
        XCTAssertEqual(result.get(), .accepted)
        XCTAssertEqual(try blockingGate.queuedEnvelopes().count, 2)
    }

    func testRepeatedInvalidConsentCoalescesWhileRevocationPurgeIsBlocked() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date())), forKey: "insightkit.external-telemetry.consent.v1")
        let admissions = LockedValue(0)
        let staleParticipantObserved = expectation(description: "stale participant observed invalid consent")
        let resumeStaleParticipant = DispatchSemaphore(value: 0)
        let staleParticipantFinished = DispatchGroup()
        let staleGate = makeGate(
            onRecordGuardPassed: {
                staleParticipantObserved.fulfill()
                resumeStaleParticipant.wait()
            },
            onRevocationAdmitted: { admissions.withValue { $0 += 1 } }
        )
        let purgeStarted = expectation(description: "purge reached key deletion")
        let releasePurge = DispatchSemaphore(value: 0)
        let revocationRetired = expectation(description: "token and completed epoch retired atomically")
        let releaseRevocationCompletion = DispatchSemaphore(value: 0)
        let participantCount = 100
        let participantsStarted = expectation(description: "every concurrent participant observed consent")
        participantsStarted.expectedFulfillmentCount = participantCount
        let participantObservations = LockedValue(0)
        let keyDeletionCount = LockedValue(0)
        let participantsFinished = DispatchGroup()
        let gate = makeGate(
            deleteQueueKey: {
                let count = keyDeletionCount.withValue { $0 += 1; return $0 }
                if count == 1 {
                    purgeStarted.fulfill()
                    releasePurge.wait()
                }
            },
            onRevocationAdmitted: { admissions.withValue { $0 += 1 } },
            onConsentObserved: { point in
                if point == .recordInitial || point == .readbackInitial {
                    let count = participantObservations.withValue { $0 += 1; return $0 }
                    if count <= participantCount { participantsStarted.fulfill() }
                }
            },
            onRevocationEpochRetired: {
                revocationRetired.fulfill()
                releaseRevocationCompletion.wait()
            }
        )
        for index in 0..<participantCount {
            participantsFinished.enter()
            DispatchQueue.global().async {
                if index.isMultiple(of: 2) {
                    XCTAssertEqual(gate.record(event: self.validEvent()).result, .disabled)
                } else {
                    XCTAssertEqual(try? gate.queuedEnvelopes(), [])
                }
                participantsFinished.leave()
            }
        }
        wait(for: [purgeStarted], timeout: 2)
        staleParticipantFinished.enter()
        DispatchQueue.global().async {
            XCTAssertEqual(staleGate.record(event: self.validEvent()).result, .disabled)
            staleParticipantFinished.leave()
        }
        wait(for: [staleParticipantObserved], timeout: 2)
        wait(for: [participantsStarted], timeout: 2)
        XCTAssertEqual(admissions.get(), 1)
        releasePurge.signal()
        wait(for: [revocationRetired], timeout: 2)
        resumeStaleParticipant.signal()
        XCTAssertEqual(staleParticipantFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(admissions.get(), 1, "retired epoch must reject stale work before task completion")
        releaseRevocationCompletion.signal()
        XCTAssertEqual(participantsFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        XCTAssertEqual(admissions.get(), 1, "no participant may admit a late purge after release")
    }

    func testPersistedRevocationTokenIsTakenOverOnceAfterRestart() throws {
        let seedGate = makeGate()
        try seedGate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seedGate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seedGate.queuedEnvelopes().count, 1)
        XCTAssertNotNil(queueKey.get())

        let token = "11111111-1111-4111-8111-111111111111"
        defaults.set(token, forKey: "insightkit.external-telemetry.revoked.v1")
        let takeoverStarted = expectation(description: "persisted revocation claimed once")
        let releasePurge = DispatchSemaphore(value: 0)
        let admissions = LockedValue(0)
        let purgeCalls = LockedValue(0)
        let purgeStarted = expectation(description: "restart purge started")
        let restartedGate = makeGate(deleteQueueKey: {
            let call = purgeCalls.withValue { $0 += 1; return $0 }
            if call == 1 {
                purgeStarted.fulfill()
                releasePurge.wait()
            }
        }, onRevocationAdmitted: {
            let count = admissions.withValue { $0 += 1; return $0 }
            if count == 1 {
                takeoverStarted.fulfill()
            }
        })

        for _ in 0..<20 {
            DispatchQueue.global().async { _ = restartedGate.record(event: self.validEvent()) }
        }
        let readbackFinished = DispatchSemaphore(value: 0)
        let readback = LockedValue<[Data]?>(nil)
        DispatchQueue.global().async {
            readback.set(try? restartedGate.queuedEnvelopes())
            readbackFinished.signal()
        }

        wait(for: [takeoverStarted, purgeStarted], timeout: 2)
        XCTAssertEqual(admissions.get(), 1)
        XCTAssertEqual(purgeCalls.get(), 1)
        XCTAssertEqual(readbackFinished.wait(timeout: .now() + 0.05), .timedOut)
        releasePurge.signal()
        XCTAssertEqual(readbackFinished.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(admissions.get(), 1)
        XCTAssertEqual(readback.get(), [])
        XCTAssertNil(queueKey.get(), "restart takeover must cryptographically erase the old queue")
        XCTAssertNil(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"))
    }

    func testExplicitDisableRegistersOneRevocationTaskBeforeTokenIsObservable() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)

        let disableAdmitted = expectation(description: "explicit disable registered token task")
        let resumeDisable = DispatchSemaphore(value: 0)
        let purgeStarted = expectation(description: "explicit disable purge started")
        let releasePurge = DispatchSemaphore(value: 0)
        let purgeCalls = LockedValue(0)
        let evidenceWrites = LockedValue(0)
        let admissionCalls = LockedValue(0)
        let gate = makeGate(
            writeData: { data, url in
                if url.lastPathComponent == "external-telemetry-disable-evidence-v1.json" {
                    evidenceWrites.withValue { $0 += 1 }
                }
                try data.write(to: url, options: .atomic)
            },
            deleteQueueKey: {
                let call = purgeCalls.withValue { $0 += 1; return $0 }
                if call == 1 {
                    purgeStarted.fulfill()
                    releasePurge.wait()
                }
            },
            onRevocationAdmitted: {
                let call = admissionCalls.withValue { $0 += 1; return $0 }
                if call == 1 {
                    disableAdmitted.fulfill()
                    resumeDisable.wait()
                }
            }
        )
        let disableFinished = expectation(description: "explicit disable finished")
        DispatchQueue.global().async {
            _ = gate.disableAndPurge()
            disableFinished.fulfill()
        }
        wait(for: [disableAdmitted], timeout: 2)

        let readbackFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? gate.queuedEnvelopes()
            readbackFinished.signal()
        }
        wait(for: [purgeStarted], timeout: 2)
        XCTAssertEqual(readbackFinished.wait(timeout: .now() + 0.05), .timedOut)
        releasePurge.signal()
        XCTAssertEqual(readbackFinished.wait(timeout: .now() + 2), .success)
        resumeDisable.signal()
        wait(for: [disableFinished], timeout: 2)

        XCTAssertEqual(admissionCalls.get(), 1)
        XCTAssertEqual(purgeCalls.get(), 1)
        XCTAssertEqual(evidenceWrites.get(), 1)
        XCTAssertNil(queueKey.get())
        XCTAssertNil(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"))
    }

    func testRevocationWaiterExecutesOwnerStorageContext() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)

        let ownerAdmitted = expectation(description: "owner task registered")
        let resumeOwner = DispatchSemaphore(value: 0)
        let ownerKeyDeletes = LockedValue(0)
        let ownerEvidenceWrites = LockedValue(0)
        let waiterKeyDeletes = LockedValue(0)
        let waiterEvidenceWrites = LockedValue(0)
        let owner = makeGate(
            writeData: { data, url in
                if url.lastPathComponent == "external-telemetry-disable-evidence-v1.json" {
                    ownerEvidenceWrites.withValue { $0 += 1 }
                }
                try data.write(to: url, options: .atomic)
            },
            deleteQueueKey: { ownerKeyDeletes.withValue { $0 += 1 } },
            onRevocationAdmitted: {
                ownerAdmitted.fulfill()
                resumeOwner.wait()
            }
        )
        let waiter = makeGate(
            writeData: { data, url in
                if url.lastPathComponent == "external-telemetry-disable-evidence-v1.json" {
                    waiterEvidenceWrites.withValue { $0 += 1 }
                }
                try data.write(to: url, options: .atomic)
            },
            deleteQueueKey: { waiterKeyDeletes.withValue { $0 += 1 } }
        )

        let disableFinished = expectation(description: "owner disable finished")
        DispatchQueue.global().async {
            _ = owner.disableAndPurge()
            disableFinished.fulfill()
        }
        wait(for: [ownerAdmitted], timeout: 2)

        let readbackFinished = expectation(description: "waiter joined owner task")
        DispatchQueue.global().async {
            _ = try? waiter.queuedEnvelopes()
            readbackFinished.fulfill()
        }
        wait(for: [readbackFinished], timeout: 2)
        resumeOwner.signal()
        wait(for: [disableFinished], timeout: 2)

        XCTAssertEqual(ownerKeyDeletes.get(), 1)
        XCTAssertEqual(ownerEvidenceWrites.get(), 1)
        XCTAssertEqual(waiterKeyDeletes.get(), 0)
        XCTAssertEqual(waiterEvidenceWrites.get(), 0)
        XCTAssertNil(queueKey.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("external-telemetry-queue-v1.json").path))
    }

    func testRevocationWaiterCannotSubstituteSuccessfulDependenciesForFailingOwnerContext() throws {
        let ownerRoot = root.appendingPathComponent("owner", isDirectory: true)
        let waiterRoot = root.appendingPathComponent("waiter", isDirectory: true)
        let ownerKey = LockedValue<Data?>(nil)
        let waiterKey = LockedValue<Data?>(nil)
        let seed = makeGate(storageDirectory: ownerRoot, queueKeyStore: ownerKey)
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)

        let ownerAdmitted = expectation(description: "failing owner task registered")
        let resumeOwner = DispatchSemaphore(value: 0)
        let ownerEvidence = LockedValue<ExternalTelemetryPrivacyGate.DisableEvidence?>(nil)
        let waiterCalls = LockedValue(0)
        let owner = makeGate(
            storageDirectory: ownerRoot,
            queueKeyStore: ownerKey,
            removeItem: { _ in throw NSError(domain: "owner", code: 1) },
            writeData: { _, _ in throw NSError(domain: "owner", code: 2) },
            saveQueueKey: { _ in throw NSError(domain: "owner", code: 3) },
            deleteQueueKey: { throw NSError(domain: "owner", code: 4) },
            onRevocationAdmitted: {
                ownerAdmitted.fulfill()
                resumeOwner.wait()
            }
        )
        let waiter = makeGate(
            storageDirectory: waiterRoot,
            queueKeyStore: waiterKey,
            writeData: { data, url in
                waiterCalls.withValue { $0 += 1 }
                try data.write(to: url, options: .atomic)
            },
            deleteQueueKey: { waiterCalls.withValue { $0 += 1 } }
        )
        let disableFinished = expectation(description: "failing owner disable finished")
        DispatchQueue.global().async {
            ownerEvidence.set(owner.disableAndPurge())
            disableFinished.fulfill()
        }
        wait(for: [ownerAdmitted], timeout: 2)

        XCTAssertEqual(try waiter.queuedEnvelopes(), [])
        resumeOwner.signal()
        wait(for: [disableFinished], timeout: 2)

        let evidence = try XCTUnwrap(ownerEvidence.get())
        XCTAssertGreaterThan(evidence.remainingItems, 0)
        XCTAssertTrue(evidence.failureCodes.contains("queue-key-delete-failed"))
        XCTAssertEqual(waiterCalls.get(), 0)
        XCTAssertNotNil(ownerKey.get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerRoot.appendingPathComponent("external-telemetry-queue-v1.json").path))
        XCTAssertNotNil(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"))
    }

    func testPersistenceWorkerInvalidConsentObservationPurgesBeforeStaleConsentRestore() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)
        let staleConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))

        let writeStarted = expectation(description: "first persistence write blocked")
        let releaseWrite = DispatchSemaphore(value: 0)
        let firstWrite = LockedValue(true)
        let keyDeleted = expectation(description: "worker observation purged key")
        let gate = makeGate(
            writeData: { data, url in
                if url.lastPathComponent == "external-telemetry-queue-v1.json",
                   firstWrite.withValue({ value in defer { value = false }; return value }) {
                    writeStarted.fulfill()
                    releaseWrite.wait()
                }
                try data.write(to: url, options: .atomic)
            },
            deleteQueueKey: { keyDeleted.fulfill() }
        )
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        wait(for: [writeStarted], timeout: 2)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date())),
            forKey: "insightkit.external-telemetry.consent.v1"
        )
        releaseWrite.signal()
        wait(for: [keyDeleted], timeout: 2)

        defaults.set(staleConsent, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try makeGate().queuedEnvelopes(), [])
        XCTAssertNil(queueKey.get())
    }

    func testRevocationRegistryEvictsObsoleteFailedEpochs() throws {
        let gate = makeGate(
            removeItem: { _ in throw NSError(domain: "forced", code: 1) },
            writeData: { _, _ in throw NSError(domain: "forced", code: 1) },
            saveQueueKey: { _ in throw NSError(domain: "forced", code: 1) },
            deleteQueueKey: { throw NSError(domain: "forced", code: 1) }
        )

        for _ in 0..<5 {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("opaque-encrypted-queue".utf8).write(
                to: root.appendingPathComponent("external-telemetry-queue-v1.json"),
                options: .atomic
            )
            XCTAssertGreaterThan(gate.disableAndPurge().remainingItems, 0)
            XCTAssertEqual(ExternalTelemetryPrivacyGate.revocationTaskCountForTesting, 1)
        }

        try makeGate().setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(ExternalTelemetryPrivacyGate.revocationTaskCountForTesting, 0)
    }

    func testExplicitDisableUUIDGenerationDoesNotHoldGlobalStateLock() throws {
        defaults.set("11111111-1111-4111-8111-111111111111", forKey: "insightkit.external-telemetry.installation-id.v1")
        let active = makeGate()
        try active.setConsent(enabled: true, consentVersion: 1)
        let uuidStarted = expectation(description: "disable UUID generation started outside lock")
        let releaseUUID = DispatchSemaphore(value: 0)
        let calls = LockedValue(0)
        let disabling = makeGate(uuid: {
            let call = calls.withValue { $0 += 1; return $0 }
            if call == 2 {
                uuidStarted.fulfill()
                releaseUUID.wait()
            }
            return UUID()
        })
        let disableFinished = expectation(description: "disable finished")
        DispatchQueue.global().async {
            _ = disabling.disableAndPurge()
            disableFinished.fulfill()
        }
        wait(for: [uuidStarted], timeout: 2)

        let recordFinished = expectation(description: "other record not blocked by UUID")
        DispatchQueue.global().async {
            _ = active.record(event: self.validEvent())
            recordFinished.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [recordFinished], timeout: 0.2), .completed)
        releaseUUID.signal()
        wait(for: [disableFinished], timeout: 2)
    }

    func testWaiterCanSubmitRevocationWhileOriginalOwnerIsPausedBeforeSubmission() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date())),
            forKey: "insightkit.external-telemetry.consent.v1"
        )
        let ownerPaused = expectation(description: "owner paused before submission")
        let resumeOwner = DispatchSemaphore(value: 0)
        let gate = makeGate(onInvalidConsentGenerationAdvanced: {
            ownerPaused.fulfill()
            resumeOwner.wait()
        })
        DispatchQueue.global().async { _ = gate.record(event: self.validEvent()) }
        wait(for: [ownerPaused], timeout: 2)

        let waiterFinished = expectation(description: "waiter submitted shared revocation")
        DispatchQueue.global().async {
            _ = try? gate.queuedEnvelopes()
            waiterFinished.fulfill()
        }
        let verdict = XCTWaiter.wait(for: [waiterFinished], timeout: 0.5)
        resumeOwner.signal()
        XCTAssertEqual(verdict, .completed, "a waiter must be able to submit the admitted token task")
    }

    func testFailedRevocationTaskRemainsTerminalUntilProcessRestart() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date())),
            forKey: "insightkit.external-telemetry.consent.v1"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("opaque-encrypted-queue".utf8).write(to: root.appendingPathComponent("external-telemetry-queue-v1.json"))
        let admissions = LockedValue(0)
        let gate = makeGate(
            removeItem: { _ in throw NSError(domain: "forced", code: 1) },
            writeData: { _, _ in throw NSError(domain: "forced", code: 1) },
            saveQueueKey: { _ in throw NSError(domain: "forced", code: 1) },
            deleteQueueKey: { throw NSError(domain: "forced", code: 1) },
            onRevocationAdmitted: { admissions.withValue { $0 += 1 } }
        )

        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        for _ in 0..<20 {
            XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
            XCTAssertEqual(try gate.queuedEnvelopes(), [])
        }

        XCTAssertEqual(admissions.get(), 1, "a terminal failed token must not retry in the same process")
        XCTAssertNotNil(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"))
    }

    func testOlderPurgeCannotClearNewerFailedRevocationMarker() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let staleAccepted = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 1, grantedAt: Date()))
        let malformed = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date()))
        defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
        let oldCleanupChecked = expectation(description: "old cleanup reached conditional clear")
        let resumeOldCleanup = DispatchSemaphore(value: 0)
        let oldGate = makeGate(onRevocationCleanupChecked: {
            oldCleanupChecked.fulfill()
            resumeOldCleanup.wait()
        })
        let oldFinished = expectation(description: "old cleanup finished")
        DispatchQueue.global().async {
            _ = oldGate.record(event: self.validEvent())
            _ = try? oldGate.queuedEnvelopes()
            oldFinished.fulfill()
        }
        wait(for: [oldCleanupChecked], timeout: 2)

        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        try Data("opaque-old-queue".utf8).write(to: queueURL)
        let newerAdmitted = expectation(description: "newer revocation admitted")
        let newerGate = makeGate(
            removeItem: { _ in throw NSError(domain: "forced", code: 1) },
            writeData: { _, _ in throw NSError(domain: "forced", code: 1) },
            saveQueueKey: { _ in throw NSError(domain: "forced", code: 1) },
            deleteQueueKey: { throw NSError(domain: "forced", code: 1) },
            onRevocationAdmitted: { newerAdmitted.fulfill() }
        )
        let newerEvidence = LockedValue<ExternalTelemetryPrivacyGate.DisableEvidence?>(nil)
        let newerFinished = expectation(description: "newer failed purge finished")
        DispatchQueue.global().async {
            newerEvidence.set(newerGate.disableAndPurge())
            newerFinished.fulfill()
        }
        wait(for: [newerAdmitted], timeout: 2)
        let newerMarker = try XCTUnwrap(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"))

        resumeOldCleanup.signal()
        wait(for: [oldFinished, newerFinished], timeout: 2)
        XCTAssertGreaterThan(try XCTUnwrap(newerEvidence.get()).remainingItems, 0)
        XCTAssertEqual(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"), newerMarker)
        defaults.set(staleAccepted, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertFalse(makeGate().consent.isEnabled)
    }

    func testInstallationFallbackUUIDDoesNotHoldGlobalStateLock() throws {
        defaults.set("11111111-1111-4111-8111-111111111111", forKey: "insightkit.external-telemetry.installation-id.v1")
        let active = makeGate()
        try active.setConsent(enabled: true, consentVersion: 1)
        let started = expectation(description: "fallback UUID outside lock")
        let release = DispatchSemaphore(value: 0)
        let shouldBlock = LockedValue(true)
        DispatchQueue.global().async {
            _ = self.makeGate(uuid: {
                if shouldBlock.withValue({ value in defer { value = false }; return value }) {
                    started.fulfill(); release.wait()
                }
                return UUID()
            }, onInstallationIDObserved: {
                self.defaults.removeObject(forKey: "insightkit.external-telemetry.installation-id.v1")
            })
        }
        wait(for: [started], timeout: 2)
        let finished = expectation(description: "record not blocked")
        DispatchQueue.global().async { _ = active.record(event: self.validEvent()); finished.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 0.2), .completed)
        release.signal()
    }

    func testValueAllowlistRejectsUnbucketedDurationOutOfRangeQualityAndInvalidAppMetadata() throws {
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)

        XCTAssertEqual(gate.record(event: .init(name: "workflow_completed", properties: ["duration_bucket_ms": 5_001])).result, .rejected)
        XCTAssertEqual(gate.record(event: .init(name: "workflow_completed", properties: ["quality_score": -0.01])).result, .rejected)
        XCTAssertEqual(gate.record(event: .init(name: "workflow_completed", properties: ["quality_score": 1.01])).result, .rejected)
        XCTAssertEqual(makeGate(appVersion: "private/path", appBuild: "123").record(event: validEvent()).result, .rejected)

        let invalidMetadata = makeGate(appVersion: "1.2.3-secret", appBuild: "sk-secret")
        try invalidMetadata.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(invalidMetadata.record(event: validEvent()).result, .rejected)
        XCTAssertEqual(try invalidMetadata.queuedEnvelopes(), [])
    }

    func testAppMetadataAcceptsCheckedInTwoComponentBundleVersion() throws {
        let gate = makeGate(appVersion: "1.0", appBuild: "1")
        try gate.setConsent(enabled: true, consentVersion: 1)

        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
    }

    func testRecordAdmissionInvalidConsentObservationCannotBeSuppressedByStaleRestore() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)
        let staleConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let malformed = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date()))
        let restored = LockedValue(false)
        let gate = makeGate(
            onRecordGuardPassed: {
                self.defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
            },
            onConsentObserved: { point in
                if point == .recordAdmission {
                    restored.set(true)
                    self.defaults.set(staleConsent, forKey: "insightkit.external-telemetry.consent.v1")
                }
            }
        )

        XCTAssertEqual(gate.record(event: validEvent()).result, .disabled)
        XCTAssertTrue(restored.get())
        Self.waitUntil { self.queueKey.get() == nil }
        XCTAssertEqual(try makeGate().queuedEnvelopes(), [])
    }

    func testPersistenceWorkerInvalidConsentObservationCannotBeSuppressedByStaleRestore() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)
        let staleConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let malformed = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date()))
        let workerObserved = expectation(description: "worker classified malformed consent")
        let gate = makeGate(onConsentObserved: { point in
            if point == .persistenceWorker {
                workerObserved.fulfill()
                self.defaults.set(staleConsent, forKey: "insightkit.external-telemetry.consent.v1")
            }
        })
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")

        wait(for: [workerObserved], timeout: 2)
        Self.waitUntil { self.queueKey.get() == nil }
        XCTAssertEqual(try makeGate().queuedEnvelopes(), [])
    }

    func testReadbackFinalInvalidConsentObservationCannotBeSuppressedByStaleRestore() throws {
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)
        let staleConsent = try XCTUnwrap(defaults.data(forKey: "insightkit.external-telemetry.consent.v1"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let malformed = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date()))
        let keyReads = LockedValue(0)
        let gate = makeGate(
            readQueueKey: {
                let count = keyReads.withValue { $0 += 1; return $0 }
                if count == 1 {
                    self.defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
                }
                return self.queueKey.get()
            },
            onConsentObserved: { point in
                if point == .readbackFinal {
                    self.defaults.set(staleConsent, forKey: "insightkit.external-telemetry.consent.v1")
                }
            }
        )

        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertNil(queueKey.get())
        XCTAssertEqual(try makeGate().queuedEnvelopes(), [])
    }

    func testSuccessfulRevocationRemovesTokenAndRegistryBeforeWakingWaiters() throws {
        let completionReached = expectation(description: "successful purge reached atomic completion")
        let releaseCompletion = DispatchSemaphore(value: 0)
        let gate = makeGate(onRevocationWillComplete: {
            completionReached.fulfill()
            releaseCompletion.wait()
        })
        try gate.setConsent(enabled: true, consentVersion: 1)
        let finished = expectation(description: "disable returned")
        let didReturn = LockedValue(false)
        DispatchQueue.global().async {
            _ = gate.disableAndPurge()
            didReturn.set(true)
            finished.fulfill()
        }
        wait(for: [completionReached], timeout: 2)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(didReturn.get())
        releaseCompletion.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertNil(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"))
        XCTAssertEqual(ExternalTelemetryPrivacyGate.revocationTaskCountForTesting, 0)
    }

    func testOldRevocationTaskKeepsCreationGenerationWhenJoinerSubmitsAfterNewEnable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(isEnabled: true, version: 99, grantedAt: Date())),
            forKey: "insightkit.external-telemetry.consent.v1"
        )
        let ownerPaused = expectation(description: "old owner paused before submission")
        let releaseOwner = DispatchSemaphore(value: 0)
        let owner = makeGate(onInvalidConsentGenerationAdvanced: {
            ownerPaused.fulfill()
            releaseOwner.wait()
        })
        let ownerFinished = expectation(description: "old owner finished")
        DispatchQueue.global().async {
            _ = owner.record(event: self.validEvent())
            ownerFinished.fulfill()
        }
        wait(for: [ownerPaused], timeout: 2)

        let joinerPaused = expectation(description: "joiner captured old token task")
        let releaseJoiner = DispatchSemaphore(value: 0)
        let joiner = makeGate(onRevocationJoined: {
            joinerPaused.fulfill()
            releaseJoiner.wait()
        })
        let joinerFinished = expectation(description: "joiner finished")
        DispatchQueue.global().async {
            _ = try? joiner.queuedEnvelopes()
            joinerFinished.fulfill()
        }
        wait(for: [joinerPaused], timeout: 2)

        let newlyEnabled = makeGate()
        try newlyEnabled.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(newlyEnabled.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try newlyEnabled.queuedEnvelopes().count, 1)

        releaseJoiner.signal()
        releaseOwner.signal()
        wait(for: [joinerFinished, ownerFinished], timeout: 2)
        Self.waitUntil { ExternalTelemetryPrivacyGate.revocationTaskCountForTesting == 0 }
        XCTAssertTrue(newlyEnabled.consent.isEnabled)
        XCTAssertEqual(try newlyEnabled.queuedEnvelopes().count, 1)
        XCTAssertNotNil(queueKey.get())
    }

    func testEnableConsentAndRevocationClearAreOneObservationForRecordAndReadback() throws {
        defaults.set("old-revocation", forKey: "insightkit.external-telemetry.revoked.v1")
        let consentPersisted = expectation(description: "enable paused between consent and token writes")
        let releaseEnable = DispatchSemaphore(value: 0)
        let enabling = makeGate(onEnableConsentPersisted: {
            consentPersisted.fulfill()
            releaseEnable.wait()
        })
        let enableFinished = expectation(description: "enable finished")
        DispatchQueue.global().async {
            try? enabling.setConsent(enabled: true, consentVersion: 1)
            enableFinished.fulfill()
        }
        wait(for: [consentPersisted], timeout: 2)

        let observer = makeGate()
        let recordResult = LockedValue<ExternalTelemetryPrivacyGate.RecordResult?>(nil)
        let recordFinished = expectation(description: "record observed completed enable")
        DispatchQueue.global().async {
            recordResult.set(observer.record(event: self.validEvent()).result)
            recordFinished.fulfill()
        }
        let readbackFinished = expectation(description: "readback observed completed enable")
        DispatchQueue.global().async {
            _ = try? observer.queuedEnvelopes()
            readbackFinished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(recordResult.get(), "observation must wait for the consent transition")

        releaseEnable.signal()
        wait(for: [enableFinished, recordFinished, readbackFinished], timeout: 2)
        XCTAssertEqual(recordResult.get(), .accepted)
        XCTAssertTrue(observer.consent.isEnabled)
        XCTAssertNil(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"))
        XCTAssertEqual(ExternalTelemetryPrivacyGate.revocationTaskCountForTesting, 0)
        XCTAssertEqual(try observer.queuedEnvelopes().count, 1)
        XCTAssertNotNil(queueKey.get())
    }

    func testRepeatedInvalidConsentAfterNewGrantPurgesTheNewConsentEpoch() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let malformed = try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
            isEnabled: true, version: 99, grantedAt: Date()
        ))
        let gate = makeGate()
        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)

        defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertNil(queueKey.get())

        try gate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(gate.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try gate.queuedEnvelopes().count, 1)
        XCTAssertNotNil(queueKey.get())

        defaults.set(malformed, forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
        XCTAssertNil(queueKey.get())
        defaults.set(try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
            isEnabled: true, version: 1, grantedAt: Date()
        )), forKey: "insightkit.external-telemetry.consent.v1")
        XCTAssertEqual(try gate.queuedEnvelopes(), [])
    }

    func testSameDurableInvalidEpochCoalescesAcrossDefaultsInstances() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let seed = makeGate()
        try seed.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(seed.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try seed.queuedEnvelopes().count, 1)
        XCTAssertNotNil(queueKey.get())
        defaults.set(try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
            isEnabled: true, version: 99, grantedAt: Date()
        )), forKey: "insightkit.external-telemetry.consent.v1")
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let firstPurgeBlocked = expectation(description: "first invalid epoch purge blocked")
        let secondObserved = expectation(description: "second defaults observed same invalid epoch")
        let releasePurge = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let admissions = LockedValue(0)
        let keyDeletions = LockedValue(0)
        let evidenceWrites = LockedValue(0)
        let writeData: (Data, URL) throws -> Void = { data, url in
            if url.lastPathComponent == "external-telemetry-disable-evidence-v1.json" {
                evidenceWrites.withValue { $0 += 1 }
            }
            try data.write(to: url, options: .atomic)
        }
        let first = ExternalTelemetryPrivacyGate(
            configuration: try ExternalTelemetryConfiguration(environment: .development, retentionDays: 30, maxQueueItems: 10),
            appVersion: "1.2.3", appBuild: "123", defaults: defaults, storageDirectory: root,
            readQueueKey: { self.queueKey.get() }, saveQueueKey: { self.queueKey.set($0) },
            deleteQueueKey: {
                keyDeletions.withValue { $0 += 1 }
                firstPurgeBlocked.fulfill()
                releasePurge.wait()
                self.queueKey.set(nil)
            },
            writeData: writeData,
            onRevocationAdmitted: { admissions.withValue { $0 += 1 } },
            onConsentObserved: { _ in }
        )
        let second = ExternalTelemetryPrivacyGate(
            configuration: try ExternalTelemetryConfiguration(environment: .development, retentionDays: 30, maxQueueItems: 10),
            appVersion: "1.2.3", appBuild: "123", defaults: secondDefaults, storageDirectory: root,
            readQueueKey: { self.queueKey.get() }, saveQueueKey: { self.queueKey.set($0) },
            deleteQueueKey: {
                keyDeletions.withValue { $0 += 1 }
                self.queueKey.set(nil)
            },
            writeData: writeData,
            onRevocationAdmitted: { admissions.withValue { $0 += 1 } },
            onConsentObserved: { point in
                if point == .readbackInitial { secondObserved.fulfill(); releaseSecond.wait() }
            }
        )
        let firstDone = expectation(description: "first invalid readback completed")
        DispatchQueue.global().async { _ = try? first.queuedEnvelopes(); firstDone.fulfill() }
        wait(for: [firstPurgeBlocked], timeout: 2)
        let secondDone = expectation(description: "second invalid readback completed")
        DispatchQueue.global().async { _ = try? second.queuedEnvelopes(); secondDone.fulfill() }
        wait(for: [secondObserved], timeout: 2)

        releasePurge.signal()
        wait(for: [firstDone], timeout: 2)
        releaseSecond.signal()
        wait(for: [secondDone], timeout: 2)
        XCTAssertEqual(admissions.get(), 1)
        XCTAssertEqual(keyDeletions.get(), 1)
        XCTAssertEqual(evidenceWrites.get(), 1)
        XCTAssertNil(defaults.string(forKey: "insightkit.external-telemetry.revoked.v1"))
        XCTAssertNil(queueKey.get())
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: queueURL.path) && queueKey.get() != nil,
            "the durable queue must be absent or cryptographically unreadable"
        )
    }

    func testReadbackInitialInvalidObservationCannotRevokeNewerEnableGeneration() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
            isEnabled: true, version: 99, grantedAt: Date()
        )), forKey: "insightkit.external-telemetry.consent.v1")
        let invalidObserved = expectation(description: "readback captured invalid consent")
        let resumeReadback = DispatchSemaphore(value: 0)
        let staleReader = makeGate(onConsentObserved: { point in
            if point == .readbackInitial { invalidObserved.fulfill(); resumeReadback.wait() }
        })
        let readbackDone = expectation(description: "stale readback returned")
        DispatchQueue.global().async { _ = try? staleReader.queuedEnvelopes(); readbackDone.fulfill() }
        wait(for: [invalidObserved], timeout: 2)

        let enabled = makeGate()
        try enabled.setConsent(enabled: true, consentVersion: 1)
        XCTAssertEqual(enabled.record(event: validEvent()).result, .accepted)
        XCTAssertEqual(try enabled.queuedEnvelopes().count, 1)
        let enabledKey = queueKey.get()

        resumeReadback.signal()
        wait(for: [readbackDone], timeout: 2)
        XCTAssertTrue(enabled.consent.isEnabled)
        XCTAssertEqual(queueKey.get(), enabledKey)
        XCTAssertEqual(try enabled.queuedEnvelopes().count, 1)
    }

    private static func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    }

    private func validEvent() -> ExternalTelemetryPrivacyGate.Event {
        .init(name: "workflow_completed", properties: [
            "workflow": "import",
            "analysis_mode": "local",
            "phase": "finalizing",
            "outcome": "succeeded",
            "duration_bucket_ms": 5_000,
            "result_count": 3,
        ])
    }

    private func queuedObjects(_ gate: ExternalTelemetryPrivacyGate) throws -> [[String: Any]] {
        try gate.queuedEnvelopes().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
    }

    private func assertInvalidConsentTransitionCannotOverwriteNewerEnable(
        operation: @escaping (ExternalTelemetryPrivacyGate) throws -> Void
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode(ExternalTelemetryPrivacyGate.Consent(
                isEnabled: true,
                version: 99,
                grantedAt: Date()
            )),
            forKey: "insightkit.external-telemetry.consent.v1"
        )
        let invalidationStarted = expectation(description: "invalid consent generation advanced")
        let resumeInvalidation = DispatchSemaphore(value: 0)
        let invalidatingGate = makeGate(onInvalidConsentGenerationAdvanced: {
            invalidationStarted.fulfill()
            resumeInvalidation.wait()
        })
        let invalidationFinished = expectation(description: "invalid consent transition finished")
        DispatchQueue.global().async {
            try? operation(invalidatingGate)
            invalidationFinished.fulfill()
        }
        wait(for: [invalidationStarted], timeout: 2)

        let enablingGate = makeGate()
        try enablingGate.setConsent(enabled: true, consentVersion: 1)
        XCTAssertTrue(enablingGate.consent.isEnabled)
        resumeInvalidation.signal()
        wait(for: [invalidationFinished], timeout: 2)

        XCTAssertTrue(enablingGate.consent.isEnabled)
        XCTAssertTrue(invalidatingGate.consent.isEnabled)
    }

    private func makeGate(
        now: @escaping () -> Date = Date.init,
        uuid: @escaping () -> UUID = UUID.init,
        maxQueueItems: Int = 10,
        retentionDays: Int = 30,
        environment: TelemetryEnvironment = .development,
        storageDirectory: URL? = nil,
        queueKeyStore: LockedValue<Data?>? = nil,
        removeItem: @escaping (URL) throws -> Void = FileManager.default.removeItem(at:),
        appVersion: String = "1.2.3",
        appBuild: String = "123",
        writeData: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) },
        readQueueKey: (() throws -> Data?)? = nil,
        saveQueueKey: ((Data) throws -> Void)? = nil,
        deleteQueueKey: @escaping () throws -> Void = {},
        onRecordGuardPassed: @escaping () -> Void = {},
        onEnableCleanupCompleted: @escaping () -> Void = {},
        onInstallationIDMissing: @escaping () -> Void = {},
        onInstallationIDObserved: @escaping () -> Void = {},
        onInvalidConsentGenerationAdvanced: @escaping () -> Void = {},
        onInvalidConsentGuardPassed: @escaping () -> Void = {}
        , onRevocationCleanupChecked: @escaping () -> Void = {}
        , onRevocationAdmitted: @escaping () -> Void = {}
        , onConsentObserved: @escaping (ExternalTelemetryPrivacyGate.ConsentObservationPoint) -> Void = { _ in }
        , onRevocationWillComplete: @escaping () -> Void = {}
        , onRevocationJoined: @escaping () -> Void = {}
        , onRevocationEpochRetired: @escaping () -> Void = {}
        , onEnableConsentPersisted: @escaping () -> Void = {}
    ) -> ExternalTelemetryPrivacyGate {
        let keyStore = queueKeyStore ?? queueKey!
        return ExternalTelemetryPrivacyGate(
            configuration: try! ExternalTelemetryConfiguration(
                environment: environment,
                retentionDays: retentionDays,
                maxQueueItems: maxQueueItems
            ),
            appVersion: appVersion,
            appBuild: appBuild,
            defaults: defaults,
            storageDirectory: storageDirectory ?? root,
            now: now,
            uuid: uuid,
            removeItem: removeItem,
            readQueueKey: { try readQueueKey?() ?? keyStore.get() },
            saveQueueKey: { data in
                if let saveQueueKey { try saveQueueKey(data) }
                else { keyStore.set(data) }
            },
            deleteQueueKey: {
                try deleteQueueKey()
                keyStore.set(nil)
            },
            writeData: writeData,
            onRecordGuardPassed: onRecordGuardPassed,
            onEnableCleanupCompleted: onEnableCleanupCompleted,
            onInstallationIDMissing: onInstallationIDMissing,
            onInstallationIDObserved: onInstallationIDObserved,
            onInvalidConsentGenerationAdvanced: onInvalidConsentGenerationAdvanced,
            onInvalidConsentGuardPassed: onInvalidConsentGuardPassed
            , onRevocationCleanupChecked: onRevocationCleanupChecked
            , onRevocationAdmitted: onRevocationAdmitted
            , onConsentObserved: onConsentObserved
            , onRevocationWillComplete: onRevocationWillComplete
            , onRevocationJoined: onRevocationJoined
            , onRevocationEpochRetired: onRevocationEpochRetired
            , onEnableConsentPersisted: onEnableConsentPersisted
        )
    }


    private func mutateQueuedEnvelope(_ mutation: (inout [String: Any]) -> Void) throws {
        let queueURL = root.appendingPathComponent("external-telemetry-queue-v1.json")
        let key = SymmetricKey(data: try XCTUnwrap(queueKey.get()))
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: queueURL)), using: key)
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: clear) as? [[String: Any]])
        mutation(&objects[0])
        let tampered = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        try XCTUnwrap(AES.GCM.seal(tampered, using: key).combined).write(to: queueURL, options: .atomic)
    }

    private func uuidSequence(_ values: [String]) -> () -> UUID {
        var iterator = values.makeIterator()
        return { UUID(uuidString: iterator.next()!)! }
    }
}

private final class LockedValue<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
