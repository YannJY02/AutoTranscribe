import Foundation

extension LiveSessionViewModel {
    func ensureRuntimeReady(requireASR: Bool, requireProvider: Bool, allowProviderProbeFailure: Bool) throws {
        func restartAndRetry() throws {
            try sidecarManager.rebootstrap(ensureReady: { [weak self] in
                guard let self else { return }
                _ = try self.rpcClient.ensureReady(timeoutSec: 6)
            })
        }

        if requireASR {
            let selectedEngine = AppConfigStore.shared.config.asr.engine
            let selectedModel = AppConfigStore.shared.currentASRModel()
            let asr: ASRRuntimeStatus
            do {
                asr = try rpcClient.asrRuntimeStatus(engine: selectedEngine)
            } catch {
                if error.localizedDescription.lowercased().contains("method not found: asr.runtime.status") {
                    try restartAndRetry()
                    asr = try rpcClient.asrRuntimeStatus(engine: selectedEngine)
                } else {
                    throw error
                }
            }
            updateMain {
                self.asrBackendStatus = asr.backend
                self.asrWarmStatus = asr.warm
            }
            if !asr.ready {
                if AppConfigStore.shared.config.download.autoBootstrapEnabled {
                    _ = try rpcClient.asrRuntimeBootstrap(model: selectedModel, engine: selectedEngine)
                    let retried = try rpcClient.asrRuntimeStatus(engine: selectedEngine)
                    updateMain {
                        self.asrBackendStatus = retried.backend
                        self.asrWarmStatus = retried.warm
                    }
                    if retried.ready {
                        return
                    }
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -4201,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "本地语音识别未就绪（\(selectedEngine.displayName) / \(asr.modelName)）。请打开设置，点击“一键修复语音识别”。",
                    ]
                )
            }
        }

        if requireProvider {
            let configStore = AppConfigStore.shared
            let selectedVendor = configStore.config.analysis.selectedVendor
            let selectedProfile = configStore.profile(for: selectedVendor)
            let providers: AnalysisProvidersStatus
            do {
                providers = try rpcClient.providersStatus(probeActive: false)
            } catch {
                if error.localizedDescription.lowercased().contains("method not found: analysis.providers.status") {
                    try restartAndRetry()
                    providers = try rpcClient.providersStatus(probeActive: false)
                } else if allowProviderProbeFailure && isProviderProbeTimeout(error) {
                    stateQueue.sync { insightRefreshSuspended = true }
                    updateMain {
                        self.analysisRuntimeState = .pausedTimeout
                        self.errorMessage = "智能分析探测超时，转写继续、洞察已暂停。"
                    }
                    return
                } else {
                    throw error
                }
            }
            if !providers.activeReady {
                updateMain {
                    self.analysisRuntimeState = .missingConfig
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -4202,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "分析模型未配置完成（当前厂商: \(providers.selectedVendor.displayName)）。请在设置中填写 API Key 与 Model ID。",
                    ]
                )
            }

            let probe: ProviderProbeResult
            do {
                probe = try rpcClient.providerProbe(
                    vendor: selectedVendor,
                    model: selectedProfile.modelID,
                    baseURL: selectedProfile.baseURL,
                    forceRefresh: true
                )
            } catch {
                if error.localizedDescription.lowercased().contains("method not found: analysis.provider.probe") {
                    try restartAndRetry()
                    probe = try rpcClient.providerProbe(
                        vendor: selectedVendor,
                        model: selectedProfile.modelID,
                        baseURL: selectedProfile.baseURL,
                        forceRefresh: true
                    )
                } else if allowProviderProbeFailure && isProviderProbeTimeout(error) {
                    stateQueue.sync { insightRefreshSuspended = true }
                    updateMain {
                        self.analysisRuntimeState = .pausedTimeout
                        self.errorMessage = "智能分析探测超时，转写继续、洞察已暂停。"
                    }
                    return
                } else {
                    throw error
                }
            }
            if !probe.ok {
                if allowProviderProbeFailure {
                    stateQueue.sync { insightRefreshSuspended = true }
                    updateMain {
                        self.analysisRuntimeState = probe.code == .authFailed ? .pausedAuthFailed : .pausedTimeout
                        self.errorMessage = "智能分析暂不可用，转写继续、洞察已暂停。请在设置中修复后重试。"
                    }
                    return
                }
                var msg = probe.message
                if !probe.hint.isEmpty {
                    msg += " \(probe.hint)"
                }
                throw NSError(
                    domain: "InsightKit",
                    code: -4203,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
            stateQueue.sync { insightRefreshSuspended = false }
            updateMain {
                self.analysisRuntimeState = .ready
            }
        }
    }

    func isProviderAuthFailure(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("鉴权失败") || lower.contains("authentication fails") {
            return true
        }
        return lower.contains("http 401") || lower.contains("governor")
    }

    func isProviderProbeTimeout(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("调用超时: analysis.provider.probe")
            || lower.contains("调用超时: analysis.providers.status")
            || lower.contains("probe_timeout")
    }

    func assertSidecarCapabilities(_ required: [String]) throws {
        let version: [String: Any]
        do {
            version = try rpcClient.sidecarVersion()
        } catch {
            if error.localizedDescription.lowercased().contains("method not found: sidecar.version") {
                return
            }
            throw error
        }
        guard let actions = version["capabilities"] as? [String], !actions.isEmpty else {
            return
        }
        let missing = required.filter { !actions.contains($0) }
        if !missing.isEmpty {
            throw NSError(
                domain: "InsightKit",
                code: -4301,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "当前侧车版本缺少实时能力（\(missing.joined(separator: ", "))）。请在设置执行“一键测试服务”并重启应用。",
                ]
            )
        }
    }
}
