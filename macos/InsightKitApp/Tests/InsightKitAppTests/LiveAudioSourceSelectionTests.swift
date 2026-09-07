import XCTest
@testable import InsightKitApp

final class LiveAudioSourceSelectionTests: XCTestCase {
    func testAudioToggleChangesSelectTheModeUsedToStartCapture() {
        let viewModel = makeViewModel()
        viewModel.inputMode = .systemAudio
        viewModel.selectedSystemSourceID = "display:1"
        viewModel.visualPreviewSource = .screen

        viewModel.setAudioInputSources(microphoneEnabled: true, systemAudioEnabled: true)
        XCTAssertEqual(viewModel.inputMode, .mixed)

        viewModel.setAudioInputSources(microphoneEnabled: true, systemAudioEnabled: false)
        XCTAssertEqual(viewModel.inputMode, .microphone)

        viewModel.setAudioInputSources(microphoneEnabled: false, systemAudioEnabled: true)
        XCTAssertEqual(viewModel.inputMode, .systemAudio)
        XCTAssertEqual(viewModel.selectedSystemSourceID, "display:1")
        XCTAssertEqual(viewModel.visualPreviewSource, .screen)
    }

    func testTurningOffBothAudioSourcesPreservesTheSelectedMode() {
        let viewModel = makeViewModel()

        for mode in AudioInputMode.allCases {
            viewModel.inputMode = mode
            viewModel.setAudioInputSources(microphoneEnabled: false, systemAudioEnabled: false)
            XCTAssertEqual(viewModel.inputMode, mode, "Reject an empty selection without choosing a fallback source")
        }
    }

    func testAudioTogglesCannotChangeModeDuringCapture() {
        let viewModel = makeViewModel()
        viewModel.inputMode = .systemAudio
        viewModel._isRunningLock.lock()
        viewModel._isRunning = true
        viewModel._isRunningLock.unlock()

        XCTAssertFalse(viewModel.canChangeInputMode)
        viewModel.setAudioInputSources(microphoneEnabled: true, systemAudioEnabled: false)
        XCTAssertEqual(viewModel.inputMode, .systemAudio)
        viewModel.setAudioInputSources(microphoneEnabled: true, systemAudioEnabled: true)
        XCTAssertEqual(viewModel.inputMode, .systemAudio)
    }

    func testPickerReloadKeepsAnUnselectedSourceUncommitted() {
        let viewModel = makeViewModel()
        viewModel.selectedSystemSourceID = nil

        viewModel.updateSystemAudioSources([displaySource], selectDefaultSource: false)

        XCTAssertEqual(viewModel.systemAudioSources, [displaySource])
        XCTAssertNil(viewModel.selectedSystemSourceID, "Browsing or cancelling the picker must not commit its default row")
    }

    func testPickerReloadPreservesAnExistingSelectionUntilConfirmation() {
        let viewModel = makeViewModel()
        viewModel.selectedSystemSourceID = "app:42"

        viewModel.updateSystemAudioSources([displaySource], selectDefaultSource: false)
        XCTAssertEqual(viewModel.selectedSystemSourceID, "app:42")

        viewModel.selectSystemSource(displaySource.id)
        XCTAssertEqual(viewModel.selectedSystemSourceID, "display:1")
    }

    func testStartupReloadStillSelectsTheFirstSourceOnlyWhenNeeded() {
        let viewModel = makeViewModel()
        viewModel.selectedSystemSourceID = nil

        viewModel.updateSystemAudioSources([displaySource], selectDefaultSource: true)
        XCTAssertEqual(viewModel.selectedSystemSourceID, "display:1")

        viewModel.selectedSystemSourceID = "app:42"
        viewModel.updateSystemAudioSources([displaySource], selectDefaultSource: true)
        XCTAssertEqual(viewModel.selectedSystemSourceID, "app:42")
    }

    private var displaySource: SystemAudioSourceItem {
        SystemAudioSourceItem(id: "display:1", kind: .display, title: "Display", subtitle: "Test source")
    }

    private func makeViewModel() -> LiveSessionViewModel {
        LiveSessionViewModel(rpcClient: RPCClientMock(), analyticsSubmit: { _ in })
    }
}
