import SwiftUI

enum InsightTheme {
    // Quiet Premium palette: warm neutral base + one low-saturation blue accent.
    static let background = Color(red: 0.952, green: 0.946, blue: 0.936)
    static let panel = Color(red: 0.984, green: 0.979, blue: 0.972)
    static let panelElevated = Color(red: 0.991, green: 0.988, blue: 0.982)
    static let border = Color(red: 0.836, green: 0.828, blue: 0.812)
    static let textPrimary = Color(red: 0.14, green: 0.16, blue: 0.19)
    static let textSecondary = Color(red: 0.42, green: 0.43, blue: 0.46)
    static let accent = Color(red: 0.35, green: 0.50, blue: 0.66)

    static let warningSurface = Color(red: 0.988, green: 0.960, blue: 0.908)
    static let warningBorder = Color(red: 0.884, green: 0.762, blue: 0.560).opacity(0.7)
    static let errorSurface = Color(red: 0.992, green: 0.933, blue: 0.925)
    static let errorBorder = Color(red: 0.856, green: 0.582, blue: 0.560).opacity(0.78)

    static let cornerRadius: CGFloat = 14
    static let cardShadowColor = Color.black.opacity(0.028)
    static let cardShadowRadius: CGFloat = 10
    static let cardShadowYOffset: CGFloat = 2
}

struct QuietCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(InsightTheme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(InsightTheme.border.opacity(0.55), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .shadow(
                color: InsightTheme.cardShadowColor,
                radius: InsightTheme.cardShadowRadius,
                y: InsightTheme.cardShadowYOffset
            )
    }
}

extension View {
    func quietCard() -> some View {
        modifier(QuietCardModifier())
    }
}
