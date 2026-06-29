import SwiftUI

struct SpeakerRenameRequest: Identifiable {
    let id = UUID()
    let label: String
}

struct SpeakerRenameSheet: View {
    let speaker: String
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var name: String

    init(speaker: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.speaker = speaker
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: speaker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.md) {
            Text("重命名说话人")
                .font(InsightTypography.heading)
                .foregroundStyle(InsightTheme.textPrimary)

            TextField("说话人名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("speaker_rename_field")

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                Button("保存") {
                    onSave(name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("speaker_rename_save_button")
            }
        }
        .padding(InsightSpacing.lg)
        .frame(width: 360)
    }
}
