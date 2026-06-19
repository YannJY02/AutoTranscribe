import SwiftUI

struct RecordsSidebarView: View {
    @Binding var searchQuery: String
    @Binding var selectedTags: Set<String>
    @Binding var selectedType: MediaType?
    @Binding var selectedTimeFilter: RecordTimeFilter?
    let allTags: [String]
    let recordCount: Int
    var onAddTag: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: InsightSpacing.md) {
            // Search
            RecordSearchBar(query: $searchQuery)
                .padding(.horizontal, InsightSpacing.lg)
                .padding(.top, InsightSpacing.lg)

            // Record count
            Text("全部记录 (\(recordCount))")
                .font(InsightTypography.heading)
                .foregroundStyle(InsightTheme.textPrimary)
                .padding(.horizontal, InsightSpacing.lg)

            Divider().padding(.horizontal, InsightSpacing.lg)

            // Type filter
            VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                Text("类型")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                    .padding(.horizontal, InsightSpacing.lg)

                HStack(spacing: InsightSpacing.sm) {
                    typeFilterButton("全部", type: nil, identifier: "records_type_filter_all")
                    typeFilterButton("音频", type: .audio, identifier: "records_type_filter_audio")
                    typeFilterButton("视频", type: .video, identifier: "records_type_filter_video")
                }
                .padding(.horizontal, InsightSpacing.lg)
            }

            Divider().padding(.horizontal, InsightSpacing.lg)

            // Tags
            VStack(alignment: .leading, spacing: InsightSpacing.sm) {
                HStack {
                    Text("标签")
                        .font(InsightTypography.caption)
                        .foregroundStyle(InsightTheme.textTertiary)
                    Spacer()
                    if let onAddTag {
                        Button(action: onAddTag) {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(InsightTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, InsightSpacing.lg)

                ScrollView {
                    FlowLayout(spacing: InsightSpacing.xs) {
                        ForEach(allTags, id: \.self) { tag in
                            tagPill(tag)
                        }
                    }
                    .padding(.horizontal, InsightSpacing.lg)
                }
            }

            Spacer()

            // Time filters
            VStack(alignment: .leading, spacing: InsightSpacing.xs) {
                Text("时间")
                    .font(InsightTypography.caption)
                    .foregroundStyle(InsightTheme.textTertiary)
                .padding(.horizontal, InsightSpacing.lg)
                ForEach(RecordTimeFilter.allCases) { filter in
                    timeFilterButton(filter)
                }
            }
            .padding(.bottom, InsightSpacing.lg)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func typeFilterButton(_ label: String, type: MediaType?, identifier: String) -> some View {
        Button(label) {
            selectedType = type
        }
        .buttonStyle(.plain)
        .font(InsightTypography.caption)
        .padding(.horizontal, InsightSpacing.sm)
        .padding(.vertical, InsightSpacing.xs)
        .background(selectedType == type ? InsightTheme.accentLight : InsightTheme.surfaceAlt)
        .foregroundStyle(selectedType == type ? InsightTheme.accent : InsightTheme.textSecondary)
        .clipShape(Capsule())
        .accessibilityIdentifier(identifier)
    }

    private func tagPill(_ tag: String) -> some View {
        let isSelected = selectedTags.contains(tag)
        return Button {
            if isSelected {
                selectedTags.remove(tag)
            } else {
                selectedTags.insert(tag)
            }
        } label: {
            Text(tag)
                .font(InsightTypography.small)
                .padding(.horizontal, InsightSpacing.sm)
                .padding(.vertical, InsightSpacing.xs)
                .background(isSelected ? InsightTheme.accentLight : InsightTheme.surfaceAlt)
                .foregroundStyle(isSelected ? InsightTheme.accent : InsightTheme.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("records_tag_filter_\(tag)")
    }

    private func timeFilterButton(_ filter: RecordTimeFilter) -> some View {
        let isSelected = selectedTimeFilter == filter
        return Button(filter.label) {
            selectedTimeFilter = isSelected ? nil : filter
        }
        .buttonStyle(.plain)
        .font(InsightTypography.body)
        .padding(.horizontal, InsightSpacing.lg)
        .padding(.vertical, InsightSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? InsightTheme.accentLight : Color.clear)
        .foregroundStyle(isSelected ? InsightTheme.accent : InsightTheme.textSecondary)
        .accessibilityIdentifier(filter.accessibilityIdentifier)
    }
}

/// Simple flow layout for tag pills
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
