import SwiftUI
import UniformTypeIdentifiers

struct FileDropZoneView: View {
    let onFileSelected: (URL) -> Void
    @State private var isTargeted = false
    @State private var validationMessage: String?
    @State private var manualPath = ""

    init(onFileSelected: @escaping (URL) -> Void) {
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
                .accessibilityIdentifier("import_choose_file_button")

            HStack(spacing: InsightSpacing.sm) {
                TextField("粘贴本地文件路径…", text: $manualPath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("import_path_field")

                Button("导入路径") { importManualPath() }
                    .buttonStyle(.bordered)
                    .disabled(manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("import_path_button")
            }
            .frame(maxWidth: 400)

            if let validationMessage {
                Text(validationMessage)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import_file_validation_error")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async { handlePickedURL(url) }
            }
        }
        return true
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        SupportedMediaTypes.configureOpenPanel(panel)
        if panel.runModal() == .OK, let url = panel.url {
            handlePickedURL(url)
        }
    }

    private func importManualPath() {
        switch SupportedMediaTypes.validateLocalMediaFileURL(from: manualPath) {
        case .success(let url):
            handlePickedURL(url)
        case .failure(let error):
            validationMessage = error.userMessage
        }
    }

    private var supportedTypes: [UTType] {
        [.fileURL]
    }

    private func handlePickedURL(_ url: URL) {
        guard SupportedMediaTypes.isSupportedFile(url) else {
            validationMessage = "不支持的文件格式：.\(url.pathExtension.lowercased())。请选择 mp3、m4a、wav、mp4、mov 或 mkv。"
            return
        }
        validationMessage = nil
        onFileSelected(url)
    }
}
