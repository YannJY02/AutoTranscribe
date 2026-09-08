import AVFoundation
import Foundation
import OSLog

private let captureTimingLogger = Logger(subsystem: "com.yannjy.insightkit", category: "CaptureTiming")

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
    func configureVideoCaptureCallbacks(meetingID: String) {
        videoCaptureService.onRecordingFirstFrame = { [weak self] time in
            guard let self else { return }
            self.stateQueue.sync {
                guard self.isRunning, self._sessionState.activeMeetingID == meetingID else { return }
                self.captureTimeline.markVideoStart(at: time)
            }
        }
        videoCaptureService.onRecordingFailure = { [weak self] message in
            guard let self else { return }
            self.updateMain {
                guard self.isCurrentLiveSession(meetingID) else { return }
                self.publishError(NSError(domain: "InsightKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ]))
                self.stopLiveSession(finalState: .error(message))
            }
        }
    }

    func configureAudioCaptureCallbacks(meetingID: String? = nil) {
        micCapture.onBuffer = { [weak self] buffer in
            self?.handleCapturedBuffer(buffer, source: .microphone, meetingID: meetingID)
        }
        systemAudioCapture.onBuffer = { [weak self] buffer, sourceStartSec in
            self?.handleCapturedBuffer(
                buffer, source: .systemAudio, meetingID: meetingID, sourceStartSec: sourceStartSec
            )
        }
        mixBus.onMixedSamples = { [weak self] samples in
            guard let self, let meetingID = meetingID ?? self.currentActiveMeetingID() else { return }
            self.archiveAcceptedMixedSamples(samples, meetingID: meetingID)
        }
    }

    func handleCapturedBuffer(
        _ buffer: AVAudioPCMBuffer,
        source: AudioMixBus.Source,
        meetingID: String?,
        sourceStartSec: TimeInterval? = nil
    ) {
        let accepted = stateQueue.sync {
            guard let activeMeetingID = _sessionState.activeMeetingID,
                  meetingID == nil || meetingID == activeMeetingID,
                  isRunning || audioCaptureDraining,
                  !recordingPaused else { return false }
            let receivedAt = recordingUptime()
            let isFirstSystemAudioBuffer = source == .systemAudio && captureTimeline.audioStartSec == nil
            captureTimeline.markAudioBufferStartIfNeeded(
                receivedAt: receivedAt,
                sampleCount: Int(buffer.frameLength),
                sampleRate: Int(buffer.format.sampleRate),
                sourceStartSec: sourceStartSec
            )
            if isFirstSystemAudioBuffer {
                let validSourceStart = sourceStartSec.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                let duration = buffer.format.sampleRate > 0
                    ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
                let oldEstimateMinusPTS = validSourceStart.map { receivedAt - duration - $0 } ?? -1
                let timingBasis = validSourceStart == nil ? "receipt_minus_duration" : "source_pts"
                let selectedStart = captureTimeline.audioStartSec ?? -1
                captureTimingLogger.notice(
                    "system_audio_first_buffer source_pts_s=\(validSourceStart ?? -1, privacy: .public) received_at_s=\(receivedAt, privacy: .public) duration_s=\(duration, privacy: .public) selected_start_s=\(selectedStart, privacy: .public) old_estimate_minus_pts_s=\(oldEstimateMinusPTS, privacy: .public) basis=\(timingBasis, privacy: .public)"
                )
            }
            switch source {
            case .microphone: mixBus.ingestMicrophone(buffer)
            case .systemAudio: mixBus.ingestSystemAudio(buffer)
            }
            return true
        }
        if accepted { recordInputLevel(buffer: buffer, source: source) }
    }

    func handleMixedSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        stateQueue.sync {
            guard let meetingID = _sessionState.activeMeetingID,
                  isRunning,
                  !recordingPaused else { return }
            enqueueAcceptedAudioArchive(samples, meetingID: meetingID)
        }
    }

    private func archiveAcceptedMixedSamples(_ samples: [Float], meetingID: String) {
        guard !samples.isEmpty else { return }
        stateQueue.sync {
            guard _sessionState.activeMeetingID == meetingID else { return }
            enqueueAcceptedAudioArchive(samples, meetingID: meetingID)
        }
    }

    /// Called under stateQueue, preserving acceptance order across pause/stop.
    private func enqueueAcceptedAudioArchive(_ samples: [Float], meetingID: String) {
        captureTimeline.markAudioBufferStartIfNeeded(
            receivedAt: recordingUptime(),
            sampleCount: samples.count,
            sampleRate: chunkAssembler.sampleRate
        )
        audioArchiveQueue.async { [weak self] in
            guard let self, self.currentActiveMeetingID() == meetingID else { return }
            do {
                let chunks = try self.chunkAssembler.append(samples: samples)
                self.pipelineQueue.async {
                    guard self.currentActiveMeetingID() == meetingID else { return }
                    for chunk in chunks {
                        self.enqueueChunkForProcessing(chunk, meetingID: meetingID)
                    }
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
        guard !stateQueue.sync(execute: { visualRecordingStartPending }) else { return }
        guard !isRunning || !shouldHoldChunksForWarmup else { return }
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
            updateWorkbench(result, analyticsLatencyMilliseconds: outcome.analysisLatencyMs)
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
