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
    }

    // MARK: - Left Panel: Transcript Stream (legacy) — Step 5c replaces with ChapterSidebarView

    private var leftPanel: some View {
        TranscriptStreamView(
            searchText: $viewModel.searchText,
            selectedEvidence: $viewModel.selectedEvidence,
            segments: viewModel.transcriptSegments
        )
    }

    // MARK: - Center Panel: Workbench (legacy) — Step 5c replaces with LiveCenterView

    private var centerPanel: some View {
        InsightWorkbenchView(
            selectedTab: $viewModel.selectedTab,
            state: viewModel.workbench,
            focusMode: viewModel.focusMode,
            onEvidenceSelected: { range in
                viewModel.selectEvidence(range)
            }
        )
    }

    // MARK: - Right Panel: Execution Panel (legacy) — Step 5c replaces with TimestampNotesEditor

    @ViewBuilder
    private var rightPanel: some View {
        if viewModel.isExecutionPanelVisible {
            ExecutionPanelView(
                actions: $viewModel.actionItems,
                onStatusChange: { id, status in
                    viewModel.updateActionStatus(id: id, status: status)
                },
                onOwnerChange: { id, owner in
                    viewModel.updateActionOwner(id: id, owner: owner)
                },
                onDueAtChange: { id, dueAt in
                    viewModel.updateActionDueAt(id: id, dueAt: dueAt)
                }
            )
        } else {
            VStack {
                Spacer()
                Text("执行面板已隐藏")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                Spacer()
            }
        }
    }
}
