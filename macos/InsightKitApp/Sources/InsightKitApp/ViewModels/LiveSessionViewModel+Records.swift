import Foundation

extension LiveSessionViewModel {

    // MARK: - Save to Records

    /// Called after stopLiveSession completes. Serializes transcript + insight
    /// and calls the records.save RPC to persist the record folder via Python RecordWriter.
    func saveToRecords(
        meetingID: String,
        insightPackageOverride: InsightPackageV1? = nil,
        transcriptSegmentsOverride: [TranscriptSegment]? = nil,
        finalizationLeaseToken: String? = nil,
        completionCaptureState: CaptureState? = nil
    ) {
        // Capture @Published state on the calling thread to avoid data races.
        // These properties are mutated on main; reading them here (pipelineQueue)
        // is safe because stopLiveSession already stopped all producers and
        // updated UI state before invoking this method.
        let capturedSegments = transcriptSegmentsOverride ?? self.transcriptSegments
        let capturedPackage = insightPackageOverride ?? self.lastInsightPackage
        let capturedRecordingURL = self.temporaryRecordingURL
        let capturedDuration = self.recordingDuration
        let capturedNotes = self.notes
        let capturedAnalysisMeta = Self.analysisMetadata(provider: self.metrics.provider, state: self.analysisRuntimeState)
        let capturedTimelineSidecarURL = self.captureTimelineSidecarURL(meetingID: meetingID)
        let capturedPresentationStatus = self.pendingPresentationCaptureStatus?
            .finalized(for: capturedRecordingURL)
        let capturedCachedFinalTranscript: [TranscriptSegment]? = {
            guard let mediaPath = capturedRecordingURL?.path,
                  let cache = self.finalizedMediaTranscriptCache,
                  cache.mediaPath == mediaPath
            else { return nil }
            return cache.segments
        }()
        updateMain {
            self.isFinalizingLiveSession = true
            self.recordingStatusMessage = "录制已停止，正在保存回看资料、转写和笔记。"
        }

        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                if let finalizationLeaseToken {
                    try self.rpcClient.sessionStopForFinalization(
                        meetingID: meetingID,
                        leaseToken: finalizationLeaseToken
                    )
                }
                let durationSec = capturedRecordingURL
                    .flatMap { self.mediaAssetInspector.durationSec(url: $0) }
                    ?? capturedDuration

                let adapter = InsightRuntimeActionRPCAdapter(rpcClient: self.rpcClient)
                let finalizer = LiveSessionFinalizer(
                    finalMediaTranscriber: self.finalMediaTranscriber,
                    runtimeTranscriptReplacementAction: RuntimeTranscriptReplacementAction(adapter: adapter),
                    recordSaveAction: RecordSaveAction(adapter: adapter),
                    retryDelays: self.finalMediaTranscriptRetryDelays
                )
                let outcome = try finalizer.finalize(LiveSessionFinalizationSnapshot(
                    meetingID: meetingID,
                    capturedSegments: capturedSegments,
                    insightPackage: capturedPackage,
                    recordingURL: capturedRecordingURL,
                    durationSec: durationSec,
                    notes: capturedNotes,
                    analysisMeta: capturedAnalysisMeta,
                    cachedFinalTranscript: capturedCachedFinalTranscript,
                    presentationStatus: capturedPresentationStatus,
                    finalizationLeaseToken: finalizationLeaseToken
                ))
                let recordPath = outcome.recordPath
                self.analyticsSubmit { analytics in
                    analytics.recordSaved("live")
                    analytics.recoveryCompleted("live", phase: "finalizing", succeeded: true)
                }
                if !recordPath.isEmpty {
                    self.copyCaptureTimelineSidecar(
                        from: capturedTimelineSidecarURL,
                        toRecordPath: recordPath
                    )
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.recordsService?.refreshIndex()
                    if !recordPath.isEmpty {
                        self.lastExportPath = recordPath
                    }
                    if let mediaPath = capturedRecordingURL?.path {
                        self.finalizedMediaTranscriptCache = (
                            mediaPath: mediaPath,
                            segments: outcome.transcriptSegments
                        )
                    }
                    self.transcriptSegments = outcome.transcriptSegments
                    self.recordingStatusMessage = outcome.statusMessage
                    if let completionCaptureState {
                        self.captureState = completionCaptureState
                        if case .error = completionCaptureState {} else {
                            self.errorMessage = nil
                        }
                    }
                    self.transcriptRecoveryStatusMessage = outcome.recoveryAvailable
                        ? "本次记录已保存媒体和笔记；可从已保存媒体恢复逐字稿。"
                        : nil
                    self.isFinalizingLiveSession = false
                    self.recordLiveReviewOpenedIfSaved()
                }
            } catch let saveError {
                ProductAnalytics.submit(ProductAnalytics.failure { analytics in
                    analytics.workflowFailed("live", phase: "finalizing", errorCode: "storage", recoveryAction: "retry")
                })
                if let finalizationLeaseToken {
                    do {
                        try self.rpcClient.sessionStopForFinalization(
                            meetingID: meetingID,
                            leaseToken: finalizationLeaseToken
                        )
                        try self.rpcClient.sessionFinalizationAbort(
                            meetingID: meetingID,
                            leaseToken: finalizationLeaseToken
                        )
                    } catch {
                        self.publishError(NSError(
                            domain: "InsightKit.FinalizationLease",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "记录保存失败，且本地服务未能确认释放保存保护：\(error.localizedDescription)"]
                        ))
                        return
                    }
                }
                self.updateMain {
                    self.isFinalizingLiveSession = false
                }
                self.publishError(saveError)
            }
        }
    }

    func recordLiveReviewOpenedIfSaved() {
        guard sessionPhase == .reviewing,
              !lastExportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        analyticsSubmit { $0.reviewOpened("live") }
    }

    private func copyCaptureTimelineSidecar(from sourceURL: URL, toRecordPath recordPath: String) {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        let recordURL = URL(fileURLWithPath: recordPath)
        let destinationURL = recordURL.appendingPathComponent("capture_timeline.json")
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            // Best-effort diagnostics only.
        }
    }

    func finalTranscriptSegmentsForRecord(
        mediaURL: URL?,
        capturedSegments: [TranscriptSegment]
    ) throws -> [TranscriptSegment] {
        guard let mediaURL else {
            return capturedSegments
        }
        let mediaPath = mediaURL.path
        if let cache = finalizedMediaTranscriptCache, cache.mediaPath == mediaPath {
            return cache.segments
        }
        let mediaSegments: [TranscriptSegment]
        do {
            updateMain {
                self.isFinalizingLiveSession = true
                self.recordingStatusMessage = "正在根据最终回看资料生成准确转写，请保持应用打开。"
            }
            mediaSegments = try transcribeFinalMediaWithRetry(mediaPath: mediaPath)
        } catch {
            finalizedMediaTranscriptCache = (mediaPath: mediaPath, segments: [])
            updateMain {
                self.transcriptSegments = []
                self.recordingStatusMessage = "最终回看资料转写暂未完成；已保留媒体和笔记，可稍后重新生成。"
            }
            return []
        }
        finalizedMediaTranscriptCache = (mediaPath: mediaPath, segments: mediaSegments)
        updateMain {
            self.transcriptSegments = mediaSegments
            self.recordingStatusMessage = mediaSegments.isEmpty
                ? "最终回看资料没有产生可保存转写；已保留媒体和笔记。"
                : nil
        }
        return mediaSegments
    }

    private func transcribeFinalMediaWithRetry(mediaPath: String) throws -> [TranscriptSegment] {
        var lastError: Error?
        let delays = finalMediaTranscriptRetryDelays
        for attempt in 0...delays.count {
            do {
                return try finalMediaTranscriber.transcribeFinalMedia(mediaPath: mediaPath, source: "media")
            } catch {
                lastError = error
                guard attempt < delays.count else {
                    break
                }
                updateMain {
                    self.recordingStatusMessage = "最终转写仍在后台处理中，正在等待完成，请保持应用打开。"
                }
                let delay = max(0, delays[attempt])
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }
            }
        }
        throw lastError ?? NSError(
            domain: "InsightKit.FinalMediaTranscription",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "最终媒体转写失败"]
        )
    }

    func replaceRuntimeTranscript(meetingID: String, segments: [TranscriptSegment]) throws {
        let deltas = segments.map {
            RPCSegmentDelta(
                startMs: $0.startMs,
                endMs: $0.endMs,
                speaker: $0.speaker == "未标注" ? "" : $0.speaker,
                text: $0.text,
                confidence: 0.0,
                source: $0.source
            )
        }
        _ = try rpcClient.transcriptReplace(meetingID: meetingID, segments: deltas)
    }

    func recoverTranscriptFromSavedRecord() {
        let path = lastExportPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let recordPath = URL(fileURLWithPath: path)
        let duration = recordingDuration
        ProductAnalytics.submit(ProductAnalytics.failure {
            $0.workflowFailed("live", phase: "reviewing", errorCode: "storage", recoveryAction: "retry")
            $0.recoveryAttempted("live", phase: "reviewing")
        })
        updateMain {
            self.transcriptRecoveryStatusMessage = "正在从已保存媒体恢复逐字稿。"
        }

        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.transcriptRecoveryService.recoverTranscript(
                    recordPath: recordPath,
                    duration: duration
                )
                self.updateMain {
                    self.transcriptSegments = result.segments
                    self.recordsService?.refreshIndex()
                    self.transcriptRecoveryStatusMessage = result.smartMinutesMayNeedRegeneration
                        ? "逐字稿已恢复；现有智能纪要仍保留，但可能需要重新生成以匹配新逐字稿。"
                        : "逐字稿已恢复。"
                    self.recordingStatusMessage = nil
                    ProductAnalytics.submit {
                        $0.recoveryCompleted("live", phase: "reviewing", succeeded: true)
                    }
                }
            } catch {
                self.updateMain {
                    self.transcriptRecoveryStatusMessage = "逐字稿恢复失败：\(error.localizedDescription)"
                    ProductAnalytics.submit {
                        $0.recoveryCompleted("live", phase: "reviewing", succeeded: false)
                    }
                }
            }
        }
    }

    private static func analysisMetadata(provider: String, state: AnalysisRuntimeState) -> [String: Any]? {
        var meta: [String: Any] = [
            "source": "final",
            "analysis_state": state.rawValue,
        ]
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            meta["provider"] = parts.first ?? trimmed
            if parts.count > 1 {
                meta["model"] = parts[1]
            }
        }
        return meta
    }

    // MARK: - Live review media preparation

    @discardableResult
    func prepareTemporaryRecordingForSave(meetingID: String, expectedVisualMedia: Bool = false) -> URL? {
        let timeline = stateQueue.sync { captureTimeline }
        let preparer = LiveSessionReviewMediaPreparer(
            audioPreparer: chunkAssembler,
            mediaAssetInspector: mediaAssetInspector,
            reviewMediaComposer: reviewMediaComposer
        )
        let outcome = preparer.prepare(LiveSessionReviewMediaPreparationSnapshot(
            meetingID: meetingID,
            capturedVideoURL: temporaryRecordingURL,
            expectedVisualMedia: expectedVisualMedia,
            captureTimeline: timeline
        ))

        temporaryRecordingURL = outcome.recordingURL
        updateMain {
            self.mediaURL = outcome.mediaURL
            self.reviewSourceMediaURL = outcome.reviewSourceMediaURL
            self.recordingStatusMessage = outcome.recordingStatusMessage
            self.reviewSourceStatusMessage = outcome.reviewSourceStatusMessage
        }
        return outcome.recordingURL
    }

    func captureTimelineSidecarURL(meetingID: String) -> URL {
        LiveSessionReviewMediaPreparer.captureTimelineSidecarURL(meetingID: meetingID)
    }
}
