import XCTest
@testable import InsightKitApp

final class WorkflowCoordinatorTests: XCTestCase {
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
}
