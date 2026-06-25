import XCTest
@testable import InsightKitApp

final class WorkflowCoordinatorTests: XCTestCase {
    func testOpenLiveResetsPreparedInputModeToMicrophone() {
        let live = LiveSessionViewModel()
        live.inputMode = .mixed

        let tx = TranscriptionSessionViewModel(
            rpcClient: RPCClientMock(),
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        let coordinator = WorkflowCoordinator(liveViewModel: live, transcriptionViewModel: tx)

        coordinator.openLive()

        XCTAssertEqual(coordinator.route, .live)
        XCTAssertEqual(live.inputMode, .microphone)
    }

    func testRouteSwitchingUpdatesAppState() {
        let live = LiveSessionViewModel()
        let tx = TranscriptionSessionViewModel(
            rpcClient: RPCClientMock(),
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        let coordinator = WorkflowCoordinator(liveViewModel: live, transcriptionViewModel: tx)

        XCTAssertEqual(coordinator.route, .home)
        XCTAssertEqual(coordinator.appState.activeRoute, .home)

        coordinator.openTranscription()
        XCTAssertEqual(coordinator.route, .transcription)
        XCTAssertEqual(coordinator.appState.activeRoute, .transcription)

        coordinator.openLive()
        XCTAssertEqual(coordinator.route, .live)
        XCTAssertEqual(coordinator.appState.activeRoute, .live)

        coordinator.openHome()
        XCTAssertEqual(coordinator.route, .home)
        XCTAssertEqual(coordinator.appState.activeRoute, .home)
    }

    func testNativePersistedRecordEnablesExportWithoutDocumentExportCapability() throws {
        let root = RecordExportTestFixture.makeRoot(prefix: "InsightKitCoordinatorExport")
        let liveID = "live-coordinator-export"
        let txID = "file-coordinator-export"
        try RecordExportTestFixture.seedRecord(root: root, recordID: liveID, source: .live)
        try RecordExportTestFixture.seedRecord(root: root, recordID: txID, source: .imported)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordsService = RecordsIndexService()
        recordsService.rootDirectory = root
        let live = LiveSessionViewModel(rpcClient: RPCClientMock())
        let tx = TranscriptionSessionViewModel(
            rpcClient: RPCClientMock(),
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        let coordinator = WorkflowCoordinator(
            liveViewModel: live,
            transcriptionViewModel: tx,
            recordsService: recordsService,
            capabilityClient: RPCClientMock()
        )

        live.stateQueue.sync {
            live._sessionState.lastMeetingID = liveID
        }
        tx.currentMeetingID = txID

        XCTAssertTrue(coordinator.canExportLive)
        XCTAssertTrue(coordinator.canExportTranscription)
    }

    func testComputedBannerActionCanOpenSettingsWithoutStoredBannerMessage() {
        var openedSettingsCount = 0
        let live = LiveSessionViewModel(rpcClient: RPCClientMock())
        let tx = TranscriptionSessionViewModel(
            rpcClient: RPCClientMock(),
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        let coordinator = WorkflowCoordinator(
            liveViewModel: live,
            transcriptionViewModel: tx,
            capabilityClient: RPCClientMock(),
            settingsOpener: {
                openedSettingsCount += 1
            }
        )

        XCTAssertNil(coordinator.bannerMessage)

        coordinator.performBannerAction(for: "open_settings")

        XCTAssertEqual(openedSettingsCount, 1)
    }

    func testActiveLiveMeetingStillBlocksNewLiveStartWhileStopIsFinalizing() {
        let live = LiveSessionViewModel(rpcClient: RPCClientMock())
        let tx = TranscriptionSessionViewModel(
            rpcClient: RPCClientMock(),
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        let coordinator = WorkflowCoordinator(
            liveViewModel: live,
            transcriptionViewModel: tx,
            capabilityClient: RPCClientMock()
        )
        live.stateQueue.sync {
            live._isRunningLock.lock()
            live._isRunning = false
            live._isRunningLock.unlock()
            live._sessionState.activeMeetingID = "live-stopping"
            live._sessionState.lastMeetingID = nil
        }
        live.syncSessionHandleFromState()
        drainWorkflowCoordinatorTestMainQueue()

        XCTAssertEqual(coordinator.livePhase, .livePostSession)
        XCTAssertFalse(coordinator.canStartLive)
    }
}

private func drainWorkflowCoordinatorTestMainQueue(
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let expectation = XCTestExpectation(description: "workflow coordinator main queue drained")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1.0)
}
