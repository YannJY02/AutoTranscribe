import SwiftUI

struct SourceToggleItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let label: String
    var isEnabled: Bool
}

struct SourceToggleBar: View {
    @Binding var sources: [SourceToggleItem]
    var onDeviceSelect: ((String) -> Void)?

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
            .contextMenu {
                Button("选择设备...") {
                    onDeviceSelect?(source.wrappedValue.id)
                }
            }

            Text(source.wrappedValue.isEnabled ? "on" : "off")
                .font(InsightTypography.small)
                .foregroundStyle(InsightTheme.textTertiary)
        }
    }
}
