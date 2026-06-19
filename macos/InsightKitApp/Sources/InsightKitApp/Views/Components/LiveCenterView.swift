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
            Group {
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
            }
            .accessibilityIdentifier("live_preparing_preview")

            // Source toggle bar
            SourceToggleBar(sources: $sources, onDeviceSelect: onDeviceSelect)
                .padding(.horizontal, InsightSpacing.panelPadding)

            // Start button
            Button {
                dataSource.onStartRecording()
            } label: {
                Text("开始录制")
            }
            .buttonStyle(.borderedProminent)
            .tint(InsightTheme.accent)
            .controlSize(.large)
            .accessibilityIdentifier("live_start_recording_button")

            Spacer()
        }
        .overlay(alignment: .topLeading) {
            phaseMarker("准备态", identifier: "live_phase_preparing")
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

                Button {
                    dataSource.onPauseRecording()
                } label: {
                    Text("暂停")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("live_pause_recording_button")

                Button {
                    dataSource.onStopRecording()
                } label: {
                    Text("停止录制")
                }
                .buttonStyle(.borderedProminent)
                .tint(InsightTheme.recording)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: [.command])
                .accessibilityIdentifier("live_stop_recording_button")
            }
            .padding(.horizontal, InsightSpacing.panelPadding)
            .padding(.vertical, InsightSpacing.md)
            .background(InsightTheme.surface)
        }
        .overlay(alignment: .topLeading) {
            phaseMarker("录制中", identifier: "live_phase_running")
        }
    }

    // MARK: - Post Session Phase

    private var postSessionView: some View {
        VStack {
            Spacer()
            recordingStatusBanner
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.bottom, InsightSpacing.md)
            SmartMinutesSheet(
                duration: dataSource.recordingDuration,
                onGenerate: {
                    dataSource.onGenerateMinutes()
                },
                onSkip: {
                    dataSource.onSkipMinutes()
                }
            )
            Spacer()
        }
        .overlay(alignment: .topLeading) {
            phaseMarker("会后选择", identifier: "live_phase_post_session")
        }
    }

    // MARK: - Reviewing Phase

    private var reviewingView: some View {
        VStack(spacing: InsightSpacing.panelGap) {
            // Media player
            MediaPlayerView(
                url: dataSource.mediaURL,
                isPlaying: true,
                seekRequest: dataSource.mediaSeekRequest,
                onSeek: { time in
                    dataSource.onSeek(to: time)
                },
                onTimeUpdate: { _ in }
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 200, maxHeight: 300)
            .padding(.horizontal, InsightSpacing.panelPadding)
            .padding(.top, InsightSpacing.panelPadding)

            recordingStatusBanner
                .padding(.horizontal, InsightSpacing.panelPadding)

            // Full transcript (scrollable, clickable)
            transcriptList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                phaseMarker("回看态", identifier: "live_phase_reviewing")
                Text(formatTimestamp(dataSource.currentPlaybackTime ?? 0))
                    .font(.caption2)
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier("live_current_playback_label")
            }
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
                    .accessibilityIdentifier("live_transcript_empty_state")
            } else {
                LazyVStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    ForEach(Array(dataSource.transcriptEntries.enumerated()), id: \.element.id) { index, entry in
                        transcriptEntryRow(entry, index: index)
                    }
                }
                .padding(.horizontal, InsightSpacing.panelPadding)
                .padding(.vertical, InsightSpacing.sm)
            }
        }
    }

    private func transcriptEntryRow(_ entry: TranscriptEntry, index: Int) -> some View {
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
        .accessibilityIdentifier("live_transcript_entry_\(index)")
        .accessibilityLabel(entry.text)
        .accessibilityValue(formatTimestamp(entry.timestamp))
    }

    @ViewBuilder
    private var recordingStatusBanner: some View {
        if let raw = dataSource.recordingStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            HStack(spacing: InsightSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(InsightTheme.warning)
                Text(raw)
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, InsightSpacing.md)
            .padding(.vertical, InsightSpacing.sm)
            .background(InsightTheme.warningSurface)
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(InsightTheme.warningBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .accessibilityIdentifier("live_recording_status")
        }
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

    @ViewBuilder
    private func phaseMarker(_ label: String, identifier: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.clear)
            .accessibilityIdentifier(identifier)
    }
}
