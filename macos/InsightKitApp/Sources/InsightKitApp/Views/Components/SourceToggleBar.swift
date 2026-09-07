import SwiftUI

struct SourceToggleItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let label: String
    var isEnabled: Bool
    var disabledReason: String? = nil
}

struct SourceToggleBar: View {
    @Binding var sources: [SourceToggleItem]
    var onSystemAudioSourceSelect: (() -> Void)?

    var body: some View {
        HStack(spacing: InsightSpacing.xl) {
            ForEach($sources) { $source in
                toggleButton(source: $source)
            }
        }
        .padding(.vertical, InsightSpacing.md)
    }

    private func toggleButton(source: Binding<SourceToggleItem>) -> some View {
        VStack(spacing: InsightSpacing.xs) {
            Button {
                source.wrappedValue.isEnabled.toggle()
            } label: {
                Image(systemName: source.wrappedValue.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(
                        source.wrappedValue.isEnabled
                            ? InsightTheme.accent
                            : InsightTheme.textTertiary
                    )
                    .frame(width: 44, height: 44)
                    .background(
                        source.wrappedValue.isEnabled
                            ? InsightTheme.accentLight
                            : InsightTheme.surfaceAlt
                    )
                    .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(source.wrappedValue.disabledReason != nil)
            .help(source.wrappedValue.disabledReason ?? "切换\(source.wrappedValue.label)")
            .accessibilityIdentifier("live_source_toggle_\(source.wrappedValue.id)")
            .accessibilityLabel("\(source.wrappedValue.label)开关")
            .accessibilityValue(source.wrappedValue.isEnabled ? "on" : "off")
            .accessibilityHint(source.wrappedValue.disabledReason ?? "")

            Text(source.wrappedValue.isEnabled ? "on" : "off")
                .font(InsightTypography.small)
                .foregroundStyle(InsightTheme.textTertiary)
                .accessibilityIdentifier("live_source_state_\(source.wrappedValue.id)")
                .accessibilityLabel("\(source.wrappedValue.label)状态")
        }
        .contextMenu {
            if source.wrappedValue.id == "system", let onSystemAudioSourceSelect {
                Button("选择设备...") {
                    onSystemAudioSourceSelect()
                }
            }
        }
    }
}
