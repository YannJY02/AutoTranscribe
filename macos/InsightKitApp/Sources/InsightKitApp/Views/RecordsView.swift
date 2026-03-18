import AppKit
import SwiftUI

struct RecordsView: View {
    @ObservedObject var recordsService: RecordsIndexService
    @State private var searchQuery = ""
    @State private var selectedTags: Set<String> = []
    @State private var selectedType: MediaType?
    @State private var selectedRecordID: String?
    @State private var reviewDataSource: RecordReviewDataSource?

    var body: some View {
        HSplitView {
            // Left sidebar
            RecordsSidebarView(
                searchQuery: $searchQuery,
                selectedTags: $selectedTags,
                selectedType: $selectedType,
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
                    center: reviewCenter(dataSource: dataSource),
                    right: TimestampNotesEditor(dataSource: dataSource)
                )
            } else {
                recordList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(InsightTheme.canvas)
            }
        }
        .background(InsightTheme.canvas)
        .onAppear {
            recordsService.refreshIndex()
        }
    }

    // MARK: - Filtered Records

    private var filteredRecords: [RecordMetadata] {
        var result = recordsService.records

        if !searchQuery.isEmpty {
            result = recordsService.searchRecords(query: searchQuery)
        }

        if !selectedTags.isEmpty || selectedType != nil {
            result = result.filter { record in
                let matchesTags = selectedTags.isEmpty
                    || !selectedTags.isDisjoint(with: Set(record.userTags + record.autoTags))
                let matchesType = selectedType == nil || record.mediaType == selectedType
                return matchesTags && matchesType
            }
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
            }
        }
    }

    // MARK: - Review Center

    private func reviewCenter(dataSource: RecordReviewDataSource) -> some View {
        VStack(spacing: InsightSpacing.panelGap) {
            // Back button
            HStack {
                Button {
                    reviewDataSource = nil
                    selectedRecordID = nil
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
            }
            .padding(.horizontal, InsightSpacing.panelPadding)
            .padding(.top, InsightSpacing.md)

            // Media player
            if let url = dataSource.mediaURL {
                MediaPlayerView(
                    url: url,
                    isPlaying: false,
                    onSeek: { time in dataSource.onSeek(to: time) },
                    onTimeUpdate: { time in dataSource.currentPlaybackTime = time }
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180, maxHeight: 260)
                .padding(.horizontal, InsightSpacing.panelPadding)
            }

            // Transcript
            ScrollView {
                LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    ForEach(dataSource.transcriptEntries) { entry in
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
                    }
                }
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.vertical, InsightSpacing.sm)
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
