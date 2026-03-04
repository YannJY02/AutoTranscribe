import SwiftUI

struct ExecutionPanelView: View {
    @Binding var actions: [ActionItem]
    let onStatusChange: (UUID, String) -> Void
    let onOwnerChange: (UUID, String) -> Void
    let onDueAtChange: (UUID, String) -> Void

    private let statusOptions: [(value: String, label: String)] = [
        ("draft", "草稿"),
        ("open", "待处理"),
        ("in_progress", "进行中"),
        ("done", "已完成"),
        ("blocked", "阻塞"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("执行面板")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(InsightTheme.textPrimary)

            ScrollView {
                if actions.isEmpty {
                    Text("等待洞察刷新后生成执行清单…")
                        .foregroundStyle(InsightTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach($actions) { $item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.task)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(InsightTheme.textPrimary)

                                HStack(spacing: 8) {
                                    Text("状态")
                                        .font(.caption)
                                        .foregroundStyle(InsightTheme.textSecondary)
                                    Picker("状态", selection: $item.status) {
                                        ForEach(statusOptions, id: \.value) { option in
                                            Text(option.label).tag(option.value)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 130)
                                    .onChange(of: item.status) { _, newValue in
                                        onStatusChange(item.id, newValue)
                                    }

                                    Spacer()

                                    if item.needsReview {
                                        Text("需复核")
                                            .font(.caption)
                                            .foregroundStyle(InsightTheme.accent)
                                    }
                                }

                                HStack(spacing: 8) {
                                    TextField("负责人", text: $item.owner)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit {
                                            onOwnerChange(item.id, item.owner)
                                        }
                                    TextField("截止时间", text: $item.dueAt)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit {
                                            onDueAtChange(item.id, item.dueAt)
                                        }
                                }

                                Text("优先级：\(item.priority)")
                                    .font(.caption)
                                    .foregroundStyle(InsightTheme.textSecondary)

                                if let evidence = item.evidence {
                                    Text("证据：\(evidence.label)")
                                        .font(.caption)
                                        .foregroundStyle(InsightTheme.textSecondary)
                                }
                            }
                            .quietCard()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
    }
}
