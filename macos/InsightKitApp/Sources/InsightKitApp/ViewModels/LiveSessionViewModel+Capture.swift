import AVFoundation
import Foundation

enum LiveCaptureHealthHint {
    static let noInput = "采集无输入：请检查音频源选择、麦克风/屏幕录制权限，或先切换到“仅麦克风”排查。"
    static let waitingForTranscript = "等待转写输入：已收到音频，当前暂未产出文本；如果持续无文本，请检查音量、静音状态或环境噪声。"

    static func isTransient(_ message: String?) -> Bool {
        guard let message else { return false }
        return message == noInput || message == waitingForTranscript
    }
}

enum LiveAnalysisHealthHint {
    static let refreshTimeout = "智能分析刷新超时，转写继续；系统会在后续转写更新后自动重试。"

    static func isTransient(_ message: String?) -> Bool {
        guard let message else { return false }
        return message == refreshTimeout
    }
}

private func isTransientLiveStatus(_ message: String?) -> Bool {
    LiveCaptureHealthHint.isTransient(message) || LiveAnalysisHealthHint.isTransient(message)
}

extension LiveSessionViewModel {
    func handleMixedSamples(_ samples: [Float]) {
        if samples.isEmpty || !isRunning || isLiveRecordingPaused() {
            return
        }

        let receivedAt = ProcessInfo.processInfo.systemUptime
        let sampleCount = samples.count
        let sampleRate = chunkAssembler.sampleRate
        stateQueue.sync {
            captureTimeline.markAudioBufferStartIfNeeded(
                receivedAt: receivedAt,
                sampleCount: sampleCount,
                sampleRate: sampleRate
            )
        }

        pipelineQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning, !self.isLiveRecordingPaused() else { return }
            do {
                let chunks = try self.chunkAssembler.append(samples: samples)
                guard let meetingID = self.currentActiveMeetingID() else { return }
                for chunk in chunks {
                    self.enqueueChunkForProcessing(chunk, meetingID: meetingID)
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    func enqueueChunkForProcessing(_ chunk: AudioChunk, meetingID: String) {
        if shouldHoldChunksForWarmup {
            let update = warmupBacklogPolicy.enqueue(chunk, into: queuedChunks)
            queuedChunks = update.queue
            let droppedCount = update.droppedExisting.count + (update.droppedIncoming ? 1 : 0)
            updateMain {
                if droppedCount > 0 {
                    self.metrics.droppedChunks += droppedCount
                }
                self.metrics.queueDepth = self.queuedChunks.count
                self.liveWarmup.bufferedChunks = self.queuedChunks.count
                self.liveWarmup.bufferedAudioMs = update.bufferedAudioMs
            }
            return
        }

        if queuedChunks.count >= maxQueuedChunks {
            if let idx = queuedChunks.firstIndex(where: { $0.isLikelySilent }) {
                queuedChunks.remove(at: idx)
                updateMain {
                    self.metrics.droppedChunks += 1
                }
            } else if chunk.isLikelySilent {
                updateMain {
                    self.metrics.droppedChunks += 1
                    self.metrics.queueDepth = self.queuedChunks.count
                }
                return
            } else if !queuedChunks.isEmpty {
                queuedChunks.removeFirst()
                updateMain {
                    self.metrics.droppedChunks += 1
                }
            }
        }

        queuedChunks.append(chunk)
        updateMain {
            self.metrics.queueDepth = self.queuedChunks.count
            self.liveWarmup.bufferedChunks = self.queuedChunks.count
            self.liveWarmup.bufferedAudioMs = self.queuedChunks.bufferedAudioMs
        }
        pumpChunkQueueIfNeeded(meetingID: meetingID)
    }

    func pumpChunkQueueIfNeeded(meetingID: String) {
        guard !chunkInFlight else {
            return
        }
        guard !queuedChunks.isEmpty else {
            updateMain {
                self.metrics.queueDepth = 0
                self.liveWarmup.bufferedChunks = 0
                self.liveWarmup.bufferedAudioMs = 0
            }
            return
        }
        let shouldDrainForStop = stateQueue.sync { stopDrainingMeetingID == meetingID }
        guard isRunning || shouldDrainForStop else {
            queuedChunks.removeAll(keepingCapacity: false)
            chunkInFlight = false
            updateMain {
                self.metrics.queueDepth = 0
                self.liveWarmup.bufferedChunks = 0
                self.liveWarmup.bufferedAudioMs = 0
            }
            return
        }

        chunkInFlight = true
        let chunk = queuedChunks.removeFirst()
        updateMain {
            self.metrics.queueDepth = self.queuedChunks.count
            self.liveWarmup.bufferedChunks = self.queuedChunks.count
            self.liveWarmup.bufferedAudioMs = self.queuedChunks.bufferedAudioMs
        }

        do {
            try processChunk(chunk, meetingID: meetingID)
        } catch {
            publishError(error)
        }

        chunkInFlight = false
        pumpChunkQueueIfNeeded(meetingID: meetingID)
    }

    @discardableResult
    func processChunk(_ chunk: AudioChunk, meetingID: String) throws -> LiveTranscriptPipelineOutcome {
        updateMain {
            self.captureHealth.lastChunkAt = Date()
        }

        let context = LiveTranscriptPipelineContext(
            meetingID: meetingID,
            source: rpcSource(for: activeMode),
            sessionStartedAt: captureHealth.sessionStartedAt,
            warmReady: asrWarmStatus.ready,
            hasTranscript: metrics.firstSegmentMs > 0 || !transcriptSegments.isEmpty,
            isInsightRefreshSuspended: stateQueue.sync { insightRefreshSuspended }
        )

        let outcome = try transcriptPipeline.process(chunk: chunk, context: context)
        applyTranscriptPipelineOutcome(outcome)
        return outcome
    }

    func applyTranscriptPipelineOutcome(_ outcome: LiveTranscriptPipelineOutcome) {
        switch outcome.refresh {
        case .none:
            break
        case .success:
            stateQueue.sync {
                insightRefreshSuspended = false
            }
        case .paused(.timeout) where outcome.errorMessage == nil:
            stateQueue.sync {
                insightRefreshSuspended = false
            }
        case .paused:
            stateQueue.sync {
                insightRefreshSuspended = true
            }
        }

        updateMain {
            self.metrics.chunkIndex = max(self.metrics.chunkIndex, outcome.chunkIndex)
            self.metrics.latencyMs = outcome.latencyMs
            self.metrics.segmentsIngested += outcome.ingestedCount
            if self.metrics.firstSegmentMs == 0, let firstSegmentMs = outcome.firstSegmentMs {
                self.metrics.firstSegmentMs = firstSegmentMs
            }
            if !outcome.transcriptSegments.isEmpty {
                self.transcriptSegments.append(contentsOf: outcome.transcriptSegments)
                self.transcriptSegments.sort { $0.startMs < $1.startMs }
                if isTransientLiveStatus(self.recordingStatusMessage) {
                    self.recordingStatusMessage = nil
                }
            }
            if let lastTranscriptAt = outcome.lastTranscriptAt {
                self.captureHealth.lastTranscriptAt = lastTranscriptAt
            }
            if let providerMetric = outcome.providerMetric {
                self.metrics.provider = providerMetric
            }
            if let analysisRuntimeState = outcome.analysisRuntimeState {
                self.analysisRuntimeState = analysisRuntimeState
            } else if case .success = outcome.refresh {
                self.analysisRuntimeState = .ready
            }
            if let errorMessage = outcome.errorMessage {
                self.errorMessage = errorMessage
            }
            if case .paused(.timeout) = outcome.refresh, outcome.errorMessage == nil {
                self.recordingStatusMessage = LiveAnalysisHealthHint.refreshTimeout
            } else if case .success = outcome.refresh, isTransientLiveStatus(self.recordingStatusMessage) {
                self.recordingStatusMessage = nil
            }
            self.captureState = outcome.captureState
        }

        if case .success(let result) = outcome.refresh {
            updateWorkbench(result)
        }
    }

    func recordInputLevel(buffer: AVAudioPCMBuffer, source: AudioMixBus.Source) {
        let level = rmsLevel(buffer)
        let now = Date()
        let minInterval: TimeInterval = 0.067 // ~15 Hz
        let threshold: Float = 0.02

        switch source {
        case .microphone:
            if let last = lastMicLevelDispatch,
               now.timeIntervalSince(last) < minInterval,
               abs(level - lastMicLevel) < threshold {
                return
            }
            lastMicLevel = level
            lastMicLevelDispatch = now
        case .systemAudio:
            if let last = lastSystemLevelDispatch,
               now.timeIntervalSince(last) < minInterval,
               abs(level - lastSystemLevel) < threshold {
                return
            }
            lastSystemLevel = level
            lastSystemLevelDispatch = now
        }

        updateMain {
            switch source {
            case .microphone:
                self.captureHealth.inputLevelMic = level
            case .systemAudio:
                self.captureHealth.inputLevelSystem = level
            }
        }
    }

    func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        if let channel = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count {
                let v = channel[i]
                sum += v * v
            }
            return min(1, sqrt(sum / Float(count)))
        }
        return 0
    }

    func startCaptureHealthMonitor() {
        captureMonitorTask?.cancel()
        captureMonitorTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.isRunning {
                    break
                }
                await self.evaluateCaptureHealthHint()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @MainActor
    func evaluateCaptureHealthHint() {
        guard isRunning else { return }
        guard !isLiveRecordingPaused() else { return }
        switch captureState {
        case .preparingRuntime, .warmingModel:
            return
        default:
            break
        }
        let now = Date()
        if let last = lastCaptureHintAt, now.timeIntervalSince(last) < 10 {
            return
        }
        guard let started = captureHealth.sessionStartedAt else { return }
        if captureHealth.lastChunkAt == nil, now.timeIntervalSince(started) >= 10 {
            recordingStatusMessage = LiveCaptureHealthHint.noInput
            lastCaptureHintAt = now
            return
        }

        if captureHealth.lastTranscriptAt == nil, now.timeIntervalSince(started) >= 20 {
            recordingStatusMessage = LiveCaptureHealthHint.waitingForTranscript
            lastCaptureHintAt = now
        }
    }
}
