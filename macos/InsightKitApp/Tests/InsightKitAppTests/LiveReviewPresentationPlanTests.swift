import XCTest
@testable import InsightKitApp

final class LiveReviewPresentationPlanTests: XCTestCase {
    func testReviewingWithGeneratedSmartMinutesUsesSummaryFirstPresentation() {
        let minutes = SmartMinutes(
            structuredSummary: "Generated Smart Minutes are ready.",
            highlights: ["High signal moment"],
            speakerSummaries: [
                SpeakerMinutesSummary(speakerName: "Speaker", summary: "Speaker perspective")
            ],
            keyDecisions: ["Ship summary-first review"],
            actionItems: ["Retest completed review interface"],
            chapters: [
                ChapterSummary(timestamp: 3, title: "Decision", summary: "Summary is ready")
            ]
        )

        let plan = LiveReviewPresentationPlan.resolve(phase: .reviewing, smartMinutes: minutes)

        XCTAssertEqual(plan.mode, .summaryFirst)
    }

    func testSummaryReviewWithExportableMinutesShowsExportActions() {
        let minutes = SmartMinutes(structuredSummary: "Exportable Smart Minutes are ready.")

        let plan = LiveReviewPresentationPlan.resolve(
            phase: .reviewing,
            smartMinutes: minutes,
            canExportDocument: true
        )

        XCTAssertEqual(plan.exportActions.map(\.title), ["导出 Markdown", "导出 PDF"])
        XCTAssertEqual(plan.exportActions.map(\.format), ["markdown", "pdf"])
        XCTAssertEqual(
            plan.exportActions.map(\.accessibilityIdentifier),
            ["live_summary_export_markdown_button", "live_summary_export_pdf_button"]
        )
    }

    func testReviewingWithoutSmartMinutesKeepsTranscriptFirstPresentation() {
        let plan = LiveReviewPresentationPlan.resolve(phase: .reviewing, smartMinutes: nil)

        XCTAssertEqual(plan.mode, .transcriptFirst)
    }
}
