import AppKit
import SwiftUI

struct RecordsView: View {
    @ObservedObject var recordsService: RecordsIndexService
    @ObservedObject var recordsNavigation: RecordsWorkspaceNavigation
    private let transcriptRecoveryService: TranscriptRecoveryServicing?
    @State private var searchQuery = ""
    @State private var selectedTags: Set<String> = []
    @State private var selectedType: MediaType?
    @State private var selectedTimeFilter: RecordTimeFilter?
    @State private var selectedRecordID: String?
    @State private var reviewDataSource: RecordReviewDataSource?
    @State private var recordRenameTarget: RecordMetadata?

    init(
        recordsService: RecordsIndexService,
        recordsNavigation: RecordsWorkspaceNavigation = RecordsWorkspaceNavigation(),
        transcriptRecoveryService: TranscriptRecoveryServicing? = nil
    ) {
        self.recordsService = recordsService
        self.recordsNavigation = recordsNavigation
        self.transcriptRecoveryService = transcriptRecoveryService
    }

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
                    center: RecordReviewCenterView(
                        dataSource: dataSource,
                        onRenameRecord: { beginRenameRecord(dataSource.metadata) }
                    ) {
                        recordsNavigation.closeReview()
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
        .onReceive(recordsNavigation.$selectedRecordID) { recordID in
            syncReviewSelection(recordID)
        }
        .sheet(item: $recordRenameTarget) { record in
            RecordRenameSheet(
                record: record,
                onCancel: { recordRenameTarget = nil },
                onSave: { newTitle in
                    commitRecordRename(record, title: newTitle)
                }
            )
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
                            onRename: { beginRenameRecord(record) },
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
        let dataSource = RecordReviewDataSource(
            metadata: record,
            rootDirectory: recordsService.rootDirectory,
            recordPath: recordsService.recordFolderURL(for: record.id),
            transcriptRecoveryService: transcriptRecoveryService
        )
        dataSource.trackOpenAnalytics()
        reviewDataSource = dataSource
        recordsNavigation.openReview(recordID: record.id)
    }

    private func revealRecord(_ record: RecordMetadata) {
        guard let folder = recordsService.recordFolderURL(for: record.id) else { return }
        NSWorkspace.shared.selectFile(folder.path, inFileViewerRootedAtPath: folder.deletingLastPathComponent().path)
    }

    private func beginRenameRecord(_ record: RecordMetadata) {
        recordRenameTarget = record
    }

    private func commitRecordRename(_ record: RecordMetadata, title: String) {
        recordsService.renameRecord(id: record.id, to: title)
        if selectedRecordID == record.id,
           let updated = recordsService.records.first(where: { $0.id == record.id }) {
            reviewDataSource = RecordReviewDataSource(
                metadata: updated,
                rootDirectory: recordsService.rootDirectory,
                recordPath: recordsService.recordFolderURL(for: record.id),
                transcriptRecoveryService: transcriptRecoveryService
            )
        }
        recordRenameTarget = nil
    }

    private func deleteRecord(_ record: RecordMetadata) {
        recordsService.deleteRecord(id: record.id)
        if selectedRecordID == record.id {
            recordsNavigation.closeReview()
        }
    }

    private func syncReviewSelection(_ recordID: String?) {
        guard let recordID else {
            selectedRecordID = nil
            reviewDataSource = nil
            return
        }

        guard selectedRecordID != recordID else { return }
        guard let record = recordsService.records.first(where: { $0.id == recordID }) else {
            recordsNavigation.closeReview()
            return
        }

        selectedRecordID = record.id
        let dataSource = RecordReviewDataSource(
            metadata: record,
            rootDirectory: recordsService.rootDirectory,
            recordPath: recordsService.recordFolderURL(for: record.id),
            transcriptRecoveryService: transcriptRecoveryService
        )
        dataSource.trackOpenAnalytics()
        reviewDataSource = dataSource
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

private struct RecordReviewCenterView: View {
    @ObservedObject var dataSource: RecordReviewDataSource
    let onRenameRecord: () -> Void
    let onBack: () -> Void
    @State private var speakerRenameRequest: SpeakerRenameRequest?

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

                VStack(alignment: .leading, spacing: 2) {
                    Text(dataSource.metadata.displayTitle)
                        .font(InsightTypography.bodyMedium)
                        .foregroundStyle(InsightTheme.textPrimary)
                        .lineLimit(1)
                    Text(dataSource.metadata.id)
                        .font(InsightTypography.small)
                        .foregroundStyle(InsightTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button("重命名") {
                    onRenameRecord()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("record_rename_button")

                Menu {
                    ForEach(dataSource.editableSpeakers, id: \.self) { speaker in
                        Button(speaker) {
                            speakerRenameRequest = SpeakerRenameRequest(label: speaker)
                        }
                    }
                } label: {
                    Label("说话人", systemImage: "person.text.rectangle")
                }
                .disabled(dataSource.editableSpeakers.isEmpty)
                .accessibilityIdentifier("record_speaker_menu")

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
            .sheet(item: $speakerRenameRequest) { request in
                SpeakerRenameSheet(
                    speaker: request.label,
                    onCancel: { speakerRenameRequest = nil },
                    onSave: { newName in
                        dataSource.renameSpeaker(from: request.label, to: newName)
                        speakerRenameRequest = nil
                    }
                )
            }

            if let message = dataSource.exportStatusMessage {
                Text(message)
                    .font(InsightTypography.small)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InsightSpacing.panelPadding)
                    .accessibilityIdentifier("record_export_status")
            }

            if let url = dataSource.mediaURL {
                ReviewMediaPlayerView(
                    url: url,
                    mediaKind: ReviewMediaKind(recordMediaType: dataSource.metadata.mediaType),
                    seekRequest: dataSource.mediaSeekRequest,
                    maximumVideoHeight: 360,
                    accessibilityID: "record_media_player",
                    onSeek: { time in dataSource.onSeek(to: time) },
                    onTimeUpdate: { time in dataSource.updatePlaybackTime(time) }
                )
                .padding(.horizontal, InsightSpacing.panelPadding)

                if let presentationStatus = dataSource.presentationStatusMessage {
                    HStack(alignment: .top, spacing: InsightSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(InsightTheme.warning)
                        Text(presentationStatus)
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
                    .accessibilityIdentifier("record_presentation_status")
                }

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

                    if dataSource.canRecoverTranscript || dataSource.transcriptRecoveryStatusMessage != nil {
                        HStack(alignment: .center, spacing: InsightSpacing.sm) {
                            Image(systemName: "arrow.clockwise.circle")
                                .foregroundStyle(InsightTheme.accent)
                            Text(dataSource.transcriptRecoveryStatusMessage ?? "逐字稿缺失，可从已保存媒体恢复。")
                                .font(InsightTypography.caption)
                                .foregroundStyle(InsightTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button {
                                dataSource.recoverTranscript()
                            } label: {
                                Label("恢复逐字稿", systemImage: "text.badge.checkmark")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!dataSource.canRecoverTranscript)
                            .accessibilityIdentifier("record_recover_transcript_button")
                        }
                        .padding(InsightSpacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(InsightTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                        .accessibilityIdentifier("record_transcript_recovery_status")
                    }

                    ForEach(Array(dataSource.transcriptEntries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .top, spacing: InsightSpacing.sm) {
                            Button {
                                dataSource.onTranscriptEntryTapped(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: InsightSpacing.xs) {
                                    HStack(spacing: InsightSpacing.sm) {
                                        Text(formatTimestamp(entry.timestamp))
                                            .font(InsightTypography.caption)
                                            .foregroundStyle(InsightTheme.accent)
                                        if let speaker = visibleSpeaker(for: entry) {
                                            Text(speaker)
                                                .font(InsightTypography.caption)
                                                .foregroundStyle(InsightTheme.textSecondary)
                                        }
                                    }
                                    Text(entry.text)
                                        .font(InsightTypography.transcript)
                                        .foregroundStyle(InsightTheme.textPrimary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            if let action = RecordSpeakerRenamePresentation.rowAction(for: entry) {
                                Button {
                                    speakerRenameRequest = SpeakerRenameRequest(label: action.speakerLabel)
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help("重命名说话人")
                                .accessibilityLabel("重命名说话人 \(action.speakerLabel)")
                                .accessibilityIdentifier("\(action.accessibilityID)_\(index)")
                            }
                        }
                        .padding(InsightSpacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(InsightTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                        .contextMenu {
                            if let speaker = RecordSpeakerRenamePresentation.rowAction(for: entry)?.speakerLabel {
                                Button("重命名说话人") {
                                    speakerRenameRequest = SpeakerRenameRequest(label: speaker)
                                }
                            }
                        }
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

    private func visibleSpeaker(for entry: TranscriptEntry) -> String? {
        RecordSpeakerRenamePresentation.rowAction(for: entry)?.speakerLabel
    }
}

private struct RecordRenameSheet: View {
    let record: RecordMetadata
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var title: String

    init(record: RecordMetadata, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.record = record
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: record.displayTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.md) {
            Text("重命名记录")
                .font(InsightTypography.heading)
                .foregroundStyle(InsightTheme.textPrimary)

            TextField("记录名称", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("record_rename_field")

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                Button("保存") {
                    onSave(title)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("record_rename_save_button")
            }
        }
        .padding(InsightSpacing.lg)
        .frame(width: 380)
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
