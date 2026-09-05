import Darwin
import XCTest
@testable import InsightKitApp

final class UITestStorageIsolationTests: XCTestCase {
    func testUITestInstanceLockIsStableAcrossRelaunchAndIsolatedBetweenRuns() throws {
        let first = UITestStorageContext(sessionID: UUID())
        let relaunched = try XCTUnwrap(UITestStorageContext.resolve(environment: first.launchEnvironment))
        let second = UITestStorageContext(sessionID: UUID())
        defer { cleanUp(first); cleanUp(second) }

        let firstLockURL = AppLifecycleDelegate.instanceLockURL(uiTestContext: first)
        let relaunchedLockURL = AppLifecycleDelegate.instanceLockURL(uiTestContext: relaunched)
        let secondLockURL = AppLifecycleDelegate.instanceLockURL(uiTestContext: second)
        XCTAssertEqual(firstLockURL.deletingLastPathComponent(), first.rootDirectory)
        XCTAssertEqual(firstLockURL, relaunchedLockURL)
        XCTAssertNotEqual(firstLockURL, secondLockURL)
        XCTAssertNotEqual(firstLockURL, AppLifecycleDelegate.instanceLockURL(uiTestContext: nil))

        guard case .acquired(let firstDescriptor) = AppLifecycleDelegate.claimSingleInstance(at: firstLockURL) else {
            return XCTFail("First UI-test run must acquire its own instance lock")
        }
        defer { close(firstDescriptor) }
        guard case .contended = AppLifecycleDelegate.claimSingleInstance(at: relaunchedLockURL) else {
            return XCTFail("The same UI-test run must keep single-instance protection")
        }
        guard case .acquired(let secondDescriptor) = AppLifecycleDelegate.claimSingleInstance(at: secondLockURL) else {
            return XCTFail("Another UI-test run must not contend for the first run's instance lock")
        }
        defer { close(secondDescriptor) }
    }

    func testNormalApplicationKeepsOperatorInstanceLockPath() {
        let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InsightKit/insightkit-app.lock")
        XCTAssertEqual(AppLifecycleDelegate.instanceLockURL(uiTestContext: nil), expected)
    }

    func testUITestBootstrapDoesNotRewriteExistingRecordsPreference() throws {
        let suiteName = "InsightKitOperatorPreferenceRegression-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let ownerRoot = fixtureRoot.appendingPathComponent("owner-records", isDirectory: true)
        let context = UITestStorageContext(sessionID: UUID())
        defaults.set(ownerRoot.path, forKey: RecordsIndexService.rootDirectoryDefaultsKey)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            cleanUp(context)
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        withEnvironment(context.launchEnvironment) {
            let records = RecordsIndexService(defaults: defaults)
            let coordinator = WorkflowCoordinator(
                liveViewModel: LiveSessionViewModel(rpcClient: RPCClientMock()),
                transcriptionViewModel: TranscriptionSessionViewModel(
                    rpcClient: RPCClientMock(), autoRefresh: false,
                    autoPolling: false, bootstrapSidecar: false
                ),
                importViewModel: ImportSessionViewModel(rpcClient: RPCClientMock()),
                recordsService: records,
                capabilityClient: RPCClientMock()
            )
            defer { coordinator.shutdown() }

            XCTAssertEqual(
                defaults.string(forKey: RecordsIndexService.rootDirectoryDefaultsKey),
                ownerRoot.path,
                "UI-test bootstrap must not overwrite the existing persistent Records preference"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownerRoot.path))
            XCTAssertEqual(records.rootDirectory, context.recordsDirectory)
            XCTAssertEqual(records.records.first?.id, "record-restart-proof")
        }
    }

    func testUITestConfigurationAndRecordsPersistWithinRunWithoutChangingOperatorDomain() throws {
        let suiteName = "InsightKitOperatorConfigRegression-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let ownerRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let ownerConfig = AppConfigStore(
            defaults: defaults, configSnapshotURL: ownerRoot.appendingPathComponent("config.json"),
            isolateExternalState: true
        )
        ownerConfig.updateAppleSpeechPrototypeEnabled(false)
        defaults.set("existing-owner-records", forKey: RecordsIndexService.rootDirectoryDefaultsKey)
        defaults.set("owner-preference", forKey: "unrelated-preference")
        let before = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
        let context = UITestStorageContext(sessionID: UUID())
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: ownerRoot)
            cleanUp(context)
        }

        try withEnvironment(context.launchEnvironment) {
            let firstStore = AppConfigStore.makeUITestStore(context: context)
            firstStore.updateAppleSpeechPrototypeEnabled(true)
            firstStore.updateASREngine(.funasr)
            firstStore.updateAnalysisMode(.local)
            let firstRecords = RecordsIndexService(defaults: defaults)
            firstRecords.prepareUITestSeed(recordID: "persisted-across-relaunch")

            // New instances load persisted state, as a second app process does.
            let secondStore = AppConfigStore.makeUITestStore(context: context)
            let secondRecords = RecordsIndexService(defaults: defaults)
            secondRecords.refreshIndex()
            XCTAssertTrue(secondStore.config.asr.appleSpeechPrototypeEnabled)
            XCTAssertEqual(secondStore.config.asr.engine, .funasr)
            XCTAssertEqual(secondStore.config.analysis.mode, .local)
            XCTAssertEqual(secondRecords.records.map(\.id), ["persisted-across-relaunch"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: context.configSnapshotURL.path))
            let after = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
            XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: after), "Operator preferences must remain unchanged")
            XCTAssertFalse(ownerConfig.config.asr.appleSpeechPrototypeEnabled)
        }
    }

    func testIndependentUITestRunsDoNotShareConfigurationOrRecords() {
        let first = UITestStorageContext(sessionID: UUID())
        let second = UITestStorageContext(sessionID: UUID())
        defer { cleanUp(first); cleanUp(second) }

        withEnvironment(first.launchEnvironment) {
            let store = AppConfigStore.makeUITestStore(context: first)
            store.updateAppleSpeechPrototypeEnabled(true)
            RecordsIndexService().prepareUITestSeed(recordID: "first-run-only")
        }
        withEnvironment(second.launchEnvironment) {
            let store = AppConfigStore.makeUITestStore(context: second)
            let records = RecordsIndexService()
            records.refreshIndex()
            XCTAssertFalse(store.config.asr.appleSpeechPrototypeEnabled)
            XCTAssertTrue(records.records.isEmpty)
        }
    }

    func testRelaunchCanDisableSeedingWithoutDisablingIsolation() {
        let context = UITestStorageContext(sessionID: UUID())
        defer { cleanUp(context) }
        var environment = context.launchEnvironment
        environment["INSIGHTKIT_UI_TEST_SEED_RECORDS"] = "0"

        withEnvironment(environment) {
            let records = RecordsIndexService()
            let coordinator = WorkflowCoordinator(
                liveViewModel: LiveSessionViewModel(rpcClient: RPCClientMock()),
                transcriptionViewModel: TranscriptionSessionViewModel(
                    rpcClient: RPCClientMock(), autoRefresh: false,
                    autoPolling: false, bootstrapSidecar: false
                ),
                importViewModel: ImportSessionViewModel(rpcClient: RPCClientMock()),
                recordsService: records,
                capabilityClient: RPCClientMock()
            )
            defer { coordinator.shutdown() }
            records.refreshIndex()
            XCTAssertTrue(UITestLaunchOptions.isEnabled)
            XCTAssertEqual(records.rootDirectory, context.recordsDirectory)
            XCTAssertTrue(records.records.isEmpty, "A relaunch must not recreate the record being tested")
        }
    }

    func testUITestStorageDoesNotDependOnMockModeRemainingEnabled() throws {
        let context = UITestStorageContext(sessionID: UUID())
        var environment = context.launchEnvironment
        environment["INSIGHTKIT_UI_TEST_MODE"] = "0"
        let resolved = try XCTUnwrap(UITestStorageContext.resolve(environment: environment))
        XCTAssertEqual(resolved.defaultsSuiteName, context.defaultsSuiteName)
        XCTAssertEqual(resolved.recordsDirectory, context.recordsDirectory)
    }

    func testAdHocUITestModeDoesNotUseAnOperatorRecordsOverride() throws {
        let environment = [
            "INSIGHTKIT_UI_TEST_MODE": "1",
            "INSIGHTKIT_RECORDS_ROOT": "/operator-records-must-not-be-used",
        ]
        let context = try XCTUnwrap(UITestStorageContext.resolve(environment: environment))
        XCTAssertEqual(RecordsIndexService.currentRootDirectory(environment: environment), context.recordsDirectory)
        XCTAssertNil(UITestStorageContext.resolve(environment: [:]))
    }

    private func cleanUp(_ context: UITestStorageContext) {
        context.makeDefaults().removePersistentDomain(forName: context.defaultsSuiteName)
        try? FileManager.default.removeItem(at: context.rootDirectory)
    }

    private func withEnvironment(_ values: [String: String], body: () throws -> Void) rethrows {
        var saved: [String: String] = [:]
        for key in values.keys {
            saved[key] = ProcessInfo.processInfo.environment[key]
        }
        defer {
            for key in values.keys {
                if let value = saved[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }
        try body()
    }
}
