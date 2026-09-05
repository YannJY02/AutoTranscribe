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
    private static let reviewNoticeMarkdown = "  - 复核：待复核"

    private struct DocumentContent {
        var lines: [String] = []
        var reviewEntryIndices: Set<Int> = []

        mutating func append(_ line: String, needsReview: Bool = false) {
            if needsReview { reviewEntryIndices.insert(lines.count) }
            lines.append(line)
        }
    }

    private struct ListItem {
        let text: String
        let needsReview: Bool
    }

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
        let document = try renderDocument(metadata: metadata, recordPath: recordPath)
        let markdown = document.lines.joined(separator: "\n")
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
            try writePDF(document: document, to: url)
            return url
        default:
            throw RecordDocumentExportError.unsupportedFormat(format)
        }
    }

    private static func persistedRecordPath(meetingID: String, recordsService: RecordsIndexService?) -> URL? {
        recordsService?.recordFolderURL(for: meetingID)
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
        try renderDocument(metadata: metadata, recordPath: recordPath).lines.joined(separator: "\n")
    }

    private static func renderDocument(metadata: RecordMetadata, recordPath: URL) throws -> DocumentContent {
        let asset = MeetingAssetSnapshot.load(recordPath: recordPath, duration: metadata.duration)
        let minutes = asset.smartMinutes ?? SmartMinutes()
        let transcript = asset.transcriptEntries
        let notes = asset.notes
        let speakers = uniqueSpeakers(from: transcript)
        let title = metadata.displayTitle
        let mediaFile = asset.mediaURL

        var lines = DocumentContent()
        lines.append("# \(title)")
        lines.append("")
        lines.append("- 文档标题：\(title)")
        lines.append("- 记录 ID：\(metadata.id)")
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
        let speakerSummaryItems = minutes.speakerSummaries.isEmpty
            ? speakerSummaries(from: transcript)
            : minutes.speakerSummaries.map { "\($0.speakerName)：\($0.summary)" }
        appendList(title: "## 发言人总结", items: speakerSummaryItems, fallback: "当前本地记录未包含独立发言人总结；已保留逐字稿说话人标签。", to: &lines)
        let decisions = asset.insightPackage?.decisionLedger.map {
            ListItem(text: $0.decision, needsReview: $0.needsReview == true)
        } ?? minutes.keyDecisions.map { ListItem(text: $0, needsReview: false) }
        let actions = asset.insightPackage?.actionTracks.map {
            ListItem(text: $0.task, needsReview: $0.needsReview == true)
        } ?? minutes.actionItems.map { ListItem(text: $0, needsReview: false) }
        appendList(title: "## 关键决策", items: decisions, fallback: "当前记录未包含明确关键决策。", to: &lines)
        appendList(title: "## 待办事项", items: actions, fallback: "当前记录未包含待办事项。", to: &lines)

        lines.append("## 智能章节")
        lines.append("")
        if minutes.chapters.isEmpty {
            lines.append("当前记录未包含智能章节。")
        } else {
            for beat in minutes.chapters {
                lines.append("- [\(formatTimestamp(beat.timestamp))] \(beat.title)：\(beat.summary)")
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
                lines.append("- [\(formatTimestamp(segment.timestamp))] \(exportSpeakerLabel(segment.speaker)): \(segment.text)")
            }
        }
        lines.append("")
        return lines
    }

    private static func itemWithReviewNotice(_ item: String, needsReview: Bool?) -> String {
        needsReview == true ? "\(item)\n\(reviewNoticeMarkdown)" : item
    }

    private static func appendList(title: String, items: [String], fallback: String, to lines: inout DocumentContent) {
        appendList(title: title, items: items.map { ListItem(text: $0, needsReview: false) }, fallback: fallback, to: &lines)
    }

    private static func appendList(title: String, items: [ListItem], fallback: String, to lines: inout DocumentContent) {
        lines.append(title)
        lines.append("")
        if items.isEmpty {
            lines.append(fallback)
        } else {
            for item in items {
                lines.append("- \(itemWithReviewNotice(item.text, needsReview: item.needsReview))", needsReview: item.needsReview)
            }
        }
        lines.append("")
    }

    private static func uniqueSpeakers(from transcript: [TranscriptEntry]) -> [String] {
        Array(Set(transcript.map { exportSpeakerLabel($0.speaker) }.filter { !$0.isEmpty })).sorted()
    }

    private static func speakerSummaries(from transcript: [TranscriptEntry]) -> [String] {
        let grouped = Dictionary(grouping: transcript) { exportSpeakerLabel($0.speaker) }
        return grouped.keys.sorted().map { speaker in
            let segments = grouped[speaker] ?? []
            let seconds = segments.reduce(0.0) { total, segment in
                max(total, segment.timestamp)
            }
            return "\(speaker)：\(segments.count) 条发言，最晚发言时间 \(formatTimestamp(seconds))。"
        }
    }

    private static func exportSpeakerLabel(_ speaker: String?) -> String {
        let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "未标注" : trimmed
    }

    private static func writePDF(document: DocumentContent, to url: URL) throws {
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

        func draw(_ line: PDFLine) {
            line.attributed.draw(
                with: CGRect(x: margin, y: y, width: contentWidth, height: line.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            y += line.height
        }
        func nextPage() {
            endPage()
            beginPage()
        }

        beginPage()
        for block in pdfBlocks(from: document) {
            let lines = block.lines.map { pdfLine($0, width: contentWidth) }
            guard let reviewNotice = block.reviewNotice else {
                for line in lines {
                    if y + line.height > margin + contentHeight { nextPage() }
                    draw(line)
                }
                continue
            }

            let notice = pdfLine(reviewNotice, width: contentWidth)
            let blockHeight = lines.reduce(notice.height) { $0 + $1.height }
            if blockHeight <= contentHeight {
                if y + blockHeight > margin + contentHeight { nextPage() }
                lines.forEach(draw)
                draw(notice)
                continue
            }

            // A flagged item larger than one page keeps its review state on every
            // fragment. Reserve space for the notice before drawing item text.
            let fragments = lines.flatMap { wrappedPDFLines($0, width: contentWidth) }
            var index = 0
            while index < fragments.count {
                if y + fragments[index].height + notice.height > margin + contentHeight { nextPage() }
                repeat {
                    draw(fragments[index])
                    index += 1
                } while index < fragments.count
                    && y + fragments[index].height + notice.height <= margin + contentHeight
                draw(notice)
                if index < fragments.count { nextPage() }
            }
        }
        endPage()
        context.closePDF()
        try data.write(to: url, options: .atomic)
    }

    private struct PDFBlock {
        let lines: [String]
        let reviewNotice: String?
    }

    private struct PDFLine {
        let attributed: NSAttributedString
        let height: CGFloat
    }

    private static func pdfBlocks(from document: DocumentContent) -> [PDFBlock] {
        document.lines.enumerated().flatMap { index, entry in
            var lines = entry.components(separatedBy: "\n")
            // Preserve the original list-entry boundary even when its text has
            // embedded paragraphs or literal review notices. Only payload flags
            // may add repeated review notices when an item spans multiple pages.
            if document.reviewEntryIndices.contains(index) {
                lines.removeLast()
                while lines.count > 1 && lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    lines.removeLast()
                }
                return [PDFBlock(lines: lines, reviewNotice: reviewNoticeMarkdown)]
            }
            return lines.map { PDFBlock(lines: [$0], reviewNotice: nil) }
        }
    }

    private static func pdfLine(_ rawLine: String, width: CGFloat) -> PDFLine {
        let line = rawLine.isEmpty ? " " : rawLine
        let attributed = NSAttributedString(string: line, attributes: attributesForLine(line))
        let height = ceil(attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 5
        return PDFLine(attributed: attributed, height: height)
    }

    private static func wrappedPDFLines(_ line: PDFLine, width: CGFloat) -> [PDFLine] {
        let storage = NSTextStorage(attributedString: line.attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var fragments: [PDFLine] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, range, _ in
            let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            fragments.append(PDFLine(attributed: storage.attributedSubstring(from: characters), height: ceil(rect.height)))
        }
        guard let last = fragments.popLast() else { return [line] }
        fragments.append(PDFLine(attributed: last.attributed, height: last.height + 5))
        return fragments
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
