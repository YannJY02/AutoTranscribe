import SwiftUI
import UniformTypeIdentifiers

/// Center panel for the import transcription workspace.
/// Switches content based on session phase: selecting → processing → reviewing.
struct ImportCenterView<DataSource: CenterStageDataSource>: View {
    @ObservedObject var dataSource: DataSource
    let importViewModel: ImportSessionViewModel
    var onFilePicked: ((URL) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            switch dataSource.phase {
            case .selecting:
                selectingView
            case .processing:
                processingView
            case .reviewing:
                reviewingView
            case .preparing, .running, .postSession:
                // Live-specific phases — not used in import
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InsightTheme.surfaceAlt)
    }

    // MARK: - Selecting Phase

    private var selectingView: some View {
        VStack(spacing: InsightSpacing.xl) {
            Spacer()
            importErrorStatus
            FileDropZoneView(
                onFileSelected: { url in
                    onFilePicked?(url)
                }
            )
            .frame(maxWidth: 500, maxHeight: 300)
            .accessibilityIdentifier("import_file_drop_zone")
            Spacer()
        }
        .padding(InsightSpacing.panelPadding)
    }

    // MARK: - Processing Phase

    private var processingView: some View {
        VStack(spacing: InsightSpacing.panelGap) {
            importErrorStatus
                .padding(.top, InsightSpacing.panelPadding)

            importAnalysisStatus
                .padding(.horizontal, InsightSpacing.panelPadding)

            // Media player (can play while processing)
            if let url = dataSource.mediaURL {
                ReviewMediaPlayerView(
                    url: url,
                    maximumVideoHeight: 320,
                    accessibilityID: "import_processing_media_player",
                    onTimeUpdate: { time in
                        importViewModel.currentPlaybackTime = time
                    }
                )
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.top, InsightSpacing.panelPadding)
            }

            // Progress
            TranscriptionProgressView(
                progress: importViewModel.importProgress,
                elapsedTime: importViewModel.importElapsed,
                sourceMediaDuration: importViewModel.sourceMediaDuration
            )
            .padding(.horizontal, InsightSpacing.panelPadding)

            importProcessingStatus
                .padding(.horizontal, InsightSpacing.panelPadding)

            // Live transcript entries
            transcriptList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Reviewing Phase

    private var reviewingView: some View {
        VStack(spacing: InsightSpacing.panelGap) {
            importAnalysisStatus
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.top, InsightSpacing.panelPadding)

            // Media player
            if let url = dataSource.mediaURL {
                ReviewMediaPlayerView(
                    url: url,
                    isPlaying: true,
                    seekRequest: importViewModel.mediaSeekRequest,
                    maximumVideoHeight: 320,
                    accessibilityID: "import_review_media_player",
                    onSeek: { time in
                        dataSource.onSeek(to: time)
                    },
                    onTimeUpdate: { time in
                        importViewModel.currentPlaybackTime = time
                    }
                )
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.top, InsightSpacing.panelPadding)
            }

            // Full transcript
            transcriptList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Action bar
            HStack(spacing: InsightSpacing.lg) {
                Button("在访达中显示") {
                    importViewModel.revealInFinder()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("导出 Markdown") {
                    importViewModel.exportDocument(format: "markdown")
                }
                .buttonStyle(.bordered)
                .disabled(importViewModel.isExporting)
                .accessibilityIdentifier("import_export_markdown_button")

                Button("导出 PDF") {
                    importViewModel.exportDocument(format: "pdf")
                }
                .buttonStyle(.bordered)
                .disabled(importViewModel.isExporting)
                .accessibilityIdentifier("import_export_pdf_button")

                Button("新建导入") {
                    importViewModel.resetToSelecting()
                }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.accent)
                .disabled(importViewModel.isExporting)
            }
            .padding(.horizontal, InsightSpacing.panelPadding)
            .padding(.vertical, InsightSpacing.md)
            .background(InsightTheme.surface)

            if let message = importViewModel.exportStatusMessage {
                Text(message)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InsightSpacing.panelPadding)
                    .accessibilityIdentifier("import_export_status")
            }
        }
    }

    // MARK: - Shared Transcript List

    @ViewBuilder
    private var importErrorStatus: some View {
        if let message = importViewModel.visibleErrorStatusMessage {
            HStack(alignment: .top, spacing: InsightSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(InsightTheme.error)
                Text(message)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(InsightSpacing.md)
            .frame(maxWidth: 520, alignment: .leading)
            .background(InsightTheme.errorSurface)
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(InsightTheme.errorBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .accessibilityIdentifier("import_error_status")
        }
    }

    @ViewBuilder
    private var importProcessingStatus: some View {
        if let message = importViewModel.visibleImportStatusMessage {
            HStack(alignment: .center, spacing: InsightSpacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(InsightTheme.accent)
                Text(message)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if importViewModel.canCancelImport {
                    Button("取消导入") {
                        importViewModel.cancelImport()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("import_cancel_button")
                }
            }
            .padding(InsightSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InsightTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(InsightTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .accessibilityIdentifier("import_processing_status")
        }
    }

    @ViewBuilder
    private var importAnalysisStatus: some View {
        if let message = importViewModel.visibleAnalysisStatusMessage {
            HStack(alignment: .top, spacing: InsightSpacing.sm) {
                Image(systemName: "wand.and.stars.inverse")
                    .foregroundStyle(InsightTheme.warning)
                Text(message)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(InsightSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InsightTheme.warningSurface)
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(InsightTheme.warningBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .accessibilityIdentifier("import_analysis_status")
        }
    }

    private var transcriptList: some View {
        ScrollView {
            if dataSource.transcriptEntries.isEmpty {
                Text(dataSource.phase == .processing ? "转写进行中…" : "未加载到逐字稿，请在记录列表中打开该会议或检查本地记录文件。")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(InsightSpacing.panelPadding)
                    .accessibilityIdentifier(dataSource.phase == .processing ? "import_transcript_processing" : "import_transcript_empty")
            } else {
                LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    ForEach(dataSource.transcriptEntries) { entry in
                        Button {
                            dataSource.onTranscriptEntryTapped(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: InsightSpacing.xs) {
                                HStack(spacing: InsightSpacing.sm) {
                                    Text(formatTimestamp(entry.timestamp))
                                        .font(InsightTypography.caption)
                                        .foregroundStyle(InsightTheme.accent)
                                    if let speaker = entry.speaker, !speaker.isEmpty {
                                        Text(speaker)
                                            .font(InsightTypography.caption)
                                            .foregroundStyle(InsightTheme.textSecondary)
                                    }
                                }
                                Text(entry.text)
                                    .font(InsightTypography.transcript)
                                    .foregroundStyle(InsightTheme.textPrimary)
                                    .lineSpacing(4)
                            }
                            .padding(InsightSpacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(InsightTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.vertical, InsightSpacing.sm)
            }
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
