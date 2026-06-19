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
    func prepareTemporaryRecordingForSave(meetingID: String) -> URL? {
        _ = try? chunkAssembler.flush(minDurationSec: 0.1)
        guard let recordingURL = concatenateWAVChunks(meetingID: meetingID) else {
            updateMain {
                self.recordingStatusMessage = "录音太短或未捕获到可保存音频，已保留转写与笔记；请检查输入源后重新录制。"
            }
            return nil
        }
        temporaryRecordingURL = recordingURL
        updateMain {
            self.recordingStatusMessage = nil
            self.mediaURL = recordingURL
        }
        return recordingURL
    }
}
