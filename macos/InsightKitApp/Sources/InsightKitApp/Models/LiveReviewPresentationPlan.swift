import Foundation

enum LiveReviewPresentationMode: Equatable {
    case transcriptFirst
    case summaryFirst
}

struct LiveReviewExportAction: Equatable, Identifiable {
    let format: String
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String

    var id: String { format }
}

struct LiveReviewPresentationPlan: Equatable {
    let mode: LiveReviewPresentationMode
    let exportActions: [LiveReviewExportAction]

    static func resolve(
        phase: SessionPhase,
        smartMinutes: SmartMinutes?,
        canExportDocument: Bool = false
    ) -> LiveReviewPresentationPlan {
        guard phase == .reviewing else {
            return LiveReviewPresentationPlan(mode: .transcriptFirst, exportActions: [])
        }
        if smartMinutes != nil {
            return LiveReviewPresentationPlan(
                mode: .summaryFirst,
                exportActions: canExportDocument ? exportActions : []
            )
        }
        return LiveReviewPresentationPlan(mode: .transcriptFirst, exportActions: [])
    }

    private static let exportActions = [
        LiveReviewExportAction(
            format: "markdown",
            title: "导出 Markdown",
            systemImage: "doc.text",
            accessibilityIdentifier: "live_summary_export_markdown_button"
        ),
        LiveReviewExportAction(
            format: "pdf",
            title: "导出 PDF",
            systemImage: "doc.richtext",
            accessibilityIdentifier: "live_summary_export_pdf_button"
        )
    ]
}
