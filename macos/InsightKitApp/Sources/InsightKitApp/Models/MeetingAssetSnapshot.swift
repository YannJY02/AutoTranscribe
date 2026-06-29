import Foundation

enum MeetingAssetHealthState: String, Equatable {
    case available
    case missing
    case damaged
    case fallback
}

struct MeetingAssetComponentHealth: Equatable {
    let state: MeetingAssetHealthState
    let source: String?
    let message: String?

    var isReadable: Bool {
        state == .available || state == .fallback
    }

    static func available(source: String) -> MeetingAssetComponentHealth {
        MeetingAssetComponentHealth(state: .available, source: source, message: nil)
    }

    static func missing(source: String, message: String) -> MeetingAssetComponentHealth {
        MeetingAssetComponentHealth(state: .missing, source: source, message: message)
    }

    static func damaged(source: String, message: String) -> MeetingAssetComponentHealth {
        MeetingAssetComponentHealth(state: .damaged, source: source, message: message)
    }

    static func fallback(source: String, message: String) -> MeetingAssetComponentHealth {
        MeetingAssetComponentHealth(state: .fallback, source: source, message: message)
    }
}

struct MeetingAssetHealth: Equatable {
    let metadata: MeetingAssetComponentHealth
    let media: MeetingAssetComponentHealth
    let transcript: MeetingAssetComponentHealth
    let smartMinutes: MeetingAssetComponentHealth
    let notes: MeetingAssetComponentHealth

    var usesFallback: Bool {
        [metadata, media, transcript, smartMinutes, notes].contains { $0.state == .fallback }
    }

    var damagedFiles: [String] {
        [metadata, media, transcript, smartMinutes, notes].compactMap { component in
            component.state == .damaged ? component.source : nil
        }
    }

    var canRecoverTranscript: Bool {
        (transcript.state == .missing || transcript.state == .damaged) && media.isReadable
    }

    var canGenerateSmartMinutes: Bool {
        (smartMinutes.state == .missing || smartMinutes.state == .damaged) && transcript.isReadable
    }

    static let empty = MeetingAssetHealth(
        metadata: .missing(source: "metadata.json", message: "记录元数据缺失。"),
        media: .missing(source: "recording.*", message: "媒体文件缺失。"),
        transcript: .missing(source: "transcript.json", message: "逐字稿缺失。"),
        smartMinutes: .missing(source: "insight_package.json", message: "Smart Minutes 缺失。"),
        notes: .missing(source: "notes.md", message: "时间绑定笔记缺失。")
    )
}

enum MeetingAssetWriteError: LocalizedError {
    case invalidSpeakerRename
    case unreadableTranscript
    case transcriptEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidSpeakerRename:
            return "说话人名称不能为空。"
        case .unreadableTranscript:
            return "无法读取官方 transcript.json。"
        case .transcriptEncodingFailed:
            return "无法写入官方 transcript.json。"
        }
    }
}

struct MeetingAssetSnapshot {
    let mediaURL: URL?
    let transcriptEntries: [TranscriptEntry]
    let notes: [TimestampedNote]
    let insightPackage: InsightPackageV1?
    let smartMinutes: SmartMinutes?
    let chapters: [ChapterSummary]
    let mediaStatusMessage: String?
    let health: MeetingAssetHealth

    typealias DataWriter = (Data, URL) throws -> Void

    static func load(recordPath: URL, duration: TimeInterval) -> MeetingAssetSnapshot {
        let metadataHealth = loadMetadataHealth(from: recordPath)
        let mediaResult = loadMedia(from: recordPath)
        let transcriptResult = loadTranscriptEntries(from: recordPath)
        let notesResult = loadNotes(from: recordPath)
        let smartMinutesResult = loadSmartMinutes(
            from: recordPath,
            duration: duration,
            transcriptEntries: transcriptResult.entries
        )

        let health = MeetingAssetHealth(
            metadata: metadataHealth,
            media: mediaResult.health,
            transcript: transcriptResult.health,
            smartMinutes: smartMinutesResult.health,
            notes: notesResult.health
        )

        return MeetingAssetSnapshot(
            mediaURL: mediaResult.url,
            transcriptEntries: transcriptResult.entries,
            notes: notesResult.notes,
            insightPackage: smartMinutesResult.package,
            smartMinutes: smartMinutesResult.smartMinutes,
            chapters: smartMinutesResult.smartMinutes?.chapters ?? [],
            mediaStatusMessage: mediaResult.health.message,
            health: health
        )
    }

    static func canonicalMediaURL(in recordPath: URL) -> URL? {
        firstExistingFile(
            in: recordPath,
            names: ["recording.mp4", "recording.mov", "recording.mkv", "recording.m4a", "recording.mp3", "recording.wav"]
        )
    }

    static func firstExistingFile(in directory: URL, names: [String]) -> URL? {
        names
            .map { directory.appendingPathComponent($0) }
            .first { isRegularFile($0) }
    }

    static func smartMinutes(from package: InsightPackageV1, duration: TimeInterval) -> SmartMinutes {
        let chapters = package.timelineBeats.map {
            ChapterSummary(
                timestamp: TimestampNormalizer.normalize($0.timestamp, duration: duration),
                title: $0.title,
                summary: $0.summary
            )
        }
        return SmartMinutes(
            structuredSummary: package.sessionOverview.overview,
            highlights: package.highlightInsights.map(\.quote),
            speakerSummaries: package.speakerPerspectives.map {
                SpeakerMinutesSummary(
                    speakerName: $0.speaker,
                    summary: $0.viewpoints.joined(separator: "；")
                )
            },
            keyDecisions: package.decisionLedger.map(\.decision),
            actionItems: package.actionTracks.map(\.task),
            chapters: chapters
        )
    }

    @discardableResult
    static func writeNotes(
        _ notes: [TimestampedNote],
        to recordPath: URL,
        dataWriter: DataWriter = MeetingAssetSnapshot.writeDataAtomically
    ) throws -> URL {
        let url = recordPath.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: recordPath, withIntermediateDirectories: true)
        let data = Data(NotesFileIO.serialize(notes).utf8)
        try dataWriter(data, url)
        return url
    }

    @discardableResult
    static func writeInsightPackage(
        _ package: InsightPackageV1,
        to recordPath: URL,
        dataWriter: DataWriter = MeetingAssetSnapshot.writeDataAtomically
    ) throws -> URL {
        let url = recordPath.appendingPathComponent("insight_package.json")
        try FileManager.default.createDirectory(at: recordPath, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(package)
        try dataWriter(data, url)
        return url
    }

    @discardableResult
    static func writeTranscriptSegments(
        _ segments: [TranscriptSegment],
        to recordPath: URL,
        dataWriter: DataWriter = MeetingAssetSnapshot.writeDataAtomically
    ) throws -> URL {
        let url = recordPath.appendingPathComponent("transcript.json")
        try FileManager.default.createDirectory(at: recordPath, withIntermediateDirectories: true)
        let rows = segments.map { segment in
            [
                "start_ms": segment.startMs,
                "end_ms": segment.endMs,
                "speaker": segment.speaker,
                "source": segment.source,
                "text": segment.text,
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try dataWriter(data, url)
        return url
    }

    @discardableResult
    static func renameSpeaker(
        in recordPath: URL,
        from oldLabel: String,
        to newLabel: String,
        dataWriter: DataWriter = MeetingAssetSnapshot.writeDataAtomically
    ) throws -> Bool {
        let sourceLabel = normalizedSpeakerLabel(oldLabel)
        let replacement = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceLabel.isEmpty, !replacement.isEmpty else {
            throw MeetingAssetWriteError.invalidSpeakerRename
        }

        let transcriptURL = recordPath.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: transcriptURL),
              var rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw MeetingAssetWriteError.unreadableTranscript
        }

        var changed = false
        for index in rows.indices {
            let existing = normalizedSpeakerLabel(rows[index]["speaker"] as? String)
            guard existing == sourceLabel else { continue }
            rows[index]["speaker"] = replacement
            changed = true
        }
        guard changed else { return false }

        guard let output = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else {
            throw MeetingAssetWriteError.transcriptEncodingFailed
        }
        try dataWriter(output, transcriptURL)
        return true
    }

    private static func loadMetadataHealth(from recordPath: URL) -> MeetingAssetComponentHealth {
        let url = recordPath.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing(source: "metadata.json", message: "记录元数据缺失。")
        }
        guard isRegularFile(url),
              let data = try? Data(contentsOf: url)
        else {
            return .damaged(source: "metadata.json", message: "metadata.json 不是可读取的文件。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if (try? decoder.decode(RecordMetadata.self, from: data)) != nil {
            return .available(source: "metadata.json")
        }
        return .damaged(source: "metadata.json", message: "metadata.json 无法解析。")
    }

    private static func loadMedia(from recordPath: URL) -> (url: URL?, health: MeetingAssetComponentHealth) {
        guard let url = canonicalMediaURL(in: recordPath) else {
            return (
                nil,
                .missing(source: "recording.*", message: missingMediaMessage(recordPath: recordPath))
            )
        }
        return (url, .available(source: url.lastPathComponent))
    }

    private static func loadTranscriptEntries(from recordPath: URL) -> (entries: [TranscriptEntry], health: MeetingAssetComponentHealth) {
        let transcriptURL = recordPath.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            return (
                [],
                .missing(source: "transcript.json", message: "官方逐字稿 transcript.json 缺失。")
            )
        }
        guard isRegularFile(transcriptURL),
              let data = try? Data(contentsOf: transcriptURL),
              let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return (
                [],
                .damaged(source: "transcript.json", message: "官方逐字稿 transcript.json 无法解析。")
            )
        }

        let entries: [TranscriptEntry] = segments.compactMap { (dict: [String: Any]) -> TranscriptEntry? in
            guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
            let startMs = intValue(dict["start_ms"]) ?? 0
            return TranscriptEntry(
                timestamp: TimeInterval(startMs) / 1000.0,
                speaker: dict["speaker"] as? String,
                text: text
            )
        }
        return (entries, .available(source: "transcript.json"))
    }

    private static func loadNotes(from recordPath: URL) -> (notes: [TimestampedNote], health: MeetingAssetComponentHealth) {
        let url = recordPath.appendingPathComponent("notes.md")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (
                [],
                .missing(source: "notes.md", message: "时间绑定笔记 notes.md 缺失。")
            )
        }
        guard isRegularFile(url),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            return (
                [],
                .damaged(source: "notes.md", message: "时间绑定笔记 notes.md 无法读取。")
            )
        }
        return (NotesFileIO.parse(content), .available(source: "notes.md"))
    }

    private static func loadSmartMinutes(
        from recordPath: URL,
        duration: TimeInterval,
        transcriptEntries: [TranscriptEntry]
    ) -> (package: InsightPackageV1?, smartMinutes: SmartMinutes?, health: MeetingAssetComponentHealth) {
        let packageURL = recordPath.appendingPathComponent("insight_package.json")
        let legacy = loadFlattenedMinutes(
            from: recordPath,
            duration: duration,
            transcriptEntries: transcriptEntries
        )

        if FileManager.default.fileExists(atPath: packageURL.path) {
            if isRegularFile(packageURL),
               let package = loadInsightPackage(from: recordPath) {
                return (package, smartMinutes(from: package, duration: duration), .available(source: "insight_package.json"))
            }
            if let legacyMinutes = legacy.smartMinutes {
                return (
                    nil,
                    legacyMinutes,
                    .fallback(
                        source: "minutes.json",
                        message: "官方 insight_package.json 无法解析；正在使用旧版 minutes.json。"
                    )
                )
            }
            return (
                nil,
                nil,
                .damaged(source: "insight_package.json", message: "官方 Smart Minutes insight_package.json 无法解析。")
            )
        }

        if let legacyMinutes = legacy.smartMinutes {
            return (
                nil,
                legacyMinutes,
                .fallback(source: "minutes.json", message: "正在使用旧版 minutes.json 作为 Smart Minutes fallback。")
            )
        }
        if legacy.filePresent && legacy.damaged {
            return (
                nil,
                nil,
                .damaged(source: "minutes.json", message: "旧版 Smart Minutes minutes.json 无法解析。")
            )
        }
        return (
            nil,
            nil,
            .missing(source: "insight_package.json", message: "Smart Minutes insight_package.json 缺失。")
        )
    }

    private static func loadInsightPackage(from recordPath: URL) -> InsightPackageV1? {
        let url = recordPath.appendingPathComponent("insight_package.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InsightPackageV1.self, from: data)
    }

    private static func loadFlattenedMinutes(
        from recordPath: URL,
        duration: TimeInterval,
        transcriptEntries: [TranscriptEntry]
    ) -> (smartMinutes: SmartMinutes?, filePresent: Bool, damaged: Bool) {
        let minutesURL = recordPath.appendingPathComponent("minutes.json")
        guard FileManager.default.fileExists(atPath: minutesURL.path) else {
            return (nil, false, false)
        }
        guard isRegularFile(minutesURL),
              let data = try? Data(contentsOf: minutesURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, true, true)
        }

        let summary = (dict["structured_summary"] as? String) ?? ""
        let highlights = (dict["highlights"] as? [String]) ?? []
        let keyDecisions = (dict["key_decisions"] as? [String]) ?? []
        let actionItems = (dict["action_items"] as? [String]) ?? []
        let timeline = (dict["timeline_beats"] as? [[String: Any]]) ?? []

        let loadedChapters = timeline.compactMap { item -> ChapterSummary? in
            let title = (item["title"] as? String) ?? ""
            let body = (item["summary"] as? String) ?? ""
            if title.isEmpty && body.isEmpty { return nil }
            return ChapterSummary(
                timestamp: TimestampNormalizer.normalize((item["timestamp"] as? String) ?? "", duration: duration),
                title: title.isEmpty ? body : title,
                summary: body
            )
        }

        guard !summary.isEmpty || !highlights.isEmpty || !keyDecisions.isEmpty || !actionItems.isEmpty || !loadedChapters.isEmpty else {
            return (nil, true, false)
        }
        return (SmartMinutes(
            structuredSummary: summary,
            highlights: highlights,
            speakerSummaries: speakerSummaries(from: transcriptEntries),
            keyDecisions: keyDecisions,
            actionItems: actionItems,
            chapters: loadedChapters
        ), true, false)
    }

    private static func speakerSummaries(from entries: [TranscriptEntry]) -> [SpeakerMinutesSummary] {
        let grouped = Dictionary(grouping: entries) { entry in
            normalizedSpeakerLabel(entry.speaker)
        }
        return grouped.keys.sorted().map { speaker in
            let speakerEntries = grouped[speaker] ?? []
            let latest = speakerEntries.map(\.timestamp).max() ?? 0
            return SpeakerMinutesSummary(
                speakerName: speaker,
                summary: "\(speakerEntries.count) 条发言，最晚发言时间 \(formatTimestamp(latest))。"
            )
        }
    }

    private static func normalizedSpeakerLabel(_ speaker: String?) -> String {
        let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "未标注" : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func missingMediaMessage(recordPath: URL) -> String {
        "媒体文件缺失：无法回放原始记录。请在 Finder 检查 \(recordPath.lastPathComponent) 中的 recording.* 文件。"
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    private static func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
