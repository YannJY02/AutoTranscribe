import SwiftUI

struct LiveWorkspaceView: View {
    @ObservedObject var viewModel: LiveSessionViewModel
    var onSystemAudioSourceSelect: (() -> Void)?

    @State private var cameraToggleEnabled = false
    @State private var screenToggleEnabled = false

    private var sourceToggles: Binding<[SourceToggleItem]> {
        Binding(
            get: {
                let microphoneEnabled = viewModel.inputMode != .systemAudio
                let systemAudioEnabled = viewModel.inputMode.requiresSystemAudioSource
                return [
                    SourceToggleItem(
                        id: "mic", icon: "mic.fill", label: "麦克风", isEnabled: microphoneEnabled,
                        disabledReason: audioToggleDisabledReason(isEnabled: microphoneEnabled)
                    ),
                    SourceToggleItem(id: "camera", icon: "video.fill", label: "摄像头", isEnabled: cameraToggleEnabled),
                    SourceToggleItem(id: "screen", icon: "rectangle.on.rectangle", label: "屏幕", isEnabled: screenToggleEnabled),
                    SourceToggleItem(
                        id: "system", icon: "speaker.wave.2.fill", label: "系统音频", isEnabled: systemAudioEnabled,
                        disabledReason: audioToggleDisabledReason(isEnabled: systemAudioEnabled)
                    ),
                ]
            },
            set: { sources in
                if let microphone = sources.first(where: { $0.id == "mic" }),
                   let systemAudio = sources.first(where: { $0.id == "system" }) {
                    viewModel.setAudioInputSources(
                        microphoneEnabled: microphone.isEnabled,
                        systemAudioEnabled: systemAudio.isEnabled
                    )
                }
                if let camera = sources.first(where: { $0.id == "camera" }) {
                    cameraToggleEnabled = camera.isEnabled
                }
                if let screen = sources.first(where: { $0.id == "screen" }) {
                    screenToggleEnabled = screen.isEnabled
                }
            }
        )
    }

    var body: some View {
        SessionShell(
            left: leftPanel,
            center: centerPanel,
            right: rightPanel
        )
        .background(viewModel.readingMode ? InsightTheme.canvas : InsightTheme.surface)
        .overlay(alignment: .topLeading) {
            Text("实时转写工作区")
                .font(.caption2)
                .foregroundStyle(.clear)
                .accessibilityIdentifier("live_workspace")
        }
        .onChange(of: cameraToggleEnabled) { _, _ in
            syncVisualPreviewSelection()
        }
        .onChange(of: screenToggleEnabled) { _, _ in
            syncVisualPreviewSelection()
        }
    }

    private func audioToggleDisabledReason(isEnabled: Bool) -> String? {
        if !viewModel.canChangeInputMode {
            return "录制中无法更改音频输入。"
        }
        if isEnabled && viewModel.inputMode != .mixed {
            return "至少保留一个音频来源。"
        }
        return nil
    }

    private func syncVisualPreviewSelection() {
        viewModel.applyVisualPreviewSelection(
            cameraEnabled: cameraToggleEnabled,
            screenEnabled: screenToggleEnabled
        )
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        ChapterSidebarView(dataSource: viewModel)
    }

    // MARK: - Center Panel

    private var centerPanel: some View {
        LiveCenterView(
            dataSource: viewModel,
            sources: sourceToggles,
            onSystemAudioSourceSelect: onSystemAudioSourceSelect
        )
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        TimestampNotesEditor(dataSource: viewModel)
    }
}
