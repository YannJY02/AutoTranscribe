import AVFoundation
import CoreGraphics
import SwiftUI

struct SettingsView: View {
    private struct VendorDraft {
        var baseURL: String
        var modelID: String
        var useCustomModel: Bool
    }

    @ObservedObject private var configStore = AppConfigStore.shared
    @ObservedObject private var coordinator: WorkflowCoordinator
    private let recordsService = RecordsIndexService()

    init(coordinator: WorkflowCoordinator) {
        self.coordinator = coordinator
    }

    @State private var selectedVendor: ProviderVendor = .openai
    @State private var loadedVendor: ProviderVendor = .openai
    @State private var vendorBaseURL: String = ""
    @State private var vendorModelID: String = ""
    @State private var vendorAPIKey: String = ""
    @State private var vendorDrafts: [ProviderVendor: VendorDraft] = [:]

    // Controls whether the model field is freetext (custom) or picker
    @State private var vendorUseCustomModel: Bool = false

    // Guard: suppress onChange auto-save while we programmatically load fields
    @State private var isLoadingVendorFields: Bool = false

    @State private var asrModel: String = ""
    @State private var asrEngine: LocalASREngine = .whisper
    @State private var asrModelDir: String = ""
    @State private var vadEnabled: Bool = true
    @State private var diarizationEnabled: Bool = true
    @State private var strictMode: Bool = true
    @State private var appleSpeechPrototypeEnabled: Bool = false

    @State private var useCustomWhisperModel: Bool = false
    @State private var useCustomFunasrModel: Bool = false
    @State private var useCustomQwenModel: Bool = false

    @State private var savedFeedback: Bool = false
    @State private var savedFeedbackTask: Task<Void, Never>? = nil

    @State private var statusMessage: String = ""
    @State private var isRunningTask = false
    @State private var providerProbeResult: ProviderProbeResult?
    @State private var providerProbeAt: Date?
    @State private var lastAppliedConfigRevision: Int = -1
    @State private var asrRuntimeSnapshot: ASRRuntimeStatus?
    @State private var asrRuntimeUpdatedAt: Date?
    @State private var appleSpeechRuntimeStatus: AppleSpeechRuntimeStatus = .resolve(
        sdkSupportsAppleSpeech: false,
        localeIdentifier: "zh-Hans",
        localeSupported: false,
        assetState: nil
    )
    @State private var appleSpeechRuntimeUpdatedAt: Date?

    /// Fix 4: Reuse shared instances to avoid spawning Python subprocesses
    /// every time the settings sheet opens.
    private static let sharedRPC: InsightRPCClient = {
        var config = InsightRPCClient.Config.default()
        config.providerProbeTimeoutSec = max(config.providerProbeTimeoutSec, 30)
        return InsightRPCClient(config: config)
    }()
    private static let sharedSidecarManager = SidecarManager()
    private var rpc: InsightRPCClient { Self.sharedRPC }
    private var sidecarManager: SidecarManager { Self.sharedSidecarManager }

    static func shutdownSharedSidecar() {
        sharedSidecarManager.stop()
    }

    static func shouldProbeCloudAnalysis(for mode: AnalysisMode) -> Bool {
        mode == .cloud
    }

    // MARK: - Computed helpers

    private var currentPresets: [String] {
        AppConfigStore.modelPresets(for: selectedVendor)
    }

    private var isCustomModel: Bool {
        vendorUseCustomModel || !currentPresets.contains(vendorModelID)
    }

    private var vendorModelLabel: String {
        selectedVendor == .doubao ? "模型名称（或接入点 ID）" : "模型名称"
    }

    private var vendorModelPlaceholder: String {
        selectedVendor == .doubao ? "输入模型名称或接入点 ID" : "输入模型名称"
    }

    private var selectedVendorKeyWarning: String? {
        validateAPIKeyFormat(vendor: loadedVendor, key: configStore.apiKeyValue(for: loadedVendor))
    }

    // MARK: - Body

    var body: some View {
        Form {
            vendorSection
            asrSection
            storageSection

            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("术语说明") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时语音总结：边说边转写，边生成洞察。")
                    Text("转写总结：导入已录好的音视频后生成定稿。")
                    Text("洞察：AI 从转写中提炼会话总览、高光洞察、决策账本和执行清单。")
                    Text("语音识别方案：本地转写引擎（Whisper/FunASR）。")
                    Text("智能分析服务：通过 API 生成洞察内容。")
                    Text("一键修复语音识别：自动安装本地依赖并准备模型。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 600, idealWidth: 680)
        .onAppear {
            syncFromStore()
            Task {
                try? await refreshASRRuntimeStatus()
                await refreshAppleSpeechRuntimeStatus()
            }
        }
        .onDisappear {
            flushVendorToStore()
            saveCurrentVendorAPIKey()
        }
    }

    // MARK: - Vendor Section

    @ViewBuilder
    private var vendorSection: some View {
        Section("智能分析服务") {
            Picker(
                "分析方式",
                selection: Binding(
                    get: { configStore.config.analysis.mode },
                    set: { selectAnalysisMode($0) }
                )
            ) {
                ForEach(AnalysisMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("settings_analysis_mode_picker")
            .disabled(coordinator.hasActiveSidecarWork || isRunningTask)
            Text(configStore.config.analysis.mode == .local
                 ? "Smart Minutes 在设备上生成，不需要 API Key 或网络连接。"
                 : "Smart Minutes 使用下方选择的云端服务；语音识别引擎单独配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if coordinator.hasActiveSidecarWork {
                Text("当前录制或导入任务完成后才能切换分析方式，避免中断正在处理的记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Vendor picker
            Picker("服务提供商", selection: $selectedVendor) {
                ForEach(ProviderVendor.allCases) { vendor in
                    Text(vendor.displayName).tag(vendor)
                }
            }
            .disabled(configStore.config.analysis.mode == .local)
            .onChange(of: selectedVendor) { oldVendor, newVendor in
                guard !isLoadingVendorFields else { return }
                switchVendor(from: oldVendor, to: newVendor)
            }

            // Base URL — readonly preview + edit toggle
            LabeledContent("服务地址（高级）") {
                TextField("", text: $vendorBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vendorBaseURL) { _, _ in
                        guard !isLoadingVendorFields else { return }
                        flushVendorToStore()
                    }
            }

            // Model: Picker for presets, TextField for custom
            if vendorUseCustomModel || currentPresets.isEmpty {
                LabeledContent(vendorModelLabel) {
                    HStack {
                        TextField(vendorModelPlaceholder, text: $vendorModelID)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: vendorModelID) { _, _ in
                                guard !isLoadingVendorFields else { return }
                                flushVendorToStore()
                            }
                        if !currentPresets.isEmpty {
                            Button("选择预设") {
                                vendorUseCustomModel = false
                                // Snap back to the first preset if current modelID is not in presets
                                if !currentPresets.contains(vendorModelID), let first = currentPresets.first {
                                    vendorModelID = first
                                    flushVendorToStore()
                                }
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                Picker(vendorModelLabel, selection: $vendorModelID) {
                    ForEach(currentPresets, id: \.self) { preset in
                        Text(preset).tag(preset)
                    }
                    Divider()
                    Text("自定义…").tag("__custom__")
                }
                .onChange(of: vendorModelID) { _, newVal in
                    guard !isLoadingVendorFields else { return }
                    if newVal == "__custom__" {
                        vendorUseCustomModel = true
                        vendorModelID = ""
                    } else {
                        flushVendorToStore()
                    }
                }
            }

            // API Key row
            HStack(spacing: 8) {
                SecureField("API Key（点击“保存 API Key”后写入钥匙串）", text: $vendorAPIKey)
                    .onSubmit { saveCurrentVendorAPIKey() }
                Button("保存 API Key") {
                    saveCurrentVendorAPIKey()
                }
                .controlSize(.small)
                .disabled(vendorAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Status row
            HStack {
                Label(
                    configStore.hasAPIKey(for: loadedVendor) ? "Key: ✓ 已保存" : "Key: 未保存",
                    systemImage: configStore.hasAPIKey(for: loadedVendor) ? "key.fill" : "key"
                )
                .font(.caption)
                .foregroundStyle(configStore.hasAPIKey(for: loadedVendor) ? .green : .secondary)

                Spacer()

                if savedFeedback {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                Button("清除 API Key", role: .destructive) {
                    try? configStore.setAPIKey("", for: loadedVendor)
                    vendorAPIKey = ""
                    showSavedFeedback()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Button("检查可用性") {
                    providerProbeResult = nil
                    runAsync { try await applyConfigAndProbeProviders() }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(
                    isRunningTask
                        || coordinator.hasActiveSidecarWork
                        || !Self.shouldProbeCloudAnalysis(for: configStore.config.analysis.mode)
                )
            }

            if let warning = selectedVendorKeyWarning {
                Label("Key 可能无效：\(warning)（可点击“保存 API Key”覆盖）", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }

            if let probe = providerProbeResult {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        probe.ok ? "连接通过" : "连接失败",
                        systemImage: probe.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(probe.ok ? Color.green : Color.orange)

                    Text("服务：\(probe.vendor.displayName) · 模型：\(probe.model.isEmpty ? "未填写" : probe.model)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("服务地址：\(probe.baseURL)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let providerProbeAt {
                        Text("最近验证：\(providerProbeAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if !probe.message.isEmpty {
                        Text(probe.message)
                            .font(.system(size: 12))
                    }
                    if !probe.hint.isEmpty {
                        Text("修复建议：\(probe.hint)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button("重新检查") {
                            runAsync { try await applyConfigAndProbeProviders() }
                        }
                        .controlSize(.small)
                        .disabled(isRunningTask || coordinator.hasActiveSidecarWork)

                        if !probe.ok {
                            Button("打开钥匙串设置提示") {
                                statusMessage = "请在当前服务重新填写 API Key 后点击“检查可用性”。"
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(probe.ok ? Color.green.opacity(0.4) : Color.orange.opacity(0.5), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - ASR Section

    @ViewBuilder
    private var asrSection: some View {
        Section("本地语音识别") {
            Picker("语音识别方案", selection: $asrEngine) {
                ForEach(LocalASREngine.allCases) { engine in
                    Text(engine.userLabel).tag(engine)
                }
            }
            .onChange(of: asrEngine) { _, newEngine in
                asrModel = configStore.defaultModelName(for: newEngine)
                asrModelDir = configStore.defaultModelDir(for: newEngine)
                useCustomWhisperModel = false
                useCustomFunasrModel = false
                useCustomQwenModel = false
                autoSaveASR()
            }

            // Model Picker
            if asrEngine == .whisper {
                if useCustomWhisperModel {
                    HStack {
                        TextField("自定义 Whisper 模型名", text: $asrModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: asrModel) { _, _ in autoSaveASR() }
                        Button("使用预设") {
                            useCustomWhisperModel = false
                            asrModel = configStore.defaultModelName(for: .whisper)
                            autoSaveASR()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                } else {
                    Picker("Whisper 模型", selection: $asrModel) {
                        ForEach(AppConfigStore.whisperPresets, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("自定义…").tag("__custom__")
                    }
                    .onChange(of: asrModel) { _, v in
                        if v == "__custom__" { useCustomWhisperModel = true; asrModel = "" }
                        else { autoSaveASR() }
                    }
                }
            } else if asrEngine == .funasr {
                if useCustomFunasrModel {
                    HStack {
                        TextField("自定义 FunASR 模型名", text: $asrModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: asrModel) { _, _ in autoSaveASR() }
                        Button("使用预设") {
                            useCustomFunasrModel = false
                            asrModel = configStore.defaultModelName(for: .funasr)
                            autoSaveASR()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                } else {
                    Picker("FunASR 模型", selection: $asrModel) {
                        ForEach(AppConfigStore.funasrPresets, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("自定义…").tag("__custom__")
                    }
                    .onChange(of: asrModel) { _, v in
                        if v == "__custom__" { useCustomFunasrModel = true; asrModel = "" }
                        else { autoSaveASR() }
                    }
                }
            } else {
                if useCustomQwenModel {
                    HStack {
                        TextField("自定义 Qwen3-ASR 模型名", text: $asrModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: asrModel) { _, _ in autoSaveASR() }
                        Button("使用预设") {
                            useCustomQwenModel = false
                            asrModel = configStore.defaultModelName(for: .qwenmlx)
                            autoSaveASR()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                } else {
                    Picker("Qwen3-ASR 模型", selection: $asrModel) {
                        ForEach(AppConfigStore.qwenPresets, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("自定义…").tag("__custom__")
                    }
                    .onChange(of: asrModel) { _, v in
                        if v == "__custom__" { useCustomQwenModel = true; asrModel = "" }
                        else { autoSaveASR() }
                    }
                }
            }

            TextField("模型下载位置", text: $asrModelDir)
                .textFieldStyle(.roundedBorder)
                .onChange(of: asrModelDir) { _, _ in autoSaveASR() }

            DisclosureGroup("高级设置") {
                Toggle("启用静音过滤（VAD）", isOn: $vadEnabled)
                    .onChange(of: vadEnabled) { _, _ in autoSaveASR() }
                Toggle("启用说话人区分", isOn: $diarizationEnabled)
                    .onChange(of: diarizationEnabled) { _, _ in autoSaveASR() }
                Toggle("失败时不使用兜底结果（严格模式）", isOn: $strictMode)
                    .onChange(of: strictMode) { _, _ in
                        configStore.updateStrictMode(strictMode)
                        showSavedFeedback()
                    }
            }

            HStack(spacing: 8) {
                Button("一键修复语音识别") {
                    runAsync { try await applyConfigAndBootstrapASR() }
                }
                .disabled(isRunningTask || coordinator.hasActiveSidecarWork)

                Button("一键测试服务") {
                    runAsync { try await runQuickDiagnostics() }
                }
                .disabled(isRunningTask || coordinator.hasActiveSidecarWork)

                Button("重启 Sidecar") {
                    runAsync { try await restartSidecar() }
                }
                .disabled(isRunningTask || coordinator.hasActiveSidecarWork)
            }

            if let runtime = asrRuntimeSnapshot {
                VStack(alignment: .leading, spacing: 6) {
                    asrRuntimeReadinessStatus(runtime)
                    if runtime.profile.schemaVersion > 0 {
                        Text("实时转写：\(runtime.profile.liveASR.ready ? "ready" : "not ready") · 最终媒体转写：\(runtime.profile.finalMediaASR.ready ? "ready" : "not ready")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(runtime.profile.finalMediaASR.ready ? InsightTheme.success : InsightTheme.warning)
                        if !runtime.profile.userRecoveryHint.isEmpty {
                            Text(runtime.profile.userRecoveryHint)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("配置设备：\(runtime.backend.configuredDevice) · 配置计算类型：\(runtime.backend.configuredComputeType)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("运行设备：\(runtime.backend.device) · 运行计算类型：\(runtime.backend.computeType)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("后端解析：\(runtime.backend.resolved.isEmpty ? "待解析" : runtime.backend.resolved)")
                        .font(.system(size: 12, weight: .semibold))
                    if !runtime.backend.supportedComputeTypes.isEmpty {
                        Text("支持计算类型：\(runtime.backend.supportedComputeTypes.joined(separator: ", "))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Text(runtime.warm.ready
                         ? "模型预热：\(runtime.warm.state.rawValue)（\(runtime.warm.lastWarmMs)ms）"
                         : "模型预热：\(runtime.warm.state.rawValue) · attempt \(runtime.warm.attempt)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !runtime.warm.lastError.isEmpty {
                        Text("最近错误：\(runtime.warm.lastError)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let asrRuntimeUpdatedAt {
                        Text("最近状态采样：\(asrRuntimeUpdatedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                )
            }

            appleSpeechExperimentalStatus
        }
    }

    @ViewBuilder
    private var appleSpeechExperimentalStatus: some View {
        let peerParityStatus = AppleSpeechPeerEngineParityStatus.evaluate(runtimeStatus: appleSpeechRuntimeStatus)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apple Speech（实验）")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(appleSpeechRuntimeStatus.state.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appleSpeechRuntimeStatus.isUsableForTranscription ? InsightTheme.success : InsightTheme.textSecondary)
            }
            Text(appleSpeechRuntimeStatus.userMessage)
                .font(.system(size: 12))
                .foregroundStyle(InsightTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("保存音频最终媒体时使用 Apple Speech 原型", isOn: $appleSpeechPrototypeEnabled)
                .disabled(!appleSpeechRuntimeStatus.shouldExposeExperimentalFinalMediaOption && !appleSpeechPrototypeEnabled)
                .onChange(of: appleSpeechPrototypeEnabled) { _, enabled in
                    configStore.updateAppleSpeechPrototypeEnabled(enabled)
                    showSavedFeedback()
                }
            Text(peerParityStatus.userMessage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(peerParityStatus.canExposeAsPeerLocalASREngine ? InsightTheme.success : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(peerParityStatus.blockingReasons, id: \.self) { reason in
                Text("• \(reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("仅用于 macOS 26+ 离线音频媒体转写原型；视频最终媒体仍走当前本地转写路径，不会替换 Whisper / FunASR / Qwen3-ASR 默认引擎，也不会降低说话人分离要求。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let appleSpeechRuntimeUpdatedAt {
                Text("最近状态采样：\(appleSpeechRuntimeUpdatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        )
        .accessibilityIdentifier("settings_apple_speech_experimental_status")
    }

    @ViewBuilder
    private func asrRuntimeReadinessStatus(_ runtime: ASRRuntimeStatus) -> some View {
        if let message = runtime.userVisibleReadinessMessage {
            let isModelMissing = !runtime.modelExists
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(isModelMissing ? InsightTheme.error : InsightTheme.warning)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(InsightTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isModelMissing ? InsightTheme.errorSurface : InsightTheme.warningSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isModelMissing ? InsightTheme.errorBorder : InsightTheme.warningBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier(runtime.userVisibleReadinessAccessibilityIdentifier ?? "settings_asr_runtime_warning_status")
        }
    }

    // MARK: - Storage Section

    @ViewBuilder
    private var storageSection: some View {
        Section("转写记录存储") {
            LabeledContent("存储目录") {
                HStack {
                    Text(recordsService.rootDirectory.path)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("更改") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            recordsService.rootDirectory = url
                        }
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                Text("已用空间：\(recordsService.storageUsedLabel)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中打开") {
                    NSWorkspace.shared.open(recordsService.rootDirectory)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Save Helpers

    /// Flush current vendor fields to store. Never called while isLoadingVendorFields is true.
    private func flushVendorToStore() {
        let base = vendorBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = vendorModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        persistVendorDraft(
            vendor: loadedVendor,
            baseURL: base,
            modelID: model,
            useCustomModel: vendorUseCustomModel
        )
        showSavedFeedback()
    }

    private func persistVendorDraft(vendor: ProviderVendor, baseURL: String, modelID: String, useCustomModel: Bool) {
        vendorDrafts[vendor] = VendorDraft(baseURL: baseURL, modelID: modelID, useCustomModel: useCustomModel)
        configStore.updateProfile(vendor: vendor, baseURL: baseURL, modelID: modelID)
    }

    private func autoSaveASR() {
        configStore.updateASR(
            engine: asrEngine,
            model: asrModel,
            modelDir: asrModelDir,
            vadEnabled: vadEnabled,
            diarizationEnabled: diarizationEnabled
        )
        configStore.updateASRProfileModel(engine: asrEngine, model: asrModel)
        showSavedFeedback()
    }

    private func showSavedFeedback() {
        savedFeedbackTask?.cancel()
        withAnimation { savedFeedback = true }
        savedFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { withAnimation { savedFeedback = false } }
        }
    }

    private func validateAPIKeyFormat(vendor: ProviderVendor, key: String) -> String? {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch vendor {
        case .deepseek:
            if value.hasPrefix("sk-"), value.count >= 20 {
                return nil
            }
            return "DeepSeek API Key 通常以 sk- 开头。"
        case .doubao:
            let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
            if value.range(of: pattern, options: .regularExpression) != nil {
                return nil
            }
            return "豆包 Ark API Key 通常是 UUID 形态。"
        default:
            return value.count >= 12 ? nil : "Key 长度过短。"
        }
    }

    private func saveCurrentVendorAPIKey() {
        let trimmed = vendorAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        try? configStore.setAPIKey(trimmed, for: loadedVendor)
        showSavedFeedback()
    }

    private func saveAPIKey(_ key: String, for vendor: ProviderVendor) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        try? configStore.setAPIKey(trimmed, for: vendor)
    }

    private func loadAPIKey(for vendor: ProviderVendor) {
        vendorAPIKey = configStore.apiKeyValue(for: vendor)
    }

    // MARK: - Vendor switching (critical fix)

    /// Switch to a new vendor.
    ///
    /// Order of operations:
    /// 1. Flush the CURRENT vendor's fields before switching
    /// 2. Set isLoadingVendorFields = true   ← prevents onChange auto-save during field update
    /// 3. Update selectedVendor (already done by Picker binding)
    /// 4. Load new vendor's baseURL + modelID from store
    /// 5. isLoadingVendorFields = false
    private func switchVendor(from oldVendor: ProviderVendor, to newVendor: ProviderVendor) {
        _ = oldVendor
        providerProbeResult = nil
        providerProbeAt = nil
        statusMessage = ""
        savedFeedbackTask?.cancel()
        savedFeedback = false

        let fieldVendor = loadedVendor
        let oldBase = vendorBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldModel = vendorModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldKey = vendorAPIKey
        persistVendorDraft(
            vendor: fieldVendor,
            baseURL: oldBase,
            modelID: oldModel,
            useCustomModel: vendorUseCustomModel
        )
        saveAPIKey(oldKey, for: fieldVendor)

        configStore.updateSelectedVendor(newVendor)

        // Step 2-5: load new vendor under guard
        isLoadingVendorFields = true
        defer { isLoadingVendorFields = false }

        let profile = configStore.profile(for: newVendor)
        let draft = vendorDrafts[newVendor]

        // Use the saved draft if available, else fall back to store profile
        vendorBaseURL = draft?.baseURL ?? profile.baseURL
        vendorModelID = draft?.modelID ?? profile.modelID
        vendorUseCustomModel = draft?.useCustomModel
            ?? !AppConfigStore.modelPresets(for: newVendor).contains(profile.modelID)
        loadAPIKey(for: newVendor)
        loadedVendor = newVendor
    }

    private func selectAnalysisMode(_ mode: AnalysisMode) {
        guard configStore.config.analysis.mode != mode else { return }
        guard !coordinator.hasActiveSidecarWork else {
            statusMessage = "当前录制或导入任务仍在运行，分析方式未更改。"
            return
        }
        configStore.updateAnalysisMode(mode)
        runAsync { try await ensureSidecarInSyncIfNeeded() }
    }

    // MARK: - Initial sync

    private func syncFromStore() {
        let config = configStore.config

        // Build drafts from current store
        for profile in config.analysis.providers {
            let presets = AppConfigStore.modelPresets(for: profile.vendor)
            vendorDrafts[profile.vendor] = VendorDraft(
                baseURL: profile.baseURL,
                modelID: profile.modelID,
                useCustomModel: !presets.contains(profile.modelID)
            )
        }

        isLoadingVendorFields = true
        selectedVendor = config.analysis.selectedVendor
        loadedVendor = selectedVendor
        let profile = configStore.profile(for: selectedVendor)
        vendorBaseURL = profile.baseURL
        vendorModelID = profile.modelID
        vendorUseCustomModel = !AppConfigStore.modelPresets(for: selectedVendor).contains(profile.modelID)
        loadAPIKey(for: selectedVendor)
        isLoadingVendorFields = false

        asrEngine = config.asr.engine
        asrModel = config.asr.model
        asrModelDir = config.asr.modelDir
        vadEnabled = config.asr.vadEnabled
        diarizationEnabled = config.asr.diarizationEnabled
        strictMode = config.strict.strictMode
        appleSpeechPrototypeEnabled = config.asr.appleSpeechPrototypeEnabled
        useCustomWhisperModel = !AppConfigStore.whisperPresets.contains(config.asr.whisperProfile.model)
        useCustomFunasrModel = !AppConfigStore.funasrPresets.contains(config.asr.funasrProfile.model)
        useCustomQwenModel = !AppConfigStore.qwenPresets.contains(config.asr.qwenProfile.model)
        lastAppliedConfigRevision = -1
    }

    // MARK: - Async tasks

    private func runAsync(_ task: @escaping () async throws -> Void) {
        isRunningTask = true
        Task {
            defer { Task { @MainActor in isRunningTask = false } }
            do {
                try await task()
            } catch {
                await MainActor.run { statusMessage = error.localizedDescription }
            }
        }
    }

    private func applyConfigAndProbeProviders() async throws {
        flushVendorToStore()
        saveCurrentVendorAPIKey()
        try await ensureSidecarInSyncIfNeeded()
        guard Self.shouldProbeCloudAnalysis(for: configStore.config.analysis.mode) else {
            await MainActor.run {
                providerProbeResult = nil
                providerProbeAt = nil
                statusMessage = "本地 Smart Minutes 已就绪，无需云端服务检查。"
            }
            return
        }
        let status = try rpc.providersStatus(probeActive: false)
        let active = status.vendors.first(where: { $0.vendor == selectedVendor })
        let probe = try rpc.providerProbe(
            vendor: selectedVendor,
            model: active?.modelID ?? vendorModelID,
            baseURL: active?.baseURL ?? vendorBaseURL,
            forceRefresh: true
        )
        let okText = probe.ok ? "可用" : "不可用"
        await MainActor.run {
            providerProbeResult = probe
            providerProbeAt = Date()
            statusMessage = "当前厂商: \(probe.vendor.displayName) · \(okText)"
        }
    }

    private func applyConfigAndBootstrapASR() async throws {
        flushVendorToStore()
        saveCurrentVendorAPIKey()
        configStore.updateASRProfileModel(engine: asrEngine, model: asrModel)
        configStore.updateASREngine(asrEngine)
        try await ensureSidecarInSyncIfNeeded()
        let result = try rpc.asrRuntimeBootstrap(model: asrModel, engine: asrEngine)
        try await refreshASRRuntimeStatus()
        await MainActor.run {
            statusMessage = result.ok ? "语音识别运行时已就绪。" : "语音识别修复失败，请查看日志后重试。"
        }
    }

    private func restartSidecar() async throws {
        flushVendorToStore()
        saveCurrentVendorAPIKey()
        let ensureReadyProbe = { [rpc] in _ = try rpc.ensureReady(timeoutSec: 6) }
        try requireIdleSidecar()
        try sidecarManager.rebootstrap(ensureReady: ensureReadyProbe, requireIdle: true)
        try await refreshASRRuntimeStatus()
        await MainActor.run {
            lastAppliedConfigRevision = configStore.configRevision
            statusMessage = "Sidecar 已重启并加载新配置。"
        }
    }

    private func runQuickDiagnostics() async throws {
        flushVendorToStore()
        saveCurrentVendorAPIKey()
        try await ensureSidecarInSyncIfNeeded()
        try await refreshASRRuntimeStatus()
        let report = try rpc.diagnosticsQuickCheck(probeTimeoutSec: 6)
        let shouldProbeCloud = Self.shouldProbeCloudAnalysis(for: configStore.config.analysis.mode)
        let providerProbe: ProviderProbeResult?
        if shouldProbeCloud {
            let status = try rpc.providersStatus(probeActive: false)
            let active = status.vendors.first(where: { $0.vendor == selectedVendor })
            providerProbe = try rpc.providerProbe(
                vendor: selectedVendor,
                model: active?.modelID ?? vendorModelID,
                baseURL: active?.baseURL ?? vendorBaseURL,
                forceRefresh: true
            )
        } else {
            providerProbe = nil
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micReady = micStatus == .authorized
        let screenReady = CGPreflightScreenCaptureAccess()
        let overall = report.overall == .pass && micReady && screenReady && (providerProbe?.ok ?? true) ? "通过" : "需处理"
        let lines = report.checks.map {
            "\($0.title): \($0.status.rawValue)\($0.timedOut ? "(timeout)" : "") (\($0.details))"
        }
        let permissionLine = "权限检查: 麦克风=\(micReady ? "pass" : "fail"), 屏幕录制=\(screenReady ? "pass" : "fail")"
        let providerLine = providerProbe.map {
            "厂商探测: \($0.vendor.displayName)=\($0.ok ? "pass" : "fail") (\($0.model))"
        } ?? "智能分析: 本地 Smart Minutes=pass（无需云端厂商探测）"
        let hasTimeout = report.checks.contains(where: { $0.timedOut })
        await MainActor.run {
            providerProbeResult = providerProbe
            providerProbeAt = providerProbe == nil ? nil : Date()
            let suffix = hasTimeout ? "（部分检查超时）" : ""
            statusMessage = "快速自检 \(overall)\(suffix)\n" + ([permissionLine, providerLine] + lines).joined(separator: "\n")
        }
    }

    private func ensureSidecarInSyncIfNeeded() async throws {
        let ensureReadyProbe = { [rpc] in _ = try rpc.ensureReady(timeoutSec: 6) }
        let revision = configStore.configRevision
        if revision != lastAppliedConfigRevision {
            try requireIdleSidecar()
            try sidecarManager.rebootstrap(ensureReady: ensureReadyProbe, requireIdle: true)
            await MainActor.run {
                lastAppliedConfigRevision = revision
            }
            return
        }
        do {
            _ = try rpc.ensureReady(timeoutSec: 6)
        } catch {
            try requireIdleSidecar()
            try sidecarManager.rebootstrap(ensureReady: ensureReadyProbe, requireIdle: true)
            await MainActor.run {
                lastAppliedConfigRevision = configStore.configRevision
            }
        }
    }

    private func requireIdleSidecar() throws {
        guard !coordinator.hasActiveSidecarWork else {
            throw NSError(
                domain: "InsightKit.Settings",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "当前录制或导入任务仍在运行，Sidecar 未重启。"]
            )
        }
    }

    private func refreshASRRuntimeStatus() async throws {
        let status = try rpc.asrRuntimeStatus(engine: asrEngine)
        await MainActor.run {
            asrRuntimeSnapshot = status
            asrRuntimeUpdatedAt = Date()
        }
    }

    private func refreshAppleSpeechRuntimeStatus() async {
        let status = await AppleSpeechTranscriptionService().runtimeStatus()
        await MainActor.run {
            appleSpeechRuntimeStatus = status
            appleSpeechRuntimeUpdatedAt = Date()
        }
    }
}
