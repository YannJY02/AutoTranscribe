import SwiftUI

struct ImportWorkspaceView: View {
    @ObservedObject var viewModel: ImportSessionViewModel

    var body: some View {
        SessionShell(
            left: leftPanel,
            center: centerPanel,
            right: rightPanel
        )
        .background(InsightTheme.canvas)
    }

    // MARK: - Left Panel: Chapter Sidebar

    private var leftPanel: some View {
        ChapterSidebarView(dataSource: viewModel)
    }

    // MARK: - Center Panel: Import Center

    private var centerPanel: some View {
        ImportCenterView(
            dataSource: viewModel,
            importViewModel: viewModel,
            onFilePicked: { url in
                viewModel.importFile(url: url)
            }
        )
    }

    // MARK: - Right Panel: Notes Editor

    private var rightPanel: some View {
        TimestampNotesEditor(dataSource: viewModel)
    }
}
