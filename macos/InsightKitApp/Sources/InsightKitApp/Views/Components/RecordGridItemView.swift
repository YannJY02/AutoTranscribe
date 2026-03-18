import SwiftUI

struct RecordGridItemView: View {
    let record: RecordMetadata
    let thumbnailURL: URL?
    var onSelect: (() -> Void)?

    var body: some View {
        Button(action: { onSelect?() }) {
            VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                // Thumbnail
                if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(height: 120)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                } else {
                    RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                        .fill(InsightTheme.canvas)
                        .frame(height: 120)
                        .overlay(
                            Image(systemName: record.mediaType == .video ? "video.fill" : "waveform")
                                .font(.system(size: 28))
                                .foregroundStyle(InsightTheme.textTertiary)
                        )
                }

                // Name
                Text(record.id)
                    .font(InsightTypography.bodyMedium)
                    .foregroundStyle(InsightTheme.textPrimary)
                    .lineLimit(1)

                // Meta
                HStack(spacing: InsightSpacing.sm) {
                    Text(formatDuration(record.duration))
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textSecondary)
                    ForEach(record.userTags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .font(InsightTypography.small)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(InsightTheme.accentLight)
                            .foregroundStyle(InsightTheme.accent)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(InsightSpacing.sm)
            .background(InsightTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
