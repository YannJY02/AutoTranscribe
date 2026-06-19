import AppKit
import SwiftUI

struct RecordsView: View {
    @ObservedObject var recordsService: RecordsIndexService
    @State private var searchQuery = ""
    @State private var selectedTags: Set<String> = []
    @State private var selectedType: MediaType?
    @State private var selectedTimeFilter: RecordTimeFilter?
    @State private var selectedRecordID: String?
    @State private var reviewDataSource: RecordReviewDataSource?

    var body: some View {
        HSplitView {
            // Left sidebar
            RecordsSidebarView(
                searchQuery: $searchQuery,
                selectedTags: $selectedTags,
                selectedType: $selectedType,
                selectedTimeFilter: $selectedTimeFilter,
                allTags: recordsService.allTags(),
                recordCount: filteredRecords.count
            )
            .frame(minWidth: 220, maxWidth: 280)
            .background(InsightTheme.surface)

            // Right content
            if let dataSource = reviewDataSource {
                // Three-panel preview
                SessionShellFixed(
                    left: ChapterSidebarView(dataSource: dataSource),
	                    center: RecordReviewCenterView(dataSource: dataSource) {
	                        reviewDataSource = nil
	                        selectedRecordID = nil
	                    },
	                    right: TimestampNotesEditor(
	                        dataSource: dataSource,
	                        autofocusInput: false,
	                        autoScrollToPlaybackTime: false
	                    )
	                )
            } else {
                recordList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(InsightTheme.canvas)
            }
        }
        .background(InsightTheme.canvas)
        .onAppear {
            recordsService.refreshIndexAsync()
        }
    }

    // MARK: - Filtered Records

    private var filteredRecords: [RecordMetadata] {
        var result = recordsService.records

        if !searchQuery.isEmpty {
            result = recordsService.searchRecords(query: searchQuery)
        }

        if !selectedTags.isEmpty || selectedType != nil || selectedTimeFilter != nil {
            let criteria = RecordFilterCriteria(
                tags: selectedTags,
                type: selectedType,
                timeFilter: selectedTimeFilter
            )
            let matchingIDs = Set(recordsService.filterRecords(criteria: criteria).map(\.id))
            result = result.filter { matchingIDs.contains($0.id) }
        }

        return result
    }

    // MARK: - Record List

    private var recordList: some View {
        ScrollView {
            if filteredRecords.isEmpty {
                VStack(spacing: InsightSpacing.lg) {
                    Spacer(minLength: 80)
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundStyle(InsightTheme.textTertiary)
                    Text("暂无转写记录")
                        .font(InsightTypography.heading)
                        .foregroundStyle(InsightTheme.textSecondary)
                    Text("完成实时转写或导入转写后，记录将显示在这里")
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("records_empty_state")
            } else {
                LazyVStack(spacing: InsightSpacing.sm) {
                    ForEach(filteredRecords) { record in
                        RecordListItemView(
                            record: record,
                            onSelect: { selectRecord(record) },
                            onRevealInFinder: { revealRecord(record) },
                            onDelete: { deleteRecord(record) }
                        )
                    }
                }
                .padding(InsightSpacing.lg)
                .accessibilityIdentifier("records_list")
            }
        }
    }

    // MARK: - Actions

    private func selectRecord(_ record: RecordMetadata) {
        selectedRecordID = record.id
        reviewDataSource = RecordReviewDataSource(
            metadata: record,
            rootDirectory: recordsService.rootDirectory
        )
    }

    private func revealRecord(_ record: RecordMetadata) {
        let folder = recordsService.rootDirectory.appendingPathComponent(record.id)
        NSWorkspace.shared.selectFile(folder.path, inFileViewerRootedAtPath: folder.deletingLastPathComponent().path)
    }

    private func deleteRecord(_ record: RecordMetadata) {
        recordsService.deleteRecord(id: record.id)
        if selectedRecordID == record.id {
            selectedRecordID = nil
            reviewDataSource = nil
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

private struct RecordReviewCenterView: View {
    @ObservedObject var dataSource: RecordReviewDataSource
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: InsightSpacing.panelGap) {
            HStack {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: InsightSpacing.xs) {
                        Image(systemName: "chevron.left")
                        Text("返回列表")
                    }
                    .font(InsightTypography.bodyMedium)
                    .foregroundStyle(InsightTheme.accent)
                }
                .buttonStyle(.plain)
                Spacer()

                Button("在访达中显示") {
                    dataSource.revealInFinder()
                }
                .buttonStyle(.bordered)

                Button("导出 Markdown") {
                    dataSource.exportRecord(format: "markdown")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("record_export_markdown_button")

                Button("导出 PDF") {
                    dataSource.exportRecord(format: "pdf")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("record_export_pdf_button")
            }
            .padding(.horizontal, InsightSpacing.panelPadding)
            .padding(.top, InsightSpacing.md)

            if let message = dataSource.exportStatusMessage {
                Text(message)
                    .font(InsightTypography.small)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InsightSpacing.panelPadding)
                    .accessibilityIdentifier("record_export_status")
            }

            if let url = dataSource.mediaURL {
                MediaPlayerView(
                    url: url,
	                    isPlaying: false,
	                    seekRequest: dataSource.mediaSeekRequest,
	                    onSeek: { time in dataSource.onSeek(to: time) },
	                    onTimeUpdate: { time in dataSource.updatePlaybackTime(time) }
	                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180, maxHeight: 260)
                .padding(.horizontal, InsightSpacing.panelPadding)
                .accessibilityIdentifier("record_media_player")

                if let seekStatus = dataSource.seekStatusMessage {
                    Text(seekStatus)
                        .font(InsightTypography.small)
                        .foregroundStyle(InsightTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, InsightSpacing.panelPadding)
                        .accessibilityIdentifier("record_media_seek_status")
                }
            } else if let message = dataSource.mediaStatusMessage {
                HStack(alignment: .top, spacing: InsightSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(InsightTheme.warning)
                    Text(message)
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(InsightSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(InsightTheme.warningSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                        .stroke(InsightTheme.warningBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                .padding(.horizontal, InsightSpacing.panelPadding)
                .accessibilityIdentifier("record_media_missing_status")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    if let smartMinutes = dataSource.smartMinutesData {
                        RecordSmartMinutesOverviewView(
                            minutes: smartMinutes,
                            onChapterTapped: { chapter in
                                dataSource.onChapterTapped(chapter)
                            }
                        )
                    }

                    Text("带时间戳逐字稿")
                        .font(InsightTypography.heading)
                        .foregroundStyle(InsightTheme.textPrimary)
                        .padding(.top, dataSource.smartMinutesData == nil ? 0 : InsightSpacing.md)
                        .accessibilityIdentifier("record_transcript_title")

                    ForEach(Array(dataSource.transcriptEntries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            dataSource.onTranscriptEntryTapped(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: InsightSpacing.xs) {
                                HStack(spacing: InsightSpacing.sm) {
                                    Text(formatTimestamp(entry.timestamp))
                                        .font(InsightTypography.caption)
                                        .foregroundStyle(InsightTheme.accent)
                                    if let speaker = entry.speaker, !speaker.isEmpty {
                                        Text(speaker)
                                            .font(InsightTypography.caption)
                                            .foregroundStyle(InsightTheme.textSecondary)
                                    }
                                }
                                Text(entry.text)
                                    .font(InsightTypography.transcript)
                                    .foregroundStyle(InsightTheme.textPrimary)
                            }
                            .padding(InsightSpacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(InsightTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("record_transcript_row_\(index)")
                    }
                }
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.vertical, InsightSpacing.sm)
            }
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

private struct RecordSmartMinutesOverviewView: View {
    let minutes: SmartMinutes
    let onChapterTapped: (ChapterSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.md) {
            HStack(spacing: InsightSpacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(InsightTheme.accent)
                Text("智能纪要")
                    .font(InsightTypography.heading)
                    .foregroundStyle(InsightTheme.textPrimary)
                    .accessibilityIdentifier("record_smart_minutes_overview")
                Spacer()
            }

            RecordMinutesTextSection(
                title: "总结",
                text: minutes.structuredSummary,
                fallback: "当前记录尚未生成结构化总结。",
                accessibilityID: "record_minutes_summary_section"
            )

            RecordMinutesListSection(
                title: "会议金句",
                items: minutes.highlights,
                fallback: "当前记录未包含会议金句。",
                accessibilityID: "record_minutes_highlights_section"
            )

            RecordMinutesSpeakerSection(
                speakers: minutes.speakerSummaries,
                accessibilityID: "record_minutes_speakers_section"
            )

            RecordMinutesListSection(
                title: "关键决策",
                items: minutes.keyDecisions,
                fallback: "当前记录未包含明确关键决策。",
                accessibilityID: "record_minutes_decisions_section"
            )

            RecordMinutesListSection(
                title: "待办事项",
                items: minutes.actionItems,
                fallback: "当前记录未包含待办事项。",
                accessibilityID: "record_minutes_actions_section"
            )

            RecordMinutesChapterSection(
                chapters: minutes.chapters,
                onChapterTapped: onChapterTapped,
                accessibilityID: "record_minutes_chapters_section"
            )
        }
        .padding(InsightSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InsightTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
    }
}

private struct RecordMinutesTextSection: View {
    let title: String
    let text: String
    let fallback: String
    let accessibilityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.xs) {
            Text(title)
                .font(InsightTypography.bodyMedium)
                .foregroundStyle(InsightTheme.textPrimary)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text)
                .font(InsightTypography.body)
                .foregroundStyle(InsightTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct RecordMinutesListSection: View {
    let title: String
    let items: [String]
    let fallback: String
    let accessibilityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.xs) {
            Text(title)
                .font(InsightTypography.bodyMedium)
                .foregroundStyle(InsightTheme.textPrimary)
            if items.isEmpty {
                Text(fallback)
                    .font(InsightTypography.body)
                    .foregroundStyle(InsightTheme.textSecondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: InsightSpacing.sm) {
                        Circle()
                            .fill(InsightTheme.accent.opacity(0.65))
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(item)
                            .font(InsightTypography.body)
                            .foregroundStyle(InsightTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct RecordMinutesSpeakerSection: View {
    let speakers: [SpeakerMinutesSummary]
    let accessibilityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.xs) {
            Text("发言人总结")
                .font(InsightTypography.bodyMedium)
                .foregroundStyle(InsightTheme.textPrimary)
            if speakers.isEmpty {
                Text("当前本地记录未包含独立发言人总结；已保留逐字稿说话人标签。")
                    .font(InsightTypography.body)
                    .foregroundStyle(InsightTheme.textSecondary)
            } else {
                ForEach(speakers) { speaker in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.speakerName)
                            .font(InsightTypography.caption)
                            .foregroundStyle(InsightTheme.accent)
                        Text(speaker.summary)
                            .font(InsightTypography.body)
                            .foregroundStyle(InsightTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct RecordMinutesChapterSection: View {
    let chapters: [ChapterSummary]
    let onChapterTapped: (ChapterSummary) -> Void
    let accessibilityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.xs) {
            Text("智能章节")
                .font(InsightTypography.bodyMedium)
                .foregroundStyle(InsightTheme.textPrimary)
                .accessibilityIdentifier(accessibilityID)
            if chapters.isEmpty {
                Text("当前记录未包含智能章节。")
                    .font(InsightTypography.body)
                    .foregroundStyle(InsightTheme.textSecondary)
            } else {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        onChapterTapped(chapter)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(formatTimestamp(chapter.timestamp))  \(chapter.title)")
                                .font(InsightTypography.caption)
                                .foregroundStyle(InsightTheme.accent)
                            Text(chapter.summary)
                                .font(InsightTypography.body)
                                .foregroundStyle(InsightTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("record_minutes_chapter_row_\(index)")
                }
            }
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
