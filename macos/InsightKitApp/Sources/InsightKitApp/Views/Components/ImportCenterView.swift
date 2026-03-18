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
            FileDropZoneView(
                onFileSelected: { url in
                    onFilePicked?(url)
                }
            )
            .frame(maxWidth: 500, maxHeight: 300)
            Spacer()
        }
        .padding(InsightSpacing.panelPadding)
    }

    // MARK: - Processing Phase

    private var processingView: some View {
        VStack(spacing: InsightSpacing.panelGap) {
            // Media player (can play while processing)
            if let url = dataSource.mediaURL {
                MediaPlayerView(
                    url: url,
                    isPlaying: false,
                    onTimeUpdate: { time in
                        importViewModel.currentPlaybackTime = time
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180, maxHeight: 260)
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.top, InsightSpacing.panelPadding)
            }

            // Progress
            TranscriptionProgressView(
                progress: importViewModel.importProgress,
                elapsedTime: importViewModel.importElapsed,
                totalTime: importViewModel.recordingDuration
            )
            .padding(.horizontal, InsightSpacing.panelPadding)

            // Live transcript entries
            transcriptList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Reviewing Phase

    private var reviewingView: some View {
        VStack(spacing: InsightSpacing.panelGap) {
            // Media player
            if let url = dataSource.mediaURL {
                MediaPlayerView(
                    url: url,
                    isPlaying: true,
                    onSeek: { time in
                        dataSource.onSeek(to: time)
                    },
                    onTimeUpdate: { time in
                        importViewModel.currentPlaybackTime = time
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180, maxHeight: 260)
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

                Button("新建导入") {
                    importViewModel.resetToSelecting()
                }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.accent)
            }
            .padding(.horizontal, InsightSpacing.panelPadding)
            .padding(.vertical, InsightSpacing.md)
            .background(InsightTheme.surface)
        }
    }

    // MARK: - Shared Transcript List

    private var transcriptList: some View {
        ScrollView {
            if dataSource.transcriptEntries.isEmpty {
                Text("转写进行中…")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(InsightSpacing.panelPadding)
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
