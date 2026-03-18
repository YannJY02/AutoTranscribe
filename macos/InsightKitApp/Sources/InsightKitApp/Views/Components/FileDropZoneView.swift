import SwiftUI
import UniformTypeIdentifiers

struct FileDropZoneView: View {
    let supportedTypes: [UTType]
    let onFileSelected: (URL) -> Void
    @State private var isTargeted = false

    init(
        supportedTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .mp3, .wav],
        onFileSelected: @escaping (URL) -> Void
    ) {
        self.supportedTypes = supportedTypes
        self.onFileSelected = onFileSelected
    }

    var body: some View {
        VStack(spacing: InsightSpacing.lg) {
            Spacer()

            VStack(spacing: InsightSpacing.md) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(InsightTheme.textTertiary)

                Text("拖放文件到此处")
                    .font(InsightTypography.heading)
                    .foregroundStyle(InsightTheme.textPrimary)

                Text("或点击选择")
                    .font(InsightTypography.body)
                    .foregroundStyle(InsightTheme.textSecondary)
            }
            .padding(InsightSpacing.xxl)
            .frame(maxWidth: 400)
            .background(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .strokeBorder(
                        isTargeted ? InsightTheme.accent : InsightTheme.border,
                        style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                            .fill(isTargeted ? InsightTheme.accentLight : InsightTheme.surfaceAlt)
                    )
            )
            .onDrop(of: supportedTypes, isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
            .onTapGesture { openFilePicker() }

            VStack(spacing: InsightSpacing.xs) {
                Text("支持格式:")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                Text("音频 mp3 m4a wav  |  视频 mp4 mov mkv")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
            }

            Button("选择文件") { openFilePicker() }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.accent)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async { onFileSelected(url) }
            }
        }
        return true
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            onFileSelected(url)
        }
    }
}
