import SwiftUI

struct WorkflowHomeView: View {
    let onOpenLive: () -> Void
    let onOpenTranscription: () -> Void
    let statusSummary: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [InsightTheme.background, InsightTheme.panelElevated.opacity(0.94)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("会议工作流")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(InsightTheme.textPrimary)
                    Text("选择你的工作流：实时语音总结或转写总结。")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(InsightTheme.textSecondary)
                    if !statusSummary.isEmpty {
                        Text(statusSummary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(InsightTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(InsightTheme.panelElevated)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(InsightTheme.border.opacity(0.5), lineWidth: 1)
                            )
                            .padding(.top, 4)
                    }
                }

                HStack(spacing: 16) {
                    flowCard(
                        title: "实时语音总结",
                        subtitle: "麦克风/系统音频实时采集，边转写边生成洞察。",
                        actionTitle: "进入实时工作台",
                        onTap: onOpenLive
                    )

                    flowCard(
                        title: "转写总结",
                        subtitle: "导入音视频或监听目录，完成转写后生成定稿洞察。",
                        actionTitle: "进入转写工作台",
                        onTap: onOpenTranscription
                    )
                }
            }
            .padding(32)
            .frame(maxWidth: 980)
        }
    }

    private func flowCard(
        title: String,
        subtitle: String,
        actionTitle: String,
        onTap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(InsightTheme.textPrimary)

            Text(subtitle)
                .font(.system(size: 14, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(InsightTheme.textSecondary)

            Spacer(minLength: 8)

            Button(actionTitle, action: onTap)
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.accent)
                .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(InsightTheme.panelElevated)
        .overlay(
            RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                .stroke(InsightTheme.border.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
    }
}
