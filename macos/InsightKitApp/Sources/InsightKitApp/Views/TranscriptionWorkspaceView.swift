import SwiftUI

struct TranscriptionWorkspaceView: View {
    @ObservedObject var viewModel: TranscriptionSessionViewModel
    let onImportRequest: () -> Void
    @State private var transcriptAnalyticsKey = UUID().uuidString.lowercased()

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("转写总结流")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(InsightTheme.textPrimary)

                HStack(spacing: 8) {
                    Button("导入文件") {
                        onImportRequest()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(InsightTheme.accent)

                    Button(viewModel.watcherState.isRunning ? "停止监听" : "开始监听") {
                        if viewModel.watcherState.isRunning {
                            viewModel.stopWatcher()
                        } else {
                            let dirs = viewModel.watcherState.dirs.isEmpty
                                ? [
                                    (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")).path,
                                    (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")).path,
                                ]
                                : viewModel.watcherState.dirs
                            viewModel.startWatcher(dirs: dirs)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("刷新") {
                        viewModel.refreshStatus()
                    }
                    .buttonStyle(.bordered)
                }

                watcherPanel

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if viewModel.jobs.isEmpty {
                            Text("暂无转写任务。可导入音视频或开启目录监听。")
                                .font(.system(size: 13))
                                .foregroundStyle(InsightTheme.textSecondary)
                                .padding(.top, 8)
                        } else {
                            ForEach(viewModel.jobs) { job in
                                jobCard(job)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if !viewModel.transcriptSegments.isEmpty {
                    let analyticsContext = viewModel.transcriptAnalyticsContext()
                    Divider()
                    TranscriptStreamView(
                        searchText: $viewModel.searchText,
                        selectedEvidence: $viewModel.selectedEvidence,
                        segments: viewModel.transcriptSegments,
                        analyticsContext: analyticsContext
                    )
                    .id(transcriptAnalyticsKey)
                    .onAppear {
                        guard let analyticsContext else { return }
                        ProductAnalytics.submit { $0.registerSearchContext(analyticsContext) }
                    }
                }
            }
            .padding(18)
            .background(InsightTheme.background)
            .frame(minWidth: 340, maxWidth: 420)

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
        .onChange(of: viewModel.currentMeetingID) { _, _ in
            transcriptAnalyticsKey = UUID().uuidString.lowercased()
        }
    }

    private var watcherPanel: some View {
        HStack(spacing: 8) {
            Text(viewModel.watcherState.isRunning ? "监听中" : "未监听")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.watcherState.isRunning ? InsightTheme.accent : InsightTheme.textSecondary)
            Text("队列 \(viewModel.watcherState.queueSize)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InsightTheme.textSecondary)
            if !viewModel.watcherState.dirs.isEmpty {
                Text(viewModel.watcherState.dirs.joined(separator: " · "))
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(InsightTheme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(InsightTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(InsightTheme.border.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func jobCard(_ job: TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.title.isEmpty ? URL(fileURLWithPath: job.sourcePath).lastPathComponent : job.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(InsightTheme.textPrimary)
            Text(stateLabel(job.state))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InsightTheme.textSecondary)

            ProgressView(value: Double(job.progress), total: 100)
                .progressViewStyle(.linear)
                .tint(InsightTheme.accent)

            HStack(spacing: 8) {
                Text(job.stage)
                    .font(.system(size: 11))
                    .foregroundStyle(InsightTheme.textSecondary)
                Spacer()
                if job.state == .running || job.state == .queued {
                    Button("取消") {
                        viewModel.cancelJob(jobID: job.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InsightTheme.accent)
                }
            }

            if !job.error.isEmpty {
                Text(job.error)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.75))
            }
        }
        .quietCard()
    }

    private func stateLabel(_ state: TranscriptionJobState) -> String {
        switch state {
        case .queued:
            return "排队中"
        case .running:
            return "处理中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .pausedByLive:
            return "已暂停（实时优先）"
        case .cancelled:
            return "已取消"
        }
    }
}
