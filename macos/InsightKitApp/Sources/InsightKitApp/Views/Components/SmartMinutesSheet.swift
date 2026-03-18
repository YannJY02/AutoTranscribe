import SwiftUI

struct SmartMinutesSheet: View {
    let duration: TimeInterval
    let onGenerate: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: InsightSpacing.xl) {
            Text("录制已完成 (\(formattedDuration))")
                .font(InsightTypography.title)
                .foregroundStyle(InsightTheme.textPrimary)

            Text("是否生成智能纪要？")
                .font(InsightTypography.heading)
                .foregroundStyle(InsightTheme.textPrimary)

            VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                Text("智能纪要将包含：")
                    .font(InsightTypography.body)
                    .foregroundStyle(InsightTheme.textSecondary)
                ForEach(minutesItems, id: \.self) { item in
                    HStack(spacing: InsightSpacing.sm) {
                        Circle()
                            .fill(InsightTheme.accent)
                            .frame(width: 5, height: 5)
                        Text(item)
                            .font(InsightTypography.body)
                            .foregroundStyle(InsightTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, InsightSpacing.xl)

            HStack(spacing: InsightSpacing.lg) {
                Button("跳过") { onSkip() }
                    .buttonStyle(.bordered)
                Button("生成纪要") { onGenerate() }
                    .buttonStyle(.borderedProminent)
                    .tint(InsightTheme.accent)
            }
        }
        .padding(InsightSpacing.xxl)
        .frame(width: 400)
        .background(InsightTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
        .shadow(
            color: InsightShadow.elevated.color,
            radius: InsightShadow.elevated.radius,
            y: InsightShadow.elevated.y
        )
    }

    private var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private let minutesItems = [
        "结构化总结",
        "会议金句",
        "发言人总结",
        "关键决策",
        "待办事项",
        "智能章节",
    ]
}
