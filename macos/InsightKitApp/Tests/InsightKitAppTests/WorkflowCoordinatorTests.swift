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
}
