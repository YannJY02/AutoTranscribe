import SwiftUI
import XCTest
@testable import InsightKitApp

final class LiveVisualSourceSelectionTests: XCTestCase {
    @MainActor
    func testRecreatedWorkspaceReadsTheCurrentCameraAndScreenSelection() {
        let viewModel = makeSyntheticViewModel()
        let selections: [(Bool, Bool, Set<String>)] = [
            (true, false, ["camera"]),
            (false, true, ["screen"]),
            (true, true, ["camera", "screen"]),
        ]
        for (cameraEnabled, screenEnabled, expected) in selections {
            viewModel.applyVisualPreviewSelection(cameraEnabled: cameraEnabled, screenEnabled: screenEnabled)
            let firstWorkspace = LiveWorkspaceView(viewModel: viewModel)
            XCTAssertEqual(enabledVisualInputs(in: firstWorkspace), expected)

            viewModel.prepareForLiveEntry()
            let reopenedWorkspace = LiveWorkspaceView(viewModel: viewModel)

            XCTAssertEqual(enabledVisualInputs(in: reopenedWorkspace), expected,
                           "Recreating the workspace must not create a separate default-off selection")
        }
    }

    @MainActor
    func testNewSessionCancelsStaleVisualSetupAndRestoresOnlyMicrophone() async {
        let viewModel = makeSyntheticViewModel()
        viewModel.applyVisualPreviewSelection(cameraEnabled: true, screenEnabled: true)
        viewModel.visualPreviewSource = .screen
        viewModel.visualSelectionUsesScreenOnlyFallback = true
        viewModel.capturePreviewStatusMessage = "正在准备旧屏幕预览"
        viewModel.inputMode = .mixed
        let generation = viewModel.stateQueue.sync { viewModel.visualPreviewGeneration }
        let setupStarted = expectation(description: "old visual setup is pending")
        let gate = AsyncStream<Void>.makeStream()
        var oldSetupResumed = false
        let setup = Task { @MainActor in
            setupStarted.fulfill()
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            oldSetupResumed = true
            guard viewModel.isCurrentVisualPreview(generation) else { return }
            viewModel.visualPreviewSource = .screen
            viewModel.capturePreviewStatusMessage = "旧预览已完成"
        }
        viewModel.visualPreviewSetupTask = setup
        await fulfillment(of: [setupStarted], timeout: 1)

        XCTAssertTrue(viewModel.resetForNewSession())

        XCTAssertTrue(setup.isCancelled)
        XCTAssertFalse(viewModel.isCurrentVisualPreview(generation))
        XCTAssertNil(viewModel.visualPreviewSetupTask)
        XCTAssertEqual(viewModel.visualPreviewSource, .none)
        XCTAssertFalse(viewModel.visualSelectionUsesScreenOnlyFallback)
        XCTAssertNil(viewModel.capturePreviewStatusMessage)
        XCTAssertEqual(enabledInputs(in: LiveWorkspaceView(viewModel: viewModel)), ["mic"])
        gate.continuation.yield(())
        gate.continuation.finish()
        await setup.value
        XCTAssertTrue(oldSetupResumed)
        XCTAssertEqual(viewModel.visualPreviewSource, .none)
        XCTAssertNil(viewModel.capturePreviewStatusMessage, "A late preview completion must not revive the old hint")
    }

    @MainActor
    func testStoppingPreviewClearsItsSelectionAndHintWithoutStartingDevices() {
        let viewModel = makeSyntheticViewModel()
        viewModel.applyVisualPreviewSelection(cameraEnabled: true, screenEnabled: true)
        viewModel.visualSelectionUsesScreenOnlyFallback = true
        let generation = viewModel.stateQueue.sync { viewModel.visualPreviewGeneration }

        viewModel.stopCameraPreview()

        XCTAssertEqual(viewModel.visualPreviewSource, .none)
        XCTAssertFalse(viewModel.visualSelectionUsesScreenOnlyFallback)
        XCTAssertNil(viewModel.capturePreviewStatusMessage)
        XCTAssertFalse(viewModel.isCurrentVisualPreview(generation))
        XCTAssertEqual(enabledInputs(in: LiveWorkspaceView(viewModel: viewModel)), ["mic"])
    }

    @MainActor
    func testAudioToggleBindingPreservesTheVisualFallbackAndItsStatus() throws {
        let viewModel = makeSyntheticViewModel()
        viewModel.applyVisualPreviewSelection(cameraEnabled: true, screenEnabled: true)
        viewModel.visualPreviewSource = .screen
        viewModel.visualSelectionUsesScreenOnlyFallback = true
        let status = "当前仅保存屏幕；摄像头不会写入本次 Record。"
        viewModel.capturePreviewStatusMessage = status
        let workspace = LiveWorkspaceView(viewModel: viewModel)
        var inputs = workspace.sourceToggles.wrappedValue
        let systemIndex = try XCTUnwrap(inputs.firstIndex { $0.id == "system" })
        inputs[systemIndex].isEnabled = true

        workspace.sourceToggles.wrappedValue = inputs

        XCTAssertEqual(viewModel.inputMode, .mixed)
        XCTAssertEqual(viewModel.visualPreviewSource, .screen)
        XCTAssertEqual(viewModel.currentPresentationCaptureStatus(), .screenOnlyFallback)
        XCTAssertEqual(viewModel.capturePreviewStatusMessage, status)
        XCTAssertEqual(enabledVisualInputs(in: workspace), ["camera", "screen"])
    }

    private func enabledInputs(in workspace: LiveWorkspaceView) -> Set<String> {
        Set(workspace.sourceToggles.wrappedValue.filter(\.isEnabled).map(\.id))
    }

    private func enabledVisualInputs(in workspace: LiveWorkspaceView) -> Set<String> {
        enabledInputs(in: workspace).intersection(["camera", "screen"])
    }

    private func makeSyntheticViewModel() -> LiveSessionViewModel {
        let previousMode = ProcessInfo.processInfo.environment["INSIGHTKIT_UI_TEST_MODE"]
        setenv("INSIGHTKIT_UI_TEST_MODE", "1", 1)
        addTeardownBlock {
            if let previousMode {
                setenv("INSIGHTKIT_UI_TEST_MODE", previousMode, 1)
            } else {
                unsetenv("INSIGHTKIT_UI_TEST_MODE")
            }
        }
        return LiveSessionViewModel(rpcClient: RPCClientMock(), analyticsSubmit: { _ in })
    }
}
