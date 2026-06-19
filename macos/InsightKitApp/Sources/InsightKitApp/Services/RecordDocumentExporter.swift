import AppKit
import Foundation

enum RecordDocumentExportError: LocalizedError {
    case unsupportedFormat(String)
    case missingMetadata
    case pdfContextCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "不支持的导出格式：\(format)"
        case .missingMetadata:
            return "记录元数据缺失。"
        case .pdfContextCreationFailed:
            return "无法创建 PDF 导出上下文。"
        }
    }
}

enum RecordDocumentExporter {
    static func hasPersistedRecord(meetingID: String?, recordsService: RecordsIndexService?) -> Bool {
        guard let meetingID,
              let recordPath = persistedRecordPath(meetingID: meetingID, recordsService: recordsService)
        else { return false }
        return FileManager.default.fileExists(atPath: recordPath.appendingPathComponent("metadata.json").path)
    }

    static func exportIfPersistedRecordExists(
        format: String,
        meetingID: String,
        recordsService: RecordsIndexService?
    ) throws -> URL? {
        guard let recordPath = persistedRecordPath(meetingID: meetingID, recordsService: recordsService) else {
            return nil
        }
        let metadata = try loadMetadata(recordPath: recordPath)
        return try export(format: format, metadata: metadata, recordPath: recordPath)
    }

    static func export(format: String, metadata: RecordMetadata, recordPath: URL) throws -> URL {
        let normalized = format.lowercased()
        let markdown = try renderMarkdown(metadata: metadata, recordPath: recordPath)
        let outputDir = recordPath.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let timestamp = filenameTimestamp()

        switch normalized {
        case "markdown", "md":
            let url = outputDir.appendingPathComponent("\(metadata.id)-\(timestamp).md")
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        case "pdf":
            let url = outputDir.appendingPathComponent("\(metadata.id)-\(timestamp).pdf")
            try writePDF(text: markdown, to: url)
            return url
        default:
            throw RecordDocumentExportError.unsupportedFormat(format)
        }
    }

    private static func persistedRecordPath(meetingID: String, recordsService: RecordsIndexService?) -> URL? {
        guard let root = recordsService?.rootDirectory else { return nil }
        let path = root.appendingPathComponent(meetingID, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return path
    }

    private static func loadMetadata(recordPath: URL) throws -> RecordMetadata {
        let url = recordPath.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url) else {
            throw RecordDocumentExportError.missingMetadata
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(RecordMetadata.self, from: data)
        } catch {
            throw RecordDocumentExportError.missingMetadata
        }
    }

    static func renderMarkdown(metadata: RecordMetadata, recordPath: URL) throws -> String {
        let minutes = loadMinutes(recordPath: recordPath)
        let transcript = loadTranscript(recordPath: recordPath)
        let notes = NotesFileIO.read(from: recordPath.appendingPathComponent("notes.md"))
        let speakers = uniqueSpeakers(from: transcript)
        let title = metadata.summaryPreview?.isEmpty == false ? metadata.summaryPreview! : metadata.id
        let mediaFile = firstExistingFile(
            in: recordPath,
            names: ["recording.mp4", "recording.mov", "recording.mkv", "recording.m4a", "recording.mp3", "recording.wav"]
        )

        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("- 文档标题：\(metadata.id)")
        lines.append("- 会议主题：\(title)")
        lines.append("- 会议时间：\(formatDate(metadata.createdAt))")
        lines.append("- 参会人：\(speakers.isEmpty ? "本地记录未标注参会人；使用说话人标签降级。" : speakers.joined(separator: ", "))")
        lines.append("- 来源：\(metadata.source == .live ? "实时录制" : "导入媒体")")
        lines.append("- 媒体类型：\(metadata.mediaType == .video ? "视频" : "音频")")
        lines.append("- 时长：\(formatDuration(metadata.duration))")
        lines.append("")
        lines.append("> AI 免责声明：以下内容由 InsightKit 根据本地逐字稿和记录文件生成，可能存在识别或总结误差；归档、分享或决策前请回看原始媒体并核对关键事实。")
        lines.append("")

        lines.append("## 长文版结构化总结")
        lines.append("")
        lines.append(minutes.structuredSummary.isEmpty ? "当前记录尚未生成结构化总结。" : minutes.structuredSummary)
        lines.append("")

        appendList(title: "## 会议金句", items: minutes.highlights, fallback: "当前记录未包含会议金句。", to: &lines)
        appendList(title: "## 发言人总结", items: speakerSummaries(from: transcript), fallback: "当前本地记录未包含独立发言人总结；已保留逐字稿说话人标签。", to: &lines)
        appendList(title: "## 关键决策", items: minutes.keyDecisions, fallback: "当前记录未包含明确关键决策。", to: &lines)
        appendList(title: "## 待办事项", items: minutes.actionItems, fallback: "当前记录未包含待办事项。", to: &lines)

        lines.append("## 智能章节")
        lines.append("")
        if minutes.timelineBeats.isEmpty {
            lines.append("当前记录未包含智能章节。")
        } else {
            for beat in minutes.timelineBeats {
                lines.append("- [\(beat.timestamp)] \(beat.title)：\(beat.summary)")
            }
        }
        lines.append("")

        lines.append("## 相关链接")
        lines.append("")
        lines.append("- 原始记录：\(mediaFile?.lastPathComponent ?? "未找到媒体文件")")
        lines.append("- 文字记录：transcript.json")
        lines.append("- 媒体回放：打开本记录文件夹并使用 InsightKit 记录详情页回放")
        lines.append("")

        lines.append("## 时间绑定笔记")
        lines.append("")
        if notes.isEmpty {
            lines.append("当前记录暂无笔记。")
        } else {
            for note in notes.sorted(by: { $0.timestamp < $1.timestamp }) {
                lines.append("- [\(formatTimestamp(note.timestamp))] \(note.text)")
            }
        }
        lines.append("")

        lines.append("## 带时间戳逐字稿")
        lines.append("")
        if transcript.isEmpty {
            lines.append("当前记录未包含逐字稿。")
        } else {
            for segment in transcript {
                lines.append("- [\(formatTimestamp(segment.startSeconds))] \(segment.speaker): \(segment.text)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendList(title: String, items: [String], fallback: String, to lines: inout [String]) {
        lines.append(title)
        lines.append("")
        if items.isEmpty {
            lines.append(fallback)
        } else {
            for item in items {
                lines.append("- \(item)")
            }
        }
        lines.append("")
    }

    private static func loadMinutes(recordPath: URL) -> RecordExportMinutes {
        let url = recordPath.appendingPathComponent("minutes.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return RecordExportMinutes() }

        let timeline = (object["timeline_beats"] as? [[String: Any]] ?? []).map {
            RecordExportTimelineBeat(
                timestamp: $0["timestamp"] as? String ?? "00:00",
                title: $0["title"] as? String ?? "",
                summary: $0["summary"] as? String ?? ""
            )
        }

        return RecordExportMinutes(
            structuredSummary: object["structured_summary"] as? String ?? "",
            highlights: object["highlights"] as? [String] ?? [],
            keyDecisions: object["key_decisions"] as? [String] ?? [],
            actionItems: object["action_items"] as? [String] ?? [],
            timelineBeats: timeline
        )
    }

    private static func loadTranscript(recordPath: URL) -> [RecordExportTranscriptSegment] {
        let url = recordPath.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let text = row["text"] as? String, !text.isEmpty else { return nil }
            return RecordExportTranscriptSegment(
                startSeconds: TimeInterval(row["start_ms"] as? Int ?? 0) / 1000,
                speaker: row["speaker"] as? String ?? "未标注",
                text: text
            )
        }
    }

    private static func uniqueSpeakers(from transcript: [RecordExportTranscriptSegment]) -> [String] {
        Array(Set(transcript.map(\.speaker).filter { !$0.isEmpty })).sorted()
    }

    private static func speakerSummaries(from transcript: [RecordExportTranscriptSegment]) -> [String] {
        let grouped = Dictionary(grouping: transcript, by: \.speaker)
        return grouped.keys.sorted().map { speaker in
            let segments = grouped[speaker] ?? []
            let seconds = segments.reduce(0.0) { total, segment in
                max(total, segment.startSeconds)
            }
            return "\(speaker)：\(segments.count) 条发言，最晚发言时间 \(formatTimestamp(seconds))。"
        }
    }

    private static func firstExistingFile(in directory: URL, names: [String]) -> URL? {
        names
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func writePDF(text: String, to url: URL) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 48
        let contentWidth = pageRect.width - margin * 2
        let contentHeight = pageRect.height - margin * 2
        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw RecordDocumentExportError.pdfContextCreationFailed
        }

        var y = margin
        func beginPage() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageRect.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            y = margin
        }
        func endPage() {
            NSGraphicsContext.current = nil
            context.restoreGState()
            context.endPDFPage()
        }

        beginPage()
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.isEmpty ? " " : rawLine
            let attributes = attributesForLine(line)
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let height = ceil(attributed.boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height) + 5
            if y + height > margin + contentHeight {
                endPage()
                beginPage()
            }
            attributed.draw(
                with: CGRect(x: margin, y: y, width: contentWidth, height: height),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            y += height
        }
        endPage()
        context.closePDF()
        try data.write(to: url, options: .atomic)
    }

    private static func attributesForLine(_ line: String) -> [NSAttributedString.Key: Any] {
        let font: NSFont
        if line.hasPrefix("# ") {
            font = .boldSystemFont(ofSize: 18)
        } else if line.hasPrefix("## ") {
            font = .boldSystemFont(ofSize: 14)
        } else {
            font = .systemFont(ofSize: 11)
        }
        return [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        return style
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
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

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct RecordExportMinutes {
    var structuredSummary: String = ""
    var highlights: [String] = []
    var keyDecisions: [String] = []
    var actionItems: [String] = []
    var timelineBeats: [RecordExportTimelineBeat] = []
}

private struct RecordExportTimelineBeat {
    let timestamp: String
    let title: String
    let summary: String
}

private struct RecordExportTranscriptSegment {
    let startSeconds: TimeInterval
    let speaker: String
    let text: String
}
