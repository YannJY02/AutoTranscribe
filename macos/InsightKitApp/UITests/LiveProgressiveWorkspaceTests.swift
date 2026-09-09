import XCTest

final class LiveProgressiveWorkspaceTests: InsightKitUITests {
    override var launchEnvironmentOverrides: [String: String] {
        ["INSIGHTKIT_UI_TEST_ROUTE": "live", "INSIGHTKIT_UI_TEST_SCENARIO": "live-delayed-summary"]
    }

    override var launchArgumentOverrides: [String] { ["--ui-test-route=live"] }

    func testSecondTranscriptAppearsBeforeDelayedSummary() throws {
        let start = button("live_start_recording_button", fallbackLabel: "开始录制")
        XCTAssertTrue(waitForElement(start, timeout: 5))
        start.click()
        let secondTranscript = element("live_transcript_entry_1")
        let appearedWhileSummaryWaited = waitForElement(secondTranscript, timeout: 1.5)
        attachScreenshot(named: "live-delayed-summary-transcript")
        XCTAssertTrue(appearedWhileSummaryWaited,
                      "Second transcript must appear while the same fixture's six-second summary is still waiting")
        XCTAssertEqual(secondTranscript.label, "第二句话应该继续显示，不必等待摘要。")
        button("live_stop_recording_button", fallbackLabel: "停止录制").click()
        XCTAssertTrue(waitForElement(element("live_phase_post_session"), timeout: 1.5),
                      "Stopping must not wait for the delayed summary")
    }
}
