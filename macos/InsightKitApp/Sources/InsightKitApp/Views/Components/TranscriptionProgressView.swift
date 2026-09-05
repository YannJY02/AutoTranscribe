import SwiftUI

struct TranscriptionProgressView: View {
    let progress: Double
    let elapsedTime: TimeInterval
    let sourceMediaDuration: TimeInterval?

    var elapsedTimeText: String { "已用时 \(formatTime(elapsedTime))" }

    var mediaDurationText: String {
        guard let duration = sourceMediaDuration, duration.isFinite, duration > 0 else {
            return "媒体时长 未知"
        }
        return "媒体时长 \(formatTime(duration))"
    }

    var body: some View {
        VStack(spacing: InsightSpacing.sm) {
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(InsightTheme.accent)

            HStack {
                Text(String(format: "%.0f%%", progress * 100))
                    .font(InsightTypography.bodyMedium)
                    .foregroundStyle(InsightTheme.textPrimary)
                Spacer()
                Text(elapsedTimeText)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
                Text(mediaDurationText)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
            }
        }
        .padding(.horizontal, InsightSpacing.lg)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
