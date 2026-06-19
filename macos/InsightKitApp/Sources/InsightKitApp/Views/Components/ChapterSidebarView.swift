import SwiftUI

struct ChapterSidebarView<DataSource: ChapterSidebarDataSource>: View {
    @ObservedObject var dataSource: DataSource

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.sm) {
            Text("章节摘要")
                .font(InsightTypography.heading)
                .foregroundStyle(InsightTheme.textPrimary)
                .padding(.horizontal, InsightSpacing.lg)
                .padding(.top, InsightSpacing.lg)
                .accessibilityIdentifier("live_chapters_title")

            if dataSource.chapters.isEmpty {
                Spacer()
                Text("录制开始后将显示章节")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("live_chapters_empty_state")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                        ForEach(Array(dataSource.chapters.enumerated()), id: \.element.id) { index, chapter in
                            chapterRow(chapter, index: index)
                        }
                    }
                    .padding(.horizontal, InsightSpacing.lg)
                }
            }

            if let minutes = dataSource.smartMinutes {
                Divider()
                    .padding(.horizontal, InsightSpacing.lg)
                Text("智能纪要")
                    .font(InsightTypography.heading)
                    .foregroundStyle(InsightTheme.textPrimary)
                    .padding(.horizontal, InsightSpacing.lg)
                    .accessibilityIdentifier("live_smart_minutes_summary_title")
                ScrollView {
                    Text(minutes.structuredSummary)
                        .font(InsightTypography.body)
                        .foregroundStyle(InsightTheme.textSecondary)
                        .padding(.horizontal, InsightSpacing.lg)
                        .accessibilityIdentifier("live_smart_minutes_summary_body")
                }
            } else if dataSource.canGenerateMinutes {
                Spacer()
                Button {
                    dataSource.onGenerateMinutes()
                } label: {
                    Text("生成智能纪要")
                }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.accent)
                .padding(.horizontal, InsightSpacing.lg)
                .padding(.bottom, InsightSpacing.lg)
                .accessibilityIdentifier("live_generate_minutes_sidebar_button")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func chapterRow(_ chapter: ChapterSummary, index: Int) -> some View {
        Button {
            dataSource.onChapterTapped(chapter)
        } label: {
            VStack(alignment: .leading, spacing: InsightSpacing.xs) {
                HStack {
                    Text(formatTimestamp(chapter.timestamp))
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.accent)
                    Text(chapter.title)
                        .font(InsightTypography.bodyMedium)
                        .foregroundStyle(InsightTheme.textPrimary)
                }
                Text(chapter.summary)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .lineLimit(2)
            }
            .padding(InsightSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InsightTheme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("live_chapter_row_\(index)")
        .accessibilityLabel(chapter.title)
        .accessibilityValue(formatTimestamp(chapter.timestamp))
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
