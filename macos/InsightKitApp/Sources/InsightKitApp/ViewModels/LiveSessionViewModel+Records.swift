import Foundation

extension LiveSessionViewModel {

    // MARK: - Save to Records

    /// Called after stopLiveSession completes. Serializes transcript + insight
    /// and calls the records.save RPC to persist the record folder via Python RecordWriter.
    func saveToRecords(meetingID: String, insightPackageOverride: InsightPackageV1? = nil) {
        // Capture @Published state on the calling thread to avoid data races.
        // These properties are mutated on main; reading them here (pipelineQueue)
        // is safe because stopLiveSession already stopped all producers and
        // updated UI state before invoking this method.
        let capturedSegments = self.transcriptSegments
        let capturedPackage = insightPackageOverride ?? self.lastInsightPackage
        let capturedRecordingURL = self.temporaryRecordingURL
        let capturedDuration = self.recordingDuration
        let capturedNotes = self.notes
        let capturedAnalysisMeta = Self.analysisMetadata(provider: self.metrics.provider, state: self.analysisRuntimeState)

        rpcQueue.async { [weak self] in
            guard let self else { return }
            do {
                let segments: [[String: Any]] = capturedSegments.map { seg in
                    [
                        "start_ms": seg.startMs,
                        "end_ms": seg.endMs,
                        "speaker": seg.speaker,
                        "text": seg.text,
                    ]
                }

                var insightPackage: [String: Any]? = nil
                if let pkg = capturedPackage {
                    let data = try JSONEncoder().encode(pkg)
                    insightPackage = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                }

                let sourcePath = capturedRecordingURL?.path ?? ""

                let mediaType: String
                if let url = capturedRecordingURL {
                    let ext = url.pathExtension.lowercased()
                    mediaType = ["mp4", "mov", "mkv", "avi", "webm"].contains(ext) ? "video" : "audio"
                } else {
                    mediaType = "audio"
                }

                let durationSec = capturedDuration

                let notesMD = NotesFileIO.serialize(capturedNotes)

                let recordPath = try self.rpcClient.recordsSave(
                    meetingID: meetingID,
                    title: "直播洞察",
                    sourcePath: sourcePath,
                    segments: segments,
                    insightPackage: insightPackage,
                    mediaType: mediaType,
                    recordSource: "live",
                    durationSec: durationSec,
                    analysisMeta: capturedAnalysisMeta,
                    notesMD: notesMD
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.recordsService?.refreshIndex()
                    if !recordPath.isEmpty {
                        self.lastExportPath = recordPath
                    }
                }
            } catch {
                self.publishError(error)
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

    // MARK: - WAV chunk concatenation (audio-only fallback)

    func concatenateWAVChunks(meetingID: String) -> URL? {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        let outputURL = tmpDir.appendingPathComponent("recording.wav")
        return chunkAssembler.writeCombinedWAV(to: outputURL)
    }

    @discardableResult
    func prepareTemporaryRecordingForSave(meetingID: String, expectedVisualMedia: Bool = false) -> URL? {
        if let videoURL = usableVideoRecordingURL(temporaryRecordingURL) {
            let reviewAudioURL = prepareAudibleReviewSource(meetingID: meetingID)
            updateMain {
                self.recordingStatusMessage = nil
                self.mediaURL = videoURL
                self.reviewSourceMediaURL = reviewAudioURL
                if reviewAudioURL != nil {
                    self.reviewSourceStatusMessage = "为保证声音可听，回看资料已切换为音频播放。"
                } else if expectedVisualMedia {
                    let message = "视频回看已保存，但本次没有可播放音频。请检查麦克风或系统音频输入。"
                    self.recordingStatusMessage = message
                    self.reviewSourceStatusMessage = message
                } else {
                    self.reviewSourceStatusMessage = nil
                }
            }
            return videoURL
        }

        guard let recordingURL = prepareAudibleReviewSource(meetingID: meetingID) else {
            updateMain {
                self.recordingStatusMessage = "录音太短或未捕获到可保存音频，已保留转写与笔记；请检查输入源后重新录制。"
                self.reviewSourceMediaURL = nil
                self.reviewSourceStatusMessage = "本次没有可播放音频。请检查麦克风或系统音频输入。"
            }
            return nil
        }
        temporaryRecordingURL = recordingURL
        updateMain {
            if expectedVisualMedia {
                self.recordingStatusMessage = "未保存到视频画面，回看将使用音频、转写与笔记。请检查摄像头或屏幕录制权限后重试。"
            } else {
                self.recordingStatusMessage = nil
            }
            self.mediaURL = recordingURL
            self.reviewSourceMediaURL = recordingURL
            self.reviewSourceStatusMessage = nil
        }
        return recordingURL
    }

    private func prepareAudibleReviewSource(meetingID: String) -> URL? {
        _ = try? chunkAssembler.flush(minDurationSec: 0.1)
        return concatenateWAVChunks(meetingID: meetingID)
    }

    private func usableVideoRecordingURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "mkv"].contains(ext) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            return nil
        }
        return url
    }
}
