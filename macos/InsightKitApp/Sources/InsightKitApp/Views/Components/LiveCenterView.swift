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
        .overlay(alignment: .top) {
            liveProgressBanner
                .padding(.top, InsightSpacing.md)
                .padding(.horizontal, InsightSpacing.panelPadding)
        }
    }

    // MARK: - Preparing Phase

    private var preparingView: some View {
        VStack(spacing: InsightSpacing.xl) {
            Spacer()

            // Video preview area
            Group {
                if let service = dataSource.capturePreview as? VideoCaptureService {
                    capturePreviewFrame(maxHeight: 360) {
                        VideoPreviewView(
                            captureService: service,
                            statusMessage: dataSource.capturePreviewStatusMessage
                        )
                    }
                } else {
                    capturePreviewFrame(maxHeight: 360) {
                        RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                            .fill(InsightTheme.canvas)
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
                    }
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
                capturePreviewFrame(maxHeight: 300) {
                    VideoPreviewView(
                        captureService: service,
                        statusMessage: dataSource.capturePreviewStatusMessage,
                        isRecording: true,
                        recordingDuration: dataSource.recordingDuration
                    )
                }
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
        let plan = LiveReviewPresentationPlan.resolve(
            phase: dataSource.phase,
            smartMinutes: dataSource.smartMinutes,
            canExportDocument: dataSource.canExportDocument
        )

        return Group {
            switch plan.mode {
            case .summaryFirst:
                if let minutes = dataSource.smartMinutes {
                    summaryFirstReviewingView(minutes: minutes, plan: plan)
                } else {
                    transcriptFirstReviewingView
                }
            case .transcriptFirst:
                transcriptFirstReviewingView
            }
        }
    }

    private func summaryFirstReviewingView(minutes: SmartMinutes, plan: LiveReviewPresentationPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InsightSpacing.md) {
                summaryReadyHeader(exportActions: plan.exportActions)

                summaryTextSection(
                    title: "总结",
                    text: minutes.structuredSummary,
                    fallback: "当前记录尚未生成结构化总结。",
                    accessibilityID: "live_summary_review_overview"
                )

                summaryListSection(
                    title: "会议金句",
                    items: minutes.highlights,
                    fallback: "当前纪要未包含会议金句。",
                    accessibilityID: "live_summary_review_highlights"
                )

                summarySpeakerSection(minutes.speakerSummaries)

                summaryListSection(
                    title: "关键决策",
                    items: minutes.keyDecisions,
                    fallback: "当前纪要未包含明确关键决策。",
                    accessibilityID: "live_summary_review_decisions"
                )

                summaryListSection(
                    title: "待办事项",
                    items: minutes.actionItems,
                    fallback: "当前纪要未包含待办事项。",
                    accessibilityID: "live_summary_review_actions"
                )

                summaryChapterSection(minutes.chapters)

                reviewSourceSection
            }
            .padding(InsightSpacing.panelPadding)
        }
        .accessibilityIdentifier("live_summary_review")
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

    private var transcriptFirstReviewingView: some View {
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

    private func summaryReadyHeader(exportActions: [LiveReviewExportAction]) -> some View {
        VStack(alignment: .leading, spacing: InsightSpacing.sm) {
            HStack(spacing: InsightSpacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(InsightTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("智能纪要")
                        .font(InsightTypography.heading)
                        .foregroundStyle(InsightTheme.textPrimary)
                    Text("已生成")
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            if !exportActions.isEmpty {
                HStack(spacing: InsightSpacing.sm) {
                    ForEach(exportActions) { action in
                        Button {
                            dataSource.onExportDocument(format: action.format)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(action.accessibilityIdentifier)
                    }
                }
            }

            if let exportFileName {
                Text("已导出 \(exportFileName)")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textSecondary)
                    .accessibilityIdentifier("live_summary_export_status")
            }
        }
        .padding(InsightSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InsightTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
        .accessibilityIdentifier("live_summary_review_header")
    }

    private var exportFileName: String? {
        let path = dataSource.lastExportPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func summaryTextSection(
        title: String,
        text: String,
        fallback: String,
        accessibilityID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: InsightSpacing.xs) {
            sectionTitle(title)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text)
                .font(InsightTypography.body)
                .foregroundStyle(InsightTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .summarySectionStyle(accessibilityID: accessibilityID)
    }

    private func summaryListSection(
        title: String,
        items: [String],
        fallback: String,
        accessibilityID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: InsightSpacing.xs) {
            sectionTitle(title)
            if items.isEmpty {
                Text(fallback)
                    .font(InsightTypography.body)
                    .foregroundStyle(InsightTheme.textSecondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: InsightSpacing.sm) {
                        Circle()
                            .fill(InsightTheme.accent.opacity(0.65))
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(item)
                            .font(InsightTypography.body)
                            .foregroundStyle(InsightTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .summarySectionStyle(accessibilityID: accessibilityID)
    }

    private func summarySpeakerSection(_ speakers: [SpeakerMinutesSummary]) -> some View {
        VStack(alignment: .leading, spacing: InsightSpacing.xs) {
            sectionTitle("发言人总结")
            if speakers.isEmpty {
                Text("当前纪要未包含独立发言人总结。")
                    .font(InsightTypography.body)
                    .foregroundStyle(InsightTheme.textSecondary)
            } else {
                ForEach(speakers) { speaker in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.speakerName)
                            .font(InsightTypography.caption)
                            .foregroundStyle(InsightTheme.accent)
                        Text(speaker.summary)
                            .font(InsightTypography.body)
                            .foregroundStyle(InsightTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .summarySectionStyle(accessibilityID: "live_summary_review_speakers")
    }

    private func summaryChapterSection(_ chapters: [ChapterSummary]) -> some View {
        VStack(alignment: .leading, spacing: InsightSpacing.xs) {
            sectionTitle("智能章节")
            if chapters.isEmpty {
                Text("当前纪要未包含智能章节。")
                    .font(InsightTypography.body)
                    .foregroundStyle(InsightTheme.textSecondary)
            } else {
                ForEach(chapters) { chapter in
                    Button {
                        dataSource.onSeek(to: chapter.timestamp)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(formatTimestamp(chapter.timestamp))  \(chapter.title)")
                                .font(InsightTypography.caption)
                                .foregroundStyle(InsightTheme.accent)
                            Text(chapter.summary)
                                .font(InsightTypography.body)
                                .foregroundStyle(InsightTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .summarySectionStyle(accessibilityID: "live_summary_review_chapters")
    }

    private var reviewSourceSection: some View {
        let presentation = LiveReviewSourcePresentation.make(
            mediaURL: dataSource.mediaURL,
            reviewSourceMediaURL: dataSource.reviewSourceMediaURL,
            statusMessage: dataSource.reviewSourceStatusMessage
        )

        return VStack(alignment: .leading, spacing: InsightSpacing.sm) {
            sectionTitle("回看资料")

            if presentation.showsPrimaryMedia {
                MediaPlayerView(
                    url: presentation.primaryMediaURL,
                    isPlaying: false,
                    seekRequest: dataSource.mediaSeekRequest,
                    onSeek: { time in
                        dataSource.onSeek(to: time)
                    },
                    onTimeUpdate: { _ in }
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 160, maxHeight: 220)
            }

            if presentation.showsSupplementalAudio {
                VStack(alignment: .leading, spacing: InsightSpacing.xs) {
                    Text("原始声音")
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textSecondary)
                    MediaPlayerView(
                        url: presentation.supplementalAudioURL,
                        isPlaying: false,
                        seekRequest: dataSource.mediaSeekRequest,
                        onSeek: { time in
                            dataSource.onSeek(to: time)
                        },
                        onTimeUpdate: { _ in }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36, maxHeight: 44)
                }
                .accessibilityIdentifier("live_summary_review_source_audio")
            }

            if let message = presentation.statusMessage {
                HStack(alignment: .top, spacing: InsightSpacing.sm) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(InsightTheme.accent)
                    Text(message)
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(InsightSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(InsightTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                .accessibilityIdentifier("live_summary_review_source_status")
            }

            if dataSource.transcriptEntries.isEmpty {
                Text("等待转写输入…")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("live_summary_review_transcript_empty")
            } else {
                VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                    ForEach(Array(dataSource.transcriptEntries.enumerated()), id: \.element.id) { index, entry in
                        transcriptEntryRow(entry, index: index)
                    }
                }
                .accessibilityIdentifier("live_summary_review_transcript")
            }
        }
        .summarySectionStyle(accessibilityID: "live_summary_review_sources")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(InsightTypography.bodyMedium)
            .foregroundStyle(InsightTheme.textPrimary)
    }

    // MARK: - Shared Transcript List

    private func capturePreviewFrame<Content: View>(
        maxHeight: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            let size = LiveVisualPreviewLayout.previewSize(
                availableWidth: proxy.size.width,
                maxHeight: maxHeight
            )

            content()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: maxHeight)
        .padding(.horizontal, InsightSpacing.panelPadding)
    }

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

    @ViewBuilder
    private var liveProgressBanner: some View {
        if let progress = dataSource.liveProgressPresentation {
            HStack(alignment: .center, spacing: InsightSpacing.sm) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.title)
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textPrimary)
                        .accessibilityIdentifier("live_progress_title")
                    Text(progress.message)
                        .font(.caption2)
                        .foregroundStyle(InsightTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("live_progress_message")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, InsightSpacing.md)
            .padding(.vertical, InsightSpacing.sm)
            .background(InsightTheme.elevated)
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(InsightTheme.border.opacity(0.7), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .shadow(color: Color.black.opacity(0.06), radius: 10, y: 3)
            .accessibilityIdentifier("live_progress_status")
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

private extension View {
    func summarySectionStyle(accessibilityID: String) -> some View {
        self
            .padding(InsightSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InsightTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .accessibilityIdentifier(accessibilityID)
    }
}
