import SwiftUI

struct BottomStatusBarView: View {
    @Binding var mode: BottomPanelMode
    let payload: BottomStatusPayload

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(InsightTheme.border.opacity(0.6))
                .frame(height: 1)

            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        tag(payload.routeTitle, emphasized: true)
                        if !payload.phaseLabel.isEmpty {
                            tag(payload.phaseLabel)
                        }
                        tag(payload.stateLabel)
                        if let last = payload.lastRefreshAt {
                            tag("最近刷新 \(last.formatted(date: .omitted, time: .shortened))")
                        }
                        if !payload.meetingID.isEmpty {
                            tag("会话 \(payload.meetingID)")
                        }

                        if mode == .expandedDebug {
                            tag(payload.developer.sidecarLabel)
                            tag(payload.developer.ready ? "侧车就绪" : "侧车未就绪")
                            tag("Chunk \(payload.developer.chunkIndex)")
                            tag("片段 \(payload.developer.segmentsIngested)")
                            tag("延迟 \(payload.developer.latencyMs)ms")
                            if !payload.developer.provider.isEmpty {
                                tag("Provider \(payload.developer.provider)")
                            }
                            if !payload.developer.analysisState.isEmpty {
                                tag(payload.developer.analysisState)
                            }
                            if payload.developer.needsReviewCount > 0 {
                                tag("需复核 \(payload.developer.needsReviewCount)")
                            }
                            if let lastChunkAt = payload.developer.lastChunkAt {
                                tag("最近Chunk \(lastChunkAt.formatted(date: .omitted, time: .standard))")
                            }
                            if let lastTranscriptAt = payload.developer.lastTranscriptAt {
                                tag("最近文本 \(lastTranscriptAt.formatted(date: .omitted, time: .standard))")
                            }
                            tag(String(format: "麦克风 %.2f", payload.developer.inputLevelMic))
                            tag(String(format: "系统音频 %.2f", payload.developer.inputLevelSystem))
                        }
                    }
                }

                Spacer(minLength: 8)

                Button(mode == .collapsed ? "开发者模式" : "收起开发者模式") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        mode = mode == .collapsed ? .expandedDebug : .collapsed
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InsightTheme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 46)
            .background(InsightTheme.panel)
        }
    }

    private func tag(_ value: String, emphasized: Bool = false) -> some View {
        Text(value)
            .font(.system(size: 12, weight: emphasized ? .semibold : .medium))
            .foregroundStyle(emphasized ? InsightTheme.textPrimary : InsightTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(InsightTheme.background.opacity(emphasized ? 0.85 : 0.6))
            )
            .overlay(
                Capsule()
                    .stroke(InsightTheme.border.opacity(0.65), lineWidth: 1)
            )
    }
}
