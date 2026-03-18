import SwiftUI

/// Center panel for the live transcription workspace.
/// Switches content based on session phase: preparing → running → postSession → reviewing.
struct LiveCenterView<DataSource: CenterStageDataSource>: View {
    @ObservedObject var dataSource: DataSource
    @Binding var sources: [SourceToggleItem]
    var onDeviceSelect: ((String) -> Void)?
    @State private var showMinutesSheet = false

    var body: some View {
        VStack(spacing: 0) {
            switch dataSource.phase {
            case .preparing:
                preparingView
            case .running:
                runningView
            case .postSession:
                postSessionView
            case .reviewing:
                reviewingView
            case .selecting, .processing:
                // Import-specific phases — not used in live
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InsightTheme.surfaceAlt)
    }

    // MARK: - Preparing Phase

    private var preparingView: some View {
        VStack(spacing: InsightSpacing.xl) {
            Spacer()

            // Video preview area
            if let service = dataSource.capturePreview as? VideoCaptureService {
                VideoPreviewView(captureService: service)
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                    .padding(.horizontal, InsightSpacing.panelPadding)
            } else {
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .fill(InsightTheme.canvas)
                    .frame(height: 360)
                    .overlay(
                        VStack(spacing: InsightSpacing.md) {
                            Image(systemName: "video.slash")
                                .font(.system(size: 40))
                                .foregroundStyle(InsightTheme.textTertiary)
                            Text("开启摄像头或屏幕捕获以预览")
                                .font(InsightTypography.caption)
                                .foregroundStyle(InsightTheme.textTertiary)
                        }
                    )
                    .padding(.horizontal, InsightSpacing.panelPadding)
            }

            // Source toggle bar
            SourceToggleBar(sources: $sources, onDeviceSelect: onDeviceSelect)
                .padding(.horizontal, InsightSpacing.panelPadding)

            // Start button
            Button("开始录制") {
                dataSource.onStartRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(InsightTheme.accent)
            .controlSize(.large)

            Spacer()
        }
    }

    // MARK: - Running Phase

    private var runningView: some View {
        VStack(spacing: InsightSpacing.panelGap) {
            // Video preview with REC indicator
            if let service = dataSource.capturePreview as? VideoCaptureService {
                VideoPreviewView(
                    captureService: service,
                    isRecording: true,
                    recordingDuration: dataSource.recordingDuration
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 200, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.top, InsightSpacing.panelPadding)
            }

            // Live transcript stream
            transcriptList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Controls bar
            HStack(spacing: InsightSpacing.lg) {
                Text(formatDuration(dataSource.recordingDuration))
                    .font(InsightTypography.bodyMedium)
                    .foregroundStyle(InsightTheme.recording)
                    .monospacedDigit()

                Spacer()

                Button("暂停") {
                    dataSource.onPauseRecording()
                }
                .buttonStyle(.bordered)

                Button("停止录制") {
                    dataSource.onStopRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.recording)
            }
            .padding(.horizontal, InsightSpacing.panelPadding)
            .padding(.vertical, InsightSpacing.md)
            .background(InsightTheme.surface)
        }
    }

    // MARK: - Post Session Phase

    private var postSessionView: some View {
        VStack {
            Spacer()
            SmartMinutesSheet(
                duration: dataSource.recordingDuration,
                onGenerate: {
                    showMinutesSheet = false
                },
                onSkip: {
                    showMinutesSheet = false
                }
            )
            Spacer()
        }
    }

    // MARK: - Reviewing Phase

    private var reviewingView: some View {
        VStack(spacing: InsightSpacing.panelGap) {
            // Media player
            MediaPlayerView(
                url: dataSource.mediaURL,
                isPlaying: true,
                onSeek: { time in
                    dataSource.onSeek(to: time)
                },
                onTimeUpdate: { _ in }
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 200, maxHeight: 300)
            .padding(.horizontal, InsightSpacing.panelPadding)
            .padding(.top, InsightSpacing.panelPadding)

            // Full transcript (scrollable, clickable)
            transcriptList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Shared Transcript List

    private var transcriptList: some View {
        ScrollView {
            if dataSource.transcriptEntries.isEmpty {
                Text("等待转写输入…")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(InsightSpacing.panelPadding)
            } else {
                LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    ForEach(dataSource.transcriptEntries) { entry in
                        transcriptEntryRow(entry)
                    }
                }
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.vertical, InsightSpacing.sm)
            }
        }
    }

    private func transcriptEntryRow(_ entry: TranscriptEntry) -> some View {
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

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
