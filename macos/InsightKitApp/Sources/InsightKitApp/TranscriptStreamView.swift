import SwiftUI

struct TranscriptStreamView: View {
    @Binding var searchText: String
    @Binding var selectedEvidence: EvidenceRange?
    let segments: [TranscriptSegment]

    var filtered: [TranscriptSegment] {
        guard !searchText.isEmpty else { return segments }
        return segments.filter {
            $0.text.localizedCaseInsensitiveContains(searchText) ||
            $0.speaker.localizedCaseInsensitiveContains(searchText) ||
            $0.source.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("逐字稿流")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(InsightTheme.textPrimary)
                Spacer()
                if let selectedEvidence {
                    Button("清除定位 \(selectedEvidence.label)") {
                        self.selectedEvidence = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InsightTheme.accent)
                }
            }

            TextField("搜索发言人或内容", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                if filtered.isEmpty {
                    Text("等待实时转写输入…")
                        .foregroundStyle(InsightTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filtered) { seg in
                            let highlighted = seg.overlaps(selectedEvidence)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(seg.timeLabel)
                                        .font(.caption)
                                        .foregroundStyle(InsightTheme.textSecondary)
                                    Text(seg.speaker)
                                        .font(.caption)
                                        .foregroundStyle(InsightTheme.accent)
                                    sourceBadge(seg.source)
                                }
                                Text(seg.text)
                                    .font(.system(size: 15))
                                    .lineSpacing(4)
                                    .foregroundStyle(InsightTheme.textPrimary)
                            }
                            .quietCard()
                            .overlay(
                                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                                    .stroke(highlighted ? InsightTheme.accent.opacity(0.8) : Color.clear, lineWidth: 1.5)
                            )
                            .onTapGesture {
                                selectedEvidence = EvidenceRange(startMs: seg.startMs, endMs: seg.endMs)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private func sourceBadge(_ source: String) -> some View {
        let label = sourceLabel(source)
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(sourceColor(source).opacity(0.18))
            )
            .foregroundStyle(sourceColor(source))
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "mic":
            return "麦克风"
        case "system":
            return "系统音频"
        case "mixed":
            return "混音"
        default:
            return "未知来源"
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "mic":
            return Color(red: 0.28, green: 0.5, blue: 0.34)
        case "system":
            return Color(red: 0.34, green: 0.46, blue: 0.68)
        case "mixed":
            return Color(red: 0.48, green: 0.42, blue: 0.62)
        default:
            return InsightTheme.textSecondary
        }
    }
}
