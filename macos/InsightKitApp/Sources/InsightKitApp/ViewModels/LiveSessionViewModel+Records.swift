import Foundation

extension LiveSessionViewModel {

    // MARK: - Save to Records

    /// Called after stopLiveSession completes. Serializes transcript + insight
    /// and calls the records.save RPC to persist the record folder via Python RecordWriter.
    func saveToRecords(meetingID: String) {
        // Capture @Published state on the calling thread to avoid data races.
        // These properties are mutated on main; reading them here (pipelineQueue)
        // is safe because stopLiveSession already stopped all producers and
        // updated UI state before invoking this method.
        let capturedSegments = self.transcriptSegments
        let capturedPackage = self.lastInsightPackage
        let capturedRecordingURL = self.temporaryRecordingURL
        let capturedDuration = self.recordingDuration
        let capturedNotes = self.notes

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

    // MARK: - WAV chunk concatenation (audio-only fallback)

    /// Concatenate all WAV chunk files produced by ChunkAssembler into a single file.
    /// Returns the URL of the concatenated file, or nil if no chunks exist.
    func concatenateWAVChunks(meetingID: String) -> URL? {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InsightKit")
            .appendingPathComponent(meetingID)
        let outputURL = tmpDir.appendingPathComponent("recording.wav")

        // Collect all WAV files in the tmp dir sorted by name (chunk index order)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) else { return nil }

        let wavFiles = files
            .filter { $0.pathExtension.lowercased() == "wav" && $0.lastPathComponent != "recording.wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !wavFiles.isEmpty else { return nil }

        // If only one file, just rename it
        if wavFiles.count == 1 {
            try? FileManager.default.moveItem(at: wavFiles[0], to: outputURL)
            return outputURL
        }

        // Read first file to get format header (44 bytes for standard WAV)
        guard let firstData = try? Data(contentsOf: wavFiles[0]), firstData.count > 44 else {
            return nil
        }

        var combined = Data()
        var totalPCMBytes: Int = 0

        for file in wavFiles {
            guard let data = try? Data(contentsOf: file), data.count > 44 else { continue }
            combined.append(data.subdata(in: 44..<data.count))
            totalPCMBytes += data.count - 44
        }

        // Rebuild WAV header with correct total size
        var header = firstData.subdata(in: 0..<44)
        let fileSize = UInt32(44 + totalPCMBytes - 8)
        let dataSize = UInt32(totalPCMBytes)
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        var result = header
        result.append(combined)

        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try? result.write(to: outputURL)
        return outputURL
    }
}
