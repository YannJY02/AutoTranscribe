import Foundation

extension LiveSessionViewModel {
    func cancelWarmupTasks(cancelRetry: Bool = true) {
        warmupKickTask?.cancel()
        warmupKickTask = nil
        warmupPollTask?.cancel()
        warmupPollTask = nil
        if cancelRetry {
            warmupRetryTask?.cancel()
            warmupRetryTask = nil
        }
    }

    func performRPC<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            rpcQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func beginWarmupLifecycle(
        meetingID: String,
        startupAt: Date,
        engine: LocalASREngine,
        model: String,
        resetFailures: Bool = true
    ) {
        cancelWarmupTasks(cancelRetry: false)
        if resetFailures {
            stateQueue.sync {
                warmupFailureCount = 0
                warmupRetryScheduled = false
            }
        }
        updateMain {
            self.captureState = .warmingModel
            self.liveWarmup.state = self.asrWarmStatus.ready ? .ready : .loading
            self.liveWarmup.attempt = max(self.liveWarmup.attempt, self.asrWarmStatus.attempt)
            self.liveWarmup.isRetryScheduled = false
            self.liveWarmup.automaticRetryCount = self.stateQueue.sync { self.warmupFailureCount }
            if self.asrWarmStatus.ready {
                self.liveWarmup.lastError = ""
            }
        }

        if asrWarmStatus.ready {
            markWarmReady(meetingID: meetingID, startupAt: startupAt, backend: asrBackendStatus, warm: asrWarmStatus)
            return
        }

        warmupKickTask = Task { [weak self] in
            guard let self else { return }
            await self.runWarmupKick(meetingID: meetingID, startupAt: startupAt, engine: engine, model: model)
        }
        warmupPollTask = Task { [weak self] in
            guard let self else { return }
            await self.runWarmupPoll(meetingID: meetingID, startupAt: startupAt, engine: engine, model: model)
        }
    }

    func runWarmupKick(
        meetingID: String,
        startupAt: Date,
        engine: LocalASREngine,
        model: String
    ) async {
        do {
            let result = try await performRPC {
                try self.rpcClient.asrPrewarm(model: model, engine: engine, timeoutSec: 20)
            }
            applyWarmSnapshot(result.warm, backend: result.backend)
            if result.warm.ready || result.state == .ready {
                markWarmReady(meetingID: meetingID, startupAt: startupAt, backend: result.backend, warm: result.warm)
            } else if result.state == .failed || result.warm.state == .failed {
                await handleWarmFailure(
                    message: result.error.isEmpty ? result.warm.lastError : result.error,
                    meetingID: meetingID,
                    startupAt: startupAt,
                    engine: engine,
                    model: model,
                    attempt: max(result.attempt, result.warm.attempt)
                )
            }
        } catch {
            await handleWarmFailure(
                message: error.localizedDescription,
                meetingID: meetingID,
                startupAt: startupAt,
                engine: engine,
                model: model,
                attempt: max(1, asrWarmStatus.attempt)
            )
        }
    }

    func runWarmupPoll(
        meetingID: String,
        startupAt: Date,
        engine: LocalASREngine,
        model: String
    ) async {
        while !Task.isCancelled {
            if !isRunning || currentActiveMeetingID() != meetingID {
                return
            }
            do {
                let status = try await performRPC {
                    try self.rpcClient.asrRuntimeStatus(engine: engine)
                }
                applyWarmSnapshot(status.warm, backend: status.backend)
                if status.warm.ready {
                    markWarmReady(meetingID: meetingID, startupAt: startupAt, backend: status.backend, warm: status.warm)
                    return
                }
                if status.warm.state == .failed {
                    await handleWarmFailure(
                        message: status.warm.lastError,
                        meetingID: meetingID,
                        startupAt: startupAt,
                        engine: engine,
                        model: model,
                        attempt: status.warm.attempt
                    )
                    return
                }
            } catch {
                await handleWarmFailure(
                    message: error.localizedDescription,
                    meetingID: meetingID,
                    startupAt: startupAt,
                    engine: engine,
                    model: model,
                    attempt: max(1, asrWarmStatus.attempt)
                )
                return
            }
            try? await Task.sleep(nanoseconds: warmupPollIntervalNs)
        }
    }

    func applyWarmSnapshot(_ warm: ASRWarmStatus, backend: ASRBackendStatus) {
        updateMain {
            self.asrBackendStatus = backend
            self.asrWarmStatus = warm
            self.liveWarmup.state = warm.state
            self.liveWarmup.attempt = max(self.liveWarmup.attempt, warm.attempt)
            self.liveWarmup.lastError = warm.lastError
            self.liveWarmup.isRetryScheduled = self.stateQueue.sync { self.warmupRetryScheduled }
            self.liveWarmup.automaticRetryCount = self.stateQueue.sync { self.warmupFailureCount }
        }
    }

    func markWarmReady(
        meetingID: String,
        startupAt: Date,
        backend: ASRBackendStatus,
        warm: ASRWarmStatus
    ) {
        let warmReadyMs = max(warm.lastWarmMs, Int(Date().timeIntervalSince(startupAt) * 1000))
        stateQueue.sync {
            warmupRetryScheduled = false
        }
        updateMain {
            self.asrBackendStatus = backend
            self.asrWarmStatus = warm
            if self.metrics.warmReadyMs == 0 {
                self.metrics.warmReadyMs = warmReadyMs
            } else {
                self.metrics.warmReadyMs = max(self.metrics.warmReadyMs, warmReadyMs)
            }
            self.liveWarmup.state = .ready
            self.liveWarmup.attempt = max(self.liveWarmup.attempt, warm.attempt)
            self.liveWarmup.lastError = ""
            self.liveWarmup.isRetryScheduled = false
            self.captureState = self.activeCaptureState
        }
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            self.pumpChunkQueueIfNeeded(meetingID: meetingID)
        }
    }

    func handleWarmFailure(
        message: String,
        meetingID: String,
        startupAt: Date,
        engine: LocalASREngine,
        model: String,
        attempt: Int
    ) async {
        guard isRunning, currentActiveMeetingID() == meetingID else {
            return
        }

        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "模型预热失败。"
            : message

        let decision: WarmupRetryAction = stateQueue.sync {
            if warmupRetryScheduled {
                return .retry(afterSeconds: warmupRetryPolicy.retryDelaySec)
            }
            warmupFailureCount += 1
            return warmupRetryPolicy.action(forFailureCount: warmupFailureCount)
        }

        let failedWarm = ASRWarmStatus(
            ready: false,
            state: .failed,
            inProgress: false,
            attempt: max(1, attempt),
            lastWarmMs: asrWarmStatus.lastWarmMs,
            lastError: normalizedMessage
        )
        applyWarmSnapshot(failedWarm, backend: asrBackendStatus)

        switch decision {
        case .retry(let afterSeconds):
            let shouldSchedule = stateQueue.sync {
                if warmupRetryScheduled {
                    return false
                }
                warmupRetryScheduled = true
                return true
            }
            guard shouldSchedule else { return }

            updateMain {
                self.captureState = .warmingModel
                self.errorMessage = "本地语音识别预热失败，\(afterSeconds)s 后自动重试。"
                self.liveWarmup.isRetryScheduled = true
                self.liveWarmup.automaticRetryCount = self.stateQueue.sync { self.warmupFailureCount }
            }

            warmupRetryTask?.cancel()
            warmupRetryTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(afterSeconds) * 1_000_000_000)
                guard !Task.isCancelled, self.isRunning, self.currentActiveMeetingID() == meetingID else {
                    return
                }
                self.stateQueue.sync {
                    self.warmupRetryScheduled = false
                }
                self.warmupRetryTask = nil
                self.beginWarmupLifecycle(
                    meetingID: meetingID,
                    startupAt: startupAt,
                    engine: engine,
                    model: model,
                    resetFailures: false
                )
            }
        case .failSession:
            updateMain {
                self.errorMessage = normalizedMessage
            }
            stopLiveSession(finalState: .error(normalizedMessage))
        }
    }
}
