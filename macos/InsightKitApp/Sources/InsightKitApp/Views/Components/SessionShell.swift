import SwiftUI

struct SessionShell<Left: View, Center: View, Right: View>: View {
    let left: Left
    let center: Center
    let right: Right

    var body: some View {
        HSplitView {
            left
                .frame(minWidth: 260, maxWidth: 360)
                .background(InsightTheme.surface)
            center
                .frame(minWidth: 480)
                .layoutPriority(1)
                .background(InsightTheme.surfaceAlt)
            right
                .frame(minWidth: 280, maxWidth: 380)
                .background(InsightTheme.surface)
        }
        .background(InsightTheme.canvas)
    }
}

/// Fixed-proportion variant for nested scenarios (e.g. RecordsView preview).
/// Uses HStack instead of HSplitView to avoid nested split view issues.
struct SessionShellFixed<Left: View, Center: View, Right: View>: View {
    let left: Left
    let center: Center
    let right: Right

    var body: some View {
        HStack(spacing: InsightSpacing.panelGap) {
            left
                .frame(minWidth: 240)
                .frame(maxWidth: .infinity)
                .background(InsightTheme.surface)
            center
                .frame(minWidth: 400)
                .frame(maxWidth: .infinity)
                .layoutPriority(2)
                .background(InsightTheme.surfaceAlt)
            right
                .frame(minWidth: 240)
                .frame(maxWidth: .infinity)
                .background(InsightTheme.surface)
        }
        .background(InsightTheme.canvas)
    }
}
