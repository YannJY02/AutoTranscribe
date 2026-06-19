import SwiftUI

struct RecordSearchBar: View {
    @Binding var query: String
    var onSubmit: (() -> Void)?

    var body: some View {
        HStack(spacing: InsightSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(InsightTheme.textTertiary)
                .font(.system(size: 14))
            TextField("搜索记录...", text: $query)
                .textFieldStyle(.plain)
                .font(InsightTypography.body)
                .onSubmit { onSubmit?() }
                .accessibilityIdentifier("records_search_field")
        }
        .padding(.horizontal, InsightSpacing.md)
        .padding(.vertical, InsightSpacing.sm)
        .background(InsightTheme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(InsightTheme.border, lineWidth: 1)
        )
    }
}
