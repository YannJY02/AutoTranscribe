import SwiftUI

struct WorkflowHomeView: View {
    let onOpenLive: () -> Void
    let onOpenTranscription: () -> Void
    let onOpenImport: () -> Void
    let onOpenRecords: () -> Void
    let statusSummary: String

    var body: some View {
        ZStack {
            InsightTheme.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: InsightSpacing.xl) {
                VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    Text("InsightKit")
                        .font(InsightTypography.title)
                        .foregroundStyle(InsightTheme.textPrimary)
                    Text("选择你的工作流")
                        .font(InsightTypography.body)
                        .foregroundStyle(InsightTheme.textSecondary)
                }

                HStack(spacing: InsightSpacing.lg) {
                    flowCard(
                        icon: "waveform.circle",
                        title: "实时转写",
                        subtitle: "麦克风/系统音频/摄像头/屏幕实时采集，边转写边生成洞察。",
                        onTap: onOpenLive
                    )
                    flowCard(
                        icon: "doc.badge.plus",
                        title: "导入转写",
                        subtitle: "导入音视频文件，完成转写后生成智能纪要。",
                        onTap: onOpenImport
                    )
                    flowCard(
                        icon: "folder",
                        title: "转写记录",
                        subtitle: "浏览、搜索和管理所有转写记录，标签筛选。",
                        onTap: onOpenRecords
                    )
                }

                VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    Text("最近记录")
                        .font(InsightTypography.heading)
                        .foregroundStyle(InsightTheme.textPrimary)
                    // Placeholder — Step 7 will populate with RecordsIndexService.recentRecords()
                    Text("暂无记录")
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textTertiary)
                        .padding(.vertical, InsightSpacing.lg)
                }

                if !statusSummary.isEmpty {
                    Text(statusSummary)
                        .font(InsightTypography.small)
                        .foregroundStyle(InsightTheme.textSecondary)
                        .padding(.horizontal, InsightSpacing.md)
                        .padding(.vertical, InsightSpacing.sm)
                        .background(
                            Capsule().fill(InsightTheme.surfaceAlt)
                        )
                        .overlay(
                            Capsule().stroke(InsightTheme.border.opacity(0.5), lineWidth: 1)
                        )
                }
            }
            .padding(InsightSpacing.xxl)
            .frame(maxWidth: 980)
        }
    }

    private func flowCard(
        icon: String,
        title: String,
        subtitle: String,
        onTap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: InsightSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(InsightTheme.textSecondary)

            Text(title)
                .font(InsightTypography.heading)
                .foregroundStyle(InsightTheme.textPrimary)

            Text(subtitle)
                .font(InsightTypography.body)
                .lineSpacing(4)
                .foregroundStyle(InsightTheme.textSecondary)

            Spacer(minLength: InsightSpacing.sm)

            Button(action: onTap) {
                Text("进入")
                    .font(InsightTypography.bodyMedium)
            }
            .buttonStyle(.borderedProminent)
            .tint(InsightTheme.accent)
            .controlSize(.large)
        }
        .padding(InsightSpacing.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(InsightTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                .stroke(InsightTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
        .shadow(
            color: InsightShadow.card.color,
            radius: InsightShadow.card.radius,
            y: InsightShadow.card.y
        )
    }
}
