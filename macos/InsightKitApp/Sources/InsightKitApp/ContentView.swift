import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var coordinator: WorkflowCoordinator

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
        contentWithBottomStatusBar
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
        .onAppear {
            coordinator.refreshSidecarCapabilities()
            coordinator.liveViewModel.reloadSystemAudioSources()
            coordinator.liveViewModel.refreshSidecarStatus()
            coordinator.recordsService.refreshIndexAsync()
            if coordinator.route == .transcription, coordinator.supportsTranscriptionFlow {
                coordinator.transcriptionViewModel.beginMonitoring()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            coordinator.shutdown()
        }
        .onOpenURL { url in
            coordinator.handleIncomingURL(url)
        }
    }

    @ViewBuilder
    private var contentWithBottomStatusBar: some View {
        if BottomStatusBarLayout.showsBottomStatusBar(for: coordinator.route) {
            VStack(spacing: 0) {
                routeContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                BottomStatusBarView(
                    mode: $coordinator.bottomPanelMode,
                    payload: coordinator.bottomStatusPayload,
                    onAction: { actionRoute in
                        coordinator.performBannerAction(for: actionRoute)
                    }
                )
                .frame(height: BottomStatusBarLayout.reservedHeight(
                    for: coordinator.route,
                    mode: coordinator.bottomPanelMode
                ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            routeContent
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch coordinator.route {
        case .home:
            WorkflowHomeView(
                onOpenLive: {
                    coordinator.openLive()
                },
                onOpenTranscription: {
                    coordinator.openTranscription()
                },
                onOpenImport: {
                    coordinator.openImport()
                },
                onOpenRecords: {
                    coordinator.openRecords()
                },
                onOpenSettings: {
                    coordinator.openSettings()
                },
                statusSummary: homeStatusSummary,
                recentRecords: Array(coordinator.recordsService.records.prefix(3))
            )
        case .live:
            LiveWorkspaceView(viewModel: coordinator.liveViewModel)
                .accessibilityIdentifier("live_workspace")
        case .transcription:
            TranscriptionWorkspaceView(
                viewModel: coordinator.transcriptionViewModel,
                onImportRequest: {
                    openTranscriptionImportPicker()
                }
            )
        case .importMedia:
            ImportWorkspaceView(viewModel: coordinator.importViewModel)
                .accessibilityIdentifier("import_workspace")
        case .records:
            RecordsView(
                recordsService: coordinator.recordsService,
                recordsNavigation: coordinator.recordsNavigation,
                transcriptRecoveryService: coordinator.liveViewModel.transcriptRecoveryService
            )
            .accessibilityIdentifier("records_view")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if coordinator.primaryNavigationAction != .none {
                Button(coordinator.primaryNavigationAction.title) {
                    coordinator.performPrimaryNavigationAction()
                }
                .accessibilityIdentifier(coordinator.primaryNavigationAction.accessibilityID)
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
                }
            }

        case .transcription:
            ToolbarItemGroup(placement: .primaryAction) {
                switch coordinator.transcriptionPhase {
                case .transcriptionIntake:
                    Button("导入文件") {
                        openTranscriptionImportPicker()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(InsightTheme.accent)

                    Button(coordinator.transcriptionViewModel.watcherState.isRunning ? "停止监听" : "开始监听") {
                        toggleTranscriptionWatcher()
                    }
                    .buttonStyle(.bordered)

                case .transcriptionProcessing:
                    Button("导入文件") {
                        openTranscriptionImportPicker()
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
                        openTranscriptionImportPicker()
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

                    Button("导出 PDF") {
                        coordinator.transcriptionViewModel.exportDocument(format: "pdf")
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

        case .importMedia, .records:
            ToolbarItemGroup(placement: .primaryAction) {
                EmptyView()
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

    private func openTranscriptionImportPicker() {
        let panel = NSOpenPanel()
        SupportedMediaTypes.configureOpenPanel(panel, allowsMultipleSelection: true)
        guard panel.runModal() == .OK else { return }
        let unsupported = panel.urls.filter { !SupportedMediaTypes.isSupportedFile($0) }
        if !unsupported.isEmpty {
            let names = unsupported.map(\.lastPathComponent).joined(separator: "、")
            coordinator.publishInfoBanner("已跳过不支持的文件格式：\(names)。支持 mp3、m4a、wav、mp4、mov、mkv。")
        }
        let supported = panel.urls.filter(SupportedMediaTypes.isSupportedFile)
        guard !supported.isEmpty else { return }
        for url in supported {
            coordinator.transcriptionViewModel.importFile(path: url.path, title: url.deletingPathExtension().lastPathComponent)
        }
        coordinator.openTranscription()
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
        .background(InsightTheme.surface)
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
                    coordinator.performBannerAction(for: banner.actionRoute)
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
            return (InsightTheme.surface, InsightTheme.border.opacity(0.55))
        case .warning:
            return (InsightTheme.warningSurface, InsightTheme.warningBorder)
        case .error:
            return (InsightTheme.errorSurface, InsightTheme.errorBorder)
        }
    }

    private func userFacingProviderMessage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let sanitized = AnalysisProviderErrorPresentation.sanitizedMessage(for: raw) {
            return sanitized
        }
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
