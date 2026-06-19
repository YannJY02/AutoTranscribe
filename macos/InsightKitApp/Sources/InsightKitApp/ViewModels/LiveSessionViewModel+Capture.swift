import AVFoundation
import Foundation

extension LiveSessionViewModel {
    func handleMixedSamples(_ samples: [Float]) {
        if samples.isEmpty || !isRunning {
            return
        }

        pipelineQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
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
        guard isRunning else {
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

    func processChunk(_ chunk: AudioChunk, meetingID: String) throws {
        updateMain {
            self.captureHealth.lastChunkAt = Date()
        }

        let t0 = Date()
        let source = rpcSource(for: activeMode)
        var segments = try rpcClient.asrTranscribeChunk(
            wavPath: chunk.url.path,
            offsetMs: chunk.startMs,
            source: source
        )
        segments = deduplicateSegments(segments)

        guard !segments.isEmpty else {
            updateMain {
                self.captureState = self.activeCaptureState
                self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunk.index + 1)
            }
            return
        }

        let ingested = try rpcClient.transcriptDelta(meetingID: meetingID, segments: segments)
        let now = Date()

        let newSegments = segments.map {
            TranscriptSegment(
                startMs: $0.startMs,
                endMs: $0.endMs,
                speaker: $0.speaker.isEmpty ? "未标注" : $0.speaker,
                source: $0.source,
                text: $0.text
            )
        }
        let latencyMs = Int(now.timeIntervalSince(t0) * 1000)
        let chunkIdx = chunk.index + 1

        var shouldRefresh = false
        stateQueue.sync {
            shouldRefresh = liveCoordinator.registerIngested(ingested, now: now)
        }

        if shouldRefresh {
            let refreshSuspended = stateQueue.sync { insightRefreshSuspended }
            if refreshSuspended {
                updateMain {
                    self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunkIdx)
                    self.metrics.latencyMs = latencyMs
                    self.metrics.segmentsIngested += ingested
                    if self.metrics.firstSegmentMs == 0, let startedAt = self.captureHealth.sessionStartedAt {
                        self.metrics.firstSegmentMs = max(1, Int(now.timeIntervalSince(startedAt) * 1000))
                    }
                    self.transcriptSegments.append(contentsOf: newSegments)
                    self.transcriptSegments.sort { $0.startMs < $1.startMs }
                    self.captureHealth.lastTranscriptAt = now
                    self.captureState = self.activeCaptureState
                    self.metrics.provider = "analysis-paused"
                }
                return
            }
            updateMain {
                self.captureState = .refreshing
            }
            do {
                let result = try rpcClient.refreshLive(meetingID: meetingID, windowSec: 120)
                stateQueue.sync {
                    liveCoordinator.markRefreshed(at: now)
                    insightRefreshSuspended = false
                }
                updateMain {
                    self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunkIdx)
                    self.metrics.latencyMs = latencyMs
                    self.metrics.segmentsIngested += ingested
                    if self.metrics.firstSegmentMs == 0, let startedAt = self.captureHealth.sessionStartedAt {
                        self.metrics.firstSegmentMs = max(1, Int(now.timeIntervalSince(startedAt) * 1000))
                    }
                    self.transcriptSegments.append(contentsOf: newSegments)
                    self.transcriptSegments.sort { $0.startMs < $1.startMs }
                    self.captureHealth.lastTranscriptAt = now
                    self.analysisRuntimeState = .ready
                    self.captureState = self.activeCaptureState
                }
                updateWorkbench(result)
            } catch {
                if isProviderAuthFailure(error) || isProviderProbeTimeout(error) {
                    stateQueue.sync {
                        liveCoordinator.markRefreshed(at: now)
                        insightRefreshSuspended = true
                    }
                    updateMain {
                        self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunkIdx)
                        self.metrics.latencyMs = latencyMs
                        self.metrics.segmentsIngested += ingested
                        if self.metrics.firstSegmentMs == 0, let startedAt = self.captureHealth.sessionStartedAt {
                            self.metrics.firstSegmentMs = max(1, Int(now.timeIntervalSince(startedAt) * 1000))
                        }
                        self.transcriptSegments.append(contentsOf: newSegments)
                        self.transcriptSegments.sort { $0.startMs < $1.startMs }
                        self.captureHealth.lastTranscriptAt = now
                        self.captureState = self.activeCaptureState
                        self.metrics.provider = "analysis-paused"
                        if self.isProviderProbeTimeout(error) {
                            self.analysisRuntimeState = .pausedTimeout
                            self.errorMessage = "智能分析探测超时，转写继续、洞察已暂停。请稍后重试或检查网络。"
                        } else {
                            self.analysisRuntimeState = .pausedAuthFailed
                            self.errorMessage = "智能分析服务鉴权失败，转写继续、洞察已暂停。请打开设置修复 API 配置后重新开始直播洞察。"
                        }
                    }
                } else {
                    throw error
                }
            }
            return
        }

        updateMain {
            self.metrics.chunkIndex = max(self.metrics.chunkIndex, chunkIdx)
            self.metrics.latencyMs = latencyMs
            self.metrics.segmentsIngested += ingested
            if self.metrics.firstSegmentMs == 0, let startedAt = self.captureHealth.sessionStartedAt {
                self.metrics.firstSegmentMs = max(1, Int(now.timeIntervalSince(startedAt) * 1000))
            }
            self.transcriptSegments.append(contentsOf: newSegments)
            self.transcriptSegments.sort { $0.startMs < $1.startMs }
            self.captureHealth.lastTranscriptAt = now
            self.captureState = self.activeCaptureState
        }
    }

    func deduplicateSegments(_ segments: [RPCSegmentDelta]) -> [RPCSegmentDelta] {
        var result: [RPCSegmentDelta] = []

        for seg in segments {
            let normalizedText = seg.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalizedText.isEmpty {
                continue
            }
            let key = "\(seg.startMs / 500)-\(normalizedText)"
            if recentFingerprints.contains(key) {
                continue
            }
            recentFingerprints.append(key)
            if recentFingerprints.count > 40 {
                recentFingerprints.removeFirst(recentFingerprints.count - 40)
            }
            result.append(seg)
        }

        return result
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
            errorMessage = "采集无输入：请检查音频源选择、麦克风/屏幕录制权限，或先切换到“仅麦克风”排查。"
            lastCaptureHintAt = now
            return
        }

        if captureHealth.lastTranscriptAt == nil, now.timeIntervalSince(started) >= 20 {
            errorMessage = "识别中：当前暂未产出文本，可能是静音、环境噪声或音量过低。"
            lastCaptureHintAt = now
        }
    }
}
