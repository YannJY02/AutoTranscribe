import SwiftUI

// MARK: - Color hex initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Design System (Notion-style)

enum InsightTheme {
    // Background layers
    static let canvas     = Color(hex: "#F0F0EF")
    static let surface    = Color(hex: "#FFFFFF")
    static let surfaceAlt = Color(hex: "#F7F6F3")
    static let elevated   = Color(hex: "#FFFFFF")

    // Text
    static let textPrimary   = Color(hex: "#37352F")
    static let textSecondary = Color(hex: "#787774")
    static let textTertiary  = Color(hex: "#B4B4B0")

    // Accent
    static let accent      = Color(hex: "#2F80ED")
    static let accentHover = Color(hex: "#2B6CC4")
    static let accentLight = Color(hex: "#E8F0FE")
    static let accentMuted = Color(hex: "#F0F5FF")

    // Borders
    static let border      = Color(hex: "#E8E8E8")
    static let borderLight = Color(hex: "#F0F0EF")
    static let borderFocus = Color(hex: "#2F80ED")

    // Status
    static let success   = Color(hex: "#0F7B6C")
    static let warning   = Color(hex: "#CB912F")
    static let error     = Color(hex: "#E03E3E")
    static let recording = Color(hex: "#E03E3E")

    // Banner surfaces (backward compat)
    static let warningSurface = Color(hex: "#FDF5E6")
    static let warningBorder  = Color(hex: "#E2C28F").opacity(0.7)
    static let errorSurface   = Color(hex: "#FDEEEC")
    static let errorBorder    = Color(hex: "#DA9490").opacity(0.78)

    // Layout
    static let cornerRadius: CGFloat = 8
    static let cardPadding: CGFloat = 16
    static let panelGap: CGFloat = 1

    // Deprecated aliases — remove after full migration
    @available(*, deprecated, renamed: "canvas")
    static let background = canvas
    @available(*, deprecated, renamed: "surface")
    static let panel = surface
    @available(*, deprecated, renamed: "elevated")
    static let panelElevated = elevated
    @available(*, deprecated, renamed: "InsightShadow.card")
    static let cardShadowColor = Color.black.opacity(0.04)
    @available(*, deprecated, renamed: "InsightShadow.card")
    static let cardShadowRadius: CGFloat = 2
    @available(*, deprecated, renamed: "InsightShadow.card")
    static let cardShadowYOffset: CGFloat = 1
}

// MARK: - Typography

enum InsightTypography {
    static let title         = Font.system(size: 20, weight: .semibold)
    static let heading       = Font.system(size: 16, weight: .semibold)
    static let body          = Font.system(size: 14, weight: .regular)
    static let bodyMedium    = Font.system(size: 14, weight: .medium)
    static let caption       = Font.system(size: 12, weight: .regular)
    static let small         = Font.system(size: 11, weight: .regular)
    static let transcript    = Font.system(size: 14, weight: .regular)
    static let noteBody      = Font.system(size: 14, weight: .regular)
    static let noteTimestamp  = Font.system(size: 11, weight: .medium)
}

// MARK: - Spacing

enum InsightSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let panelPadding: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let panelGap: CGFloat = 1
}

// MARK: - Shadows

enum InsightShadow {
    static let card = (color: Color.black.opacity(0.04), radius: CGFloat(2), y: CGFloat(1))
    static let cardHover = (color: Color.black.opacity(0.08), radius: CGFloat(8), y: CGFloat(2))
    static let elevated = (color: Color.black.opacity(0.12), radius: CGFloat(16), y: CGFloat(4))
}

// MARK: - Animations

enum InsightAnimation {
    static let phaseTransition = Animation.easeInOut(duration: 0.25)
    static let listAppear = Animation.easeOut(duration: 0.15)
    static let hover = Animation.easeInOut(duration: 0.12)
    static let sheetPresent = Animation.spring(response: 0.3, dampingFraction: 0.85)
    static let chapterAppend = Animation.easeOut(duration: 0.2)
    static let noteHighlight = Animation.easeInOut(duration: 0.3)
    static let recordingPulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
}

// MARK: - Card Modifier

struct QuietCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(InsightTheme.cardPadding)
            .background(InsightTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: InsightTheme.cornerRadius)
                    .stroke(InsightTheme.border.opacity(0.55), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
            .shadow(
                color: InsightShadow.card.color,
                radius: InsightShadow.card.radius,
                y: InsightShadow.card.y
            )
    }
}

extension View {
    func quietCard() -> some View {
        modifier(QuietCardModifier())
    }
}
