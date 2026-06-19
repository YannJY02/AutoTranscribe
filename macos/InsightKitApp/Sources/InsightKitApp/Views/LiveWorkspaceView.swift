import SwiftUI

struct LiveWorkspaceView: View {
    @ObservedObject var viewModel: LiveSessionViewModel

    // Source toggles for the Green Room
    @State private var sourceToggles: [SourceToggleItem] = [
        SourceToggleItem(id: "mic", icon: "mic.fill", label: "麦克风", isEnabled: true),
        SourceToggleItem(id: "camera", icon: "video.fill", label: "摄像头", isEnabled: false),
        SourceToggleItem(id: "screen", icon: "rectangle.on.rectangle", label: "屏幕", isEnabled: false),
        SourceToggleItem(id: "system", icon: "speaker.wave.2.fill", label: "系统音频", isEnabled: false),
    ]

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
        .onChange(of: cameraToggleEnabled) { _, isEnabled in
            if isEnabled {
                viewModel.startCameraPreview()
            } else {
                viewModel.stopCameraPreview()
            }
        }
    }

    private var cameraToggleEnabled: Bool {
        sourceToggles.first(where: { $0.id == "camera" })?.isEnabled ?? false
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        ChapterSidebarView(dataSource: viewModel)
    }

    // MARK: - Center Panel

    private var centerPanel: some View {
        LiveCenterView(
            dataSource: viewModel,
            sources: $sourceToggles,
            onDeviceSelect: { id in
                viewModel.selectedSystemSourceID = id
            }
        )
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        TimestampNotesEditor(dataSource: viewModel)
    }
}
