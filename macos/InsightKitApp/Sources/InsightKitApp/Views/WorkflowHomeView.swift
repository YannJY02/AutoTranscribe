import SwiftUI

struct WorkflowHomeView: View {
    let onOpenLive: () -> Void
    let onOpenTranscription: () -> Void
    let onOpenImport: () -> Void
    let onOpenRecords: () -> Void
    let onOpenSettings: () -> Void
    let statusSummary: String
    let recentRecords: [RecordMetadata]

    var body: some View {
        ZStack {
            InsightTheme.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: InsightSpacing.xl) {
                HStack(alignment: .top, spacing: InsightSpacing.md) {
                    VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                        Text("InsightKit")
                            .font(InsightTypography.title)
                            .foregroundStyle(InsightTheme.textPrimary)
                            .accessibilityIdentifier("home_title")
                        Text("选择你的工作流")
                            .font(InsightTypography.body)
                            .foregroundStyle(InsightTheme.textSecondary)
                            .accessibilityIdentifier("home_subtitle")
                    }

                    Spacer()

                    Button {
                        onOpenSettings()
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("打开 Settings Workspace")
                    .accessibilityIdentifier("home_open_settings")
                }

                HStack(spacing: InsightSpacing.lg) {
                    flowCard(
                        icon: "waveform.circle",
                        title: "实时转写",
                        subtitle: "麦克风/系统音频/摄像头/屏幕实时采集，边转写边生成洞察。",
                        accessibilityID: "home_card_live",
                        onTap: onOpenLive
                    )
                    flowCard(
                        icon: "doc.badge.plus",
                        title: "导入转写",
                        subtitle: "导入音视频文件，完成转写后生成智能纪要。",
                        accessibilityID: "home_card_import",
                        onTap: onOpenImport
                    )
                    flowCard(
                        icon: "folder",
                        title: "转写记录",
                        subtitle: "浏览、搜索和管理所有转写记录，标签筛选。",
                        accessibilityID: "home_card_records",
                        onTap: onOpenRecords
                    )
                }

                VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    Text("最近记录")
                        .font(InsightTypography.heading)
                        .foregroundStyle(InsightTheme.textPrimary)
                        .accessibilityIdentifier("home_recent_title")
                    if recentRecords.isEmpty {
                        Text("暂无记录")
                            .font(InsightTypography.caption)
                            .foregroundStyle(InsightTheme.textTertiary)
                            .padding(.vertical, InsightSpacing.lg)
                            .accessibilityIdentifier("home_recent_empty")
                    } else {
                        VStack(spacing: InsightSpacing.sm) {
                            ForEach(recentRecords) { record in
                                Button(action: onOpenRecords) {
                                    HStack(spacing: InsightSpacing.md) {
                                        Image(systemName: record.mediaType == .video ? "video" : "waveform")
                                            .font(.system(size: 18, weight: .medium))
                                            .foregroundStyle(InsightTheme.accent)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(record.displayTitle)
                                                .font(InsightTypography.bodyMedium)
                                                .foregroundStyle(InsightTheme.textPrimary)
                                                .lineLimit(1)
                                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(InsightTypography.small)
                                                .foregroundStyle(InsightTheme.textSecondary)
                                        }
                                        Spacer()
                                        Text(record.source == .live ? "实时" : "导入")
                                            .font(InsightTypography.small)
                                            .foregroundStyle(InsightTheme.textSecondary)
                                    }
                                    .padding(InsightSpacing.sm)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(InsightTheme.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                                            .stroke(InsightTheme.border.opacity(0.65), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home_recent_record_\(record.id)")
                            }
                        }
                        .accessibilityIdentifier("home_recent_records")
                    }
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
        accessibilityID: String = "",
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
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

                Text("进入")
                    .font(InsightTypography.bodyMedium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(InsightTheme.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(InsightSpacing.cardPadding)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .background(InsightTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(InsightTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
        }
        .buttonStyle(.plain)
        .shadow(
            color: InsightShadow.card.color,
            radius: InsightShadow.card.radius,
            y: InsightShadow.card.y
        )
        .accessibilityIdentifier(accessibilityID)
    }
}
