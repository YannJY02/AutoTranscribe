import Combine
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

    func testDirectSettingsEntryCanOpenSettingsWorkspace() {
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

        coordinator.openSettings()

        XCTAssertEqual(openedSettingsCount, 1)
    }

    func testBottomStatusPayloadExposesSettingsAction() {
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

        coordinator.openLive()

        XCTAssertEqual(coordinator.bottomStatusPayload.actions, [.settings])
    }

    func testPrimaryNavigationFromRecordReviewReturnsToRecordsListInsteadOfHome() {
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

        coordinator.openRecords()
        XCTAssertEqual(coordinator.primaryNavigationAction, .home)

        coordinator.recordsNavigation.openReview(recordID: "record-review-fixture")

        XCTAssertEqual(coordinator.primaryNavigationAction, .recordsList)

        coordinator.performPrimaryNavigationAction()

        XCTAssertEqual(coordinator.route, .records)
        XCTAssertEqual(coordinator.appState.activeRoute, .records)
        XCTAssertFalse(coordinator.recordsNavigation.isReviewingRecord)
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

    func testImportProcessingBlocksSidecarConfigRestart() {
        let tx = TranscriptionSessionViewModel(
            rpcClient: RPCClientMock(),
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        let importViewModel = ImportSessionViewModel(rpcClient: RPCClientMock())
        let coordinator = WorkflowCoordinator(
            transcriptionViewModel: tx,
            importViewModel: importViewModel,
            capabilityClient: RPCClientMock()
        )

        XCTAssertFalse(coordinator.hasActiveSidecarWork)
        importViewModel.sessionPhase = .processing
        XCTAssertTrue(coordinator.hasActiveSidecarWork)
    }

    func testLiveFinalizationAndInsightRefreshBlockSidecarConfigRestart() {
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

        live.isFinalizingLiveSession = true
        XCTAssertTrue(coordinator.hasActiveSidecarWork)

        live.isFinalizingLiveSession = false
        live.captureState = .refreshing
        XCTAssertTrue(coordinator.hasActiveSidecarWork)
    }

    func testTranscriptionInsightBuildBlocksSidecarConfigRestart() {
        let rpc = RPCClientMock()
        rpc.buildFinalDelaySec = 0.1
        let tx = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        tx.currentMeetingID = "transcription-finalizing"
        let coordinator = WorkflowCoordinator(
            transcriptionViewModel: tx,
            capabilityClient: RPCClientMock()
        )

        tx.buildFinalInsight()

        XCTAssertTrue(coordinator.hasActiveSidecarWork)
    }

    func testTranscriptionSubmissionBlocksSidecarConfigRestartBeforeStatusRefresh() {
        let rpc = RPCClientMock()
        rpc.transcriptionStatusDelaySec = 0.1
        let tx = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        let coordinator = WorkflowCoordinator(
            transcriptionViewModel: tx,
            capabilityClient: RPCClientMock()
        )

        tx.importFile(path: "/tmp/synthetic.wav")

        XCTAssertTrue(tx.hasPendingSidecarMutation)
        XCTAssertTrue(coordinator.hasActiveSidecarWork)
    }

    func testCompletedMeetingArtifactLoadsAreCoalescedInsteadOfDropped() {
        let rpc = RPCClientMock()
        let tx = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )

        let completed = expectation(description: "both artifact loads complete")
        var cancellable: AnyCancellable?
        cancellable = tx.$isBuildingFinalInsight.sink { isBuilding in
            if !isBuilding, rpc.buildFinalMeetingIDs.count == 2 {
                completed.fulfill()
            }
        }

        tx.loadArtifactsForMeeting("meeting-1")
        tx.loadArtifactsForMeeting("meeting-2")

        wait(for: [completed], timeout: 1.0)
        cancellable?.cancel()
        XCTAssertEqual(rpc.buildFinalMeetingIDs, ["meeting-1", "meeting-2"])
        XCTAssertFalse(tx.isBuildingFinalInsight)
    }

    func testFailedFinalizationAbortKeepsVisibleBusyState() {
        let rpc = RPCClientMock()
        rpc.recordsSaveError = NSError(domain: "test", code: 1)
        rpc.finalizationAbortError = NSError(domain: "test", code: 2)
        let abortAttempted = expectation(description: "finalization abort attempted")
        rpc.finalizationAbortObserver = { abortAttempted.fulfill() }
        let live = LiveSessionViewModel(rpcClient: rpc)
        let segment = TranscriptSegment(
            startMs: 0,
            endMs: 1_000,
            speaker: "speaker",
            source: "mic",
            text: "content"
        )

        live.saveToRecords(
            meetingID: "failed-finalization",
            transcriptSegmentsOverride: [segment],
            finalizationLeaseToken: "lease-token"
        )

        wait(for: [abortAttempted], timeout: 1.0)
        drainWorkflowCoordinatorTestMainQueue()
        XCTAssertTrue(live.isFinalizingLiveSession)
        XCTAssertEqual(rpc.finalizationAbortCalls.first?.leaseToken, "lease-token")
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
