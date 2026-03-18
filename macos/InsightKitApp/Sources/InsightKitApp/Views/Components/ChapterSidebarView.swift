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

            if dataSource.chapters.isEmpty {
                Spacer()
                Text("录制开始后将显示章节")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                        ForEach(dataSource.chapters) { chapter in
                            chapterRow(chapter)
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
                ScrollView {
                    Text(minutes.structuredSummary)
                        .font(InsightTypography.body)
                        .foregroundStyle(InsightTheme.textSecondary)
                        .padding(.horizontal, InsightSpacing.lg)
                }
            } else if dataSource.canGenerateMinutes {
                Spacer()
                Button("生成智能纪要") {
                    dataSource.onGenerateMinutes()
                }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.accent)
                .padding(.horizontal, InsightSpacing.lg)
                .padding(.bottom, InsightSpacing.lg)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func chapterRow(_ chapter: ChapterSummary) -> some View {
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
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
