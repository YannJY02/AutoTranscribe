import SwiftUI

struct RecordListItemView: View {
    let record: RecordMetadata
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        Button(action: { onSelect?() }) {
            HStack(spacing: InsightSpacing.md) {
                // Type icon
                Image(systemName: record.mediaType == .video ? "video.fill" : "waveform")
                    .font(.system(size: 18))
                    .foregroundStyle(InsightTheme.accent)
                    .frame(width: 32, height: 32)

                // Info
                VStack(alignment: .leading, spacing: InsightSpacing.xs) {
                    Text(record.displayTitle)
                        .font(InsightTypography.bodyMedium)
                        .foregroundStyle(InsightTheme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: InsightSpacing.sm) {
                        Text(formatDuration(record.duration))
                            .font(InsightTypography.caption)
                            .foregroundStyle(InsightTheme.textSecondary)
                        Text(record.source == .live ? "实时" : "导入")
                            .font(InsightTypography.small)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(InsightTheme.surfaceAlt)
                            .clipShape(Capsule())
                            .foregroundStyle(InsightTheme.textTertiary)
                        Text(formatDate(record.createdAt))
                            .font(InsightTypography.caption)
                            .foregroundStyle(InsightTheme.textTertiary)
                    }
                }

                Spacer()

                // Tags
                HStack(spacing: InsightSpacing.xs) {
                    ForEach(record.userTags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(InsightTypography.small)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(InsightTheme.accentLight)
                            .foregroundStyle(InsightTheme.accent)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(InsightSpacing.md)
            .background(InsightTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("record_list_item_\(record.id)")
        .contextMenu {
            Button("打开") { onSelect?() }
            Button("重命名") { onRename?() }
            Button("在访达中显示") { onRevealInFinder?() }
            Divider()
            Button("删除", role: .destructive) { onDelete?() }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
