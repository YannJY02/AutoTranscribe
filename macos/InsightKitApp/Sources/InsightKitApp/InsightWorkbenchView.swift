import SwiftUI

struct InsightWorkbenchView: View {
    @Binding var selectedTab: InsightTab
    let state: InsightWorkbenchState
    let focusMode: Bool
    let onEvidenceSelected: (EvidenceRange?) -> Void

    private var currentItems: [WorkbenchItem] {
        switch selectedTab {
        case .sessionOverview:
            return [WorkbenchItem(title: "会话总览", body: state.sessionOverview, meta: "", evidence: nil)]
        case .highlightInsights:
            return state.highlightInsights
        case .speakerMap:
            return state.speakerPerspectives
        case .decisionLedger:
            return state.decisionLedger
        case .actionTracks:
            return state.actionTracks
        case .timelineBeats:
            return state.timelineBeats
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("洞察工作台")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(InsightTheme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(InsightTab.allCases) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(selectedTab == tab ? Color.white : InsightTheme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selectedTab == tab ? InsightTheme.accent : InsightTheme.panel)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(InsightTheme.border.opacity(selectedTab == tab ? 0 : 0.6), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if selectedTab == .decisionLedger {
                EvidenceRail(items: currentItems, onEvidenceSelected: onEvidenceSelected)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: focusMode ? 12 : 10) {
                        ForEach(currentItems) { item in
                            WorkbenchItemCard(item: item, onEvidenceSelected: onEvidenceSelected)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
    }
}

private struct WorkbenchItemCard: View {
    let item: WorkbenchItem
    let onEvidenceSelected: (EvidenceRange?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(InsightTheme.textPrimary)
            Text(item.body)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(InsightTheme.textPrimary)

            if !item.meta.isEmpty {
                Text(item.meta)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InsightTheme.textSecondary)
            }

            if let evidence = item.evidence {
                Button("定位证据 \(evidence.label)") {
                    onEvidenceSelected(evidence)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InsightTheme.accent)
            }
        }
        .quietCard()
    }
}

private struct EvidenceRail: View {
    let items: [WorkbenchItem]
    let onEvidenceSelected: (EvidenceRange?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(InsightTheme.accent)
                                .frame(width: 9, height: 9)
                            Rectangle()
                                .fill(InsightTheme.border)
                                .frame(width: 1)
                        }
                        .frame(width: 16)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("决策节点 \(idx + 1)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(InsightTheme.textSecondary)

                            Text(item.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(InsightTheme.textPrimary)
                            Text(item.body)
                                .font(.system(size: 15))
                                .lineSpacing(6)
                                .foregroundStyle(InsightTheme.textPrimary)

                            if !item.meta.isEmpty {
                                Text(item.meta)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(InsightTheme.textSecondary)
                            }

                            if let evidence = item.evidence {
                                Button("查看证据 \(evidence.label)") {
                                    onEvidenceSelected(evidence)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(InsightTheme.accent)
                            }
                        }
                        .quietCard()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
