import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var coordinator: WorkflowCoordinator
    @State private var isImportPickerPresented = false

    init(coordinator: WorkflowCoordinator = WorkflowCoordinator()) {
        self.coordinator = coordinator
    }

    private var activeBanner: BannerMessage? {
        if let banner = coordinator.bannerMessage {
            return banner
        }

        if coordinator.route == .live, let message = coordinator.liveViewModel.errorMessage, !message.isEmpty {
            let mapped = userFacingProviderMessage(message)
            let level: BannerLevel = coordinator.liveViewModel.analysisRuntimeState == .ready ? .error : .warning
            return BannerMessage(
                level: level,
                title: "实时语音总结异常",
                message: mapped,
                actionTitle: "打开设置",
                actionRoute: "open_settings"
            )
        }

        if coordinator.route == .transcription, let inline = coordinator.transcriptionViewModel.inlineError {
            let mapped = userFacingProviderMessage(inline.message)
            return BannerMessage(
                level: .warning,
                title: "转写服务提醒",
                message: mapped,
                actionTitle: "打开设置",
                actionRoute: "open_settings"
            )
        }

        return nil
    }

    var body: some View {
        Group {
            switch coordinator.route {
            case .home:
                WorkflowHomeView(
                    onOpenLive: {
                        coordinator.openLive()
                    },
                    onOpenTranscription: {
                        coordinator.openTranscription()
                    },
                    statusSummary: homeStatusSummary
                )
            case .live:
                LiveWorkspaceView(viewModel: coordinator.liveViewModel)
            case .transcription:
                TranscriptionWorkspaceView(
                    viewModel: coordinator.transcriptionViewModel,
                    onImportRequest: {
                        isImportPickerPresented = true
                    }
                )
            }
        }
        .sheet(isPresented: $coordinator.liveViewModel.isSystemAudioPickerPresented) {
            SystemAudioPickerSheet(
                sources: coordinator.liveViewModel.systemAudioSources,
                selectedID: coordinator.liveViewModel.selectedSystemSourceID,
                onReload: {
                    coordinator.liveViewModel.reloadSystemAudioSources()
                },
                onSelect: { sourceID in
                    coordinator.liveViewModel.selectSystemSource(sourceID)
                },
                onConfirm: {
                    coordinator.liveViewModel.isSystemAudioPickerPresented = false
                    coordinator.clearBanner()
                },
                onCancel: {
                    coordinator.liveViewModel.isSystemAudioPickerPresented = false
                    coordinator.clearBanner()
                }
            )
        }
        .fileImporter(
            isPresented: $isImportPickerPresented,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    coordinator.transcriptionViewModel.importFile(path: url.path, title: url.deletingPathExtension().lastPathComponent)
                }
                coordinator.openTranscription()
            case .failure(let error):
                coordinator.publishInfoBanner("导入文件失败：\(error.localizedDescription)")
            }
        }
        .toolbar {
            toolbarContent
        }
        .safeAreaInset(edge: .top) {
            if let banner = activeBanner {
                bannerBar(banner)
            } else if coordinator.route == .live, coordinator.liveViewModel.permissionState == .denied {
                permissionRecoveryBar
            }
        }
        .safeAreaInset(edge: .bottom) {
            if coordinator.route != .home {
                BottomStatusBarView(
                    mode: $coordinator.bottomPanelMode,
                    payload: coordinator.bottomStatusPayload
                )
            }
        }
        .onAppear {
            coordinator.refreshSidecarCapabilities()
            coordinator.liveViewModel.reloadSystemAudioSources()
            coordinator.liveViewModel.refreshSidecarStatus()
            if coordinator.route == .transcription, coordinator.supportsTranscriptionFlow {
                coordinator.transcriptionViewModel.beginMonitoring()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if coordinator.route != .home {
                Button("返回首页") {
                    coordinator.openHome()
                }
            }
        }

        switch coordinator.route {
        case .home:
            ToolbarItemGroup(placement: .primaryAction) {
                Button("实时语音总结") {
                    coordinator.openLive()
                }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.accent)

                Button("转写总结") {
                    coordinator.openTranscription()
                }
                .buttonStyle(.bordered)
            }

        case .live:
            ToolbarItemGroup(placement: .primaryAction) {
                switch coordinator.livePhase {
                case .livePreparing:
                    Picker("输入", selection: $coordinator.liveViewModel.inputMode) {
                        ForEach(AudioInputMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .disabled(!coordinator.liveViewModel.canChangeInputMode)

                    Button(systemAudioSourceTitle) {
                        openSystemAudioPicker()
                    }

                    Button("开始直播洞察") {
                        coordinator.startLiveSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(InsightTheme.accent)
                    .disabled(!coordinator.canStartLive)

                case .liveRunning:
                    Button("停止") {
                        coordinator.stopLiveSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(InsightTheme.accent)
                    .disabled(!coordinator.canStopLive)

                    Button("系统音频源") {
                        coordinator.publishInfoBanner("直播进行中不可切换音频源，请先停止后再选择。")
                    }
                    .buttonStyle(.bordered)

                case .livePostSession:
                    Button("生成定稿洞察") {
                        coordinator.liveViewModel.buildFinalInsight()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(InsightTheme.accent)
                    .disabled(!coordinator.canBuildLiveFinal)

                    Button("导出 Markdown") {
                        coordinator.liveViewModel.exportDocument(format: "markdown")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!coordinator.canExportLive)

                    Button("新建会话") {
                        coordinator.resetLiveSession()
                    }
                    .buttonStyle(.bordered)
                case .transcriptionIntake, .transcriptionProcessing, .transcriptionFinalize:
                    EmptyView()
                }

                Menu("更多操作") {
                    Toggle("阅读模式", isOn: $coordinator.liveViewModel.readingMode)
                    Toggle("聚焦模式", isOn: $coordinator.liveViewModel.focusMode)
                    Toggle("显示执行面板", isOn: $coordinator.liveViewModel.isExecutionPanelVisible)
                    Divider()
                    Button("刷新侧车状态") {
                        coordinator.liveViewModel.refreshSidecarStatus()
                        coordinator.refreshSidecarCapabilities()
                    }
                }
            }

        case .transcription:
            ToolbarItemGroup(placement: .primaryAction) {
                switch coordinator.transcriptionPhase {
                case .transcriptionIntake:
                    Button("导入文件") {
                        isImportPickerPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(InsightTheme.accent)

                    Button(coordinator.transcriptionViewModel.watcherState.isRunning ? "停止监听" : "开始监听") {
                        toggleTranscriptionWatcher()
                    }
                    .buttonStyle(.bordered)

                case .transcriptionProcessing:
                    Button("导入文件") {
                        isImportPickerPresented = true
                    }
                    .buttonStyle(.bordered)

                    Button(coordinator.transcriptionViewModel.watcherState.isRunning ? "停止监听" : "开始监听") {
                        toggleTranscriptionWatcher()
                    }
                    .buttonStyle(.bordered)

                    Button("刷新状态") {
                        coordinator.transcriptionViewModel.refreshStatus()
                    }
                    .buttonStyle(.bordered)

                case .transcriptionFinalize:
                    Button("导入文件") {
                        isImportPickerPresented = true
                    }
                    .buttonStyle(.bordered)

                    Button("生成定稿洞察") {
                        coordinator.transcriptionViewModel.buildFinalInsight()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(InsightTheme.accent)
                    .disabled(!coordinator.canBuildTranscriptionFinal)

                    Button("导出 Markdown") {
                        coordinator.transcriptionViewModel.exportDocument(format: "markdown")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!coordinator.canExportTranscription)
                case .livePreparing, .liveRunning, .livePostSession:
                    EmptyView()
                }

                Menu("更多操作") {
                    Toggle("阅读模式", isOn: $coordinator.transcriptionViewModel.readingMode)
                    Toggle("聚焦模式", isOn: $coordinator.transcriptionViewModel.focusMode)
                    Toggle("显示执行面板", isOn: $coordinator.transcriptionViewModel.isExecutionPanelVisible)
                    Divider()
                    Button("刷新侧车状态") {
                        coordinator.transcriptionViewModel.refreshStatus()
                        coordinator.refreshSidecarCapabilities()
                    }
                }
            }
        }
    }

    private var systemAudioSourceTitle: String {
        guard
            let selected = coordinator.liveViewModel.selectedSystemSourceID,
            let source = coordinator.liveViewModel.systemAudioSources.first(where: { $0.id == selected })
        else {
            return "系统音频源"
        }
        return source.title
    }

    private var homeStatusSummary: String {
        let live = coordinator.liveViewModel.captureState.label
        let transcription = coordinator.transcriptionPhase.rawValue
        return "最近状态：实时流 \(live) · 转写流 \(transcription)"
    }

    private func openSystemAudioPicker() {
        guard coordinator.supportsSystemAudioPicker else {
            coordinator.publishInfoBanner("当前版本未启用系统音频采集能力。请在设置中执行“一键测试服务”。")
            return
        }
        coordinator.liveViewModel.reloadSystemAudioSources()
        coordinator.liveViewModel.isSystemAudioPickerPresented = true
    }

    private func toggleTranscriptionWatcher() {
        if coordinator.transcriptionViewModel.watcherState.isRunning {
            coordinator.transcriptionViewModel.stopWatcher()
            return
        }
        let dirs = coordinator.transcriptionViewModel.watcherState.dirs.isEmpty
            ? [
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path,
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path,
            ]
            : coordinator.transcriptionViewModel.watcherState.dirs
        coordinator.transcriptionViewModel.startWatcher(dirs: dirs)
    }

    private var permissionRecoveryBar: some View {
        HStack(spacing: 10) {
            Text("权限未就绪：请在系统设置中开启麦克风与屏幕录制权限。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InsightTheme.textSecondary)
            Spacer()
            Button("麦克风设置") {
                coordinator.liveViewModel.openMicrophonePrivacySettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("屏幕录制设置") {
                coordinator.liveViewModel.openScreenRecordingSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(InsightTheme.panel)
        .overlay(
            Rectangle()
                .fill(InsightTheme.border.opacity(0.55))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func bannerBar(_ banner: BannerMessage) -> some View {
        let palette = bannerPalette(for: banner.level)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(InsightTheme.textPrimary)
                Text(banner.message)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(InsightTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            if !banner.actionTitle.isEmpty {
                Button(banner.actionTitle) {
                    coordinator.performBannerAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button("关闭") {
                coordinator.clearBanner()
                coordinator.liveViewModel.clearError()
                coordinator.transcriptionViewModel.clearError()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.background)
        .overlay(
            Rectangle()
                .fill(palette.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func bannerPalette(for level: BannerLevel) -> (background: Color, border: Color) {
        switch level {
        case .info:
            return (InsightTheme.panel, InsightTheme.border.opacity(0.55))
        case .warning:
            return (InsightTheme.warningSurface, InsightTheme.warningBorder)
        case .error:
            return (InsightTheme.errorSurface, InsightTheme.errorBorder)
        }
    }

    private func userFacingProviderMessage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("authentication fails") || lower.contains("governor") || lower.contains("http 401") {
            return "智能分析服务鉴权失败（401）。请在设置中检查 API Key、模型名称，并点击“检查可用性”。"
        }
        if lower.contains("model not exist") || lower.contains("invalidendpointormodel.notfound") || lower.contains("http 404") {
            return "模型名称不可用。请在设置中核对模型名称（豆包可填写模型名称或接入点 ID）后重试。"
        }
        if lower.contains("missing api key") {
            return "当前智能分析服务未配置 API Key。请在设置中填写后重试。"
        }
        return raw
    }
}

#Preview {
    ContentView()
}
