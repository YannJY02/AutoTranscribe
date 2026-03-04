import SwiftUI

struct LiveWorkspaceView: View {
    @ObservedObject var viewModel: LiveSessionViewModel

    var body: some View {
        HSplitView {
            TranscriptStreamView(
                searchText: $viewModel.searchText,
                selectedEvidence: $viewModel.selectedEvidence,
                segments: viewModel.transcriptSegments
            )
            .frame(minWidth: viewModel.focusMode ? 280 : 320, maxWidth: 420)

            InsightWorkbenchView(
                selectedTab: $viewModel.selectedTab,
                state: viewModel.workbench,
                focusMode: viewModel.focusMode,
                onEvidenceSelected: { range in
                    viewModel.selectEvidence(range)
                }
            )
            .frame(minWidth: 560)

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
                .frame(minWidth: 340, maxWidth: 420)
            }
        }
        .background(viewModel.readingMode ? InsightTheme.background : Color.white)
    }
}
