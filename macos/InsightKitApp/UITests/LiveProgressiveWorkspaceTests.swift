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

final class LiveSlowSummaryWorkspaceTests: InsightKitUITests {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "INSIGHTKIT_UI_TEST_ROUTE": "live",
            "INSIGHTKIT_UI_TEST_SCENARIO": "live-delayed-summary",
            "INSIGHTKIT_RPC_TIMEOUT_SEC": "1",
            "INSIGHTKIT_LIVE_INSIGHT_RPC_TIMEOUT_SEC": "10",
            "INSIGHTKIT_RPC_MAX_RETRIES": "0",
        ]
    }

    override var launchArgumentOverrides: [String] { ["--ui-test-route=live"] }

    func testDelayedSummaryAppearsBeforeRecordingStops() throws {
        let start = button("live_start_recording_button", fallbackLabel: "开始录制")
        XCTAssertTrue(waitForElement(start, timeout: 5))
        start.click()
        XCTAssertTrue(waitForElement(element("live_transcript_entry_1"), timeout: 1.5))
        attachScreenshot(named: "live-summary-pending")

        let summary = element("live_smart_minutes_summary_body")
        let appeared = waitForElement(summary, timeout: 10)
        attachScreenshot(named: "live-summary-after-provider-response")
        XCTAssertTrue(appeared, "A valid live summary must survive the shorter general RPC deadline")
        XCTAssertEqual(stringValue(of: summary), "延迟摘要已完成")
        XCTAssertTrue(element("live_phase_running").exists,
                      "Minutes must appear during recording, without requiring final generation")
        button("live_stop_recording_button", fallbackLabel: "停止录制").click()
        XCTAssertTrue(waitForElement(element("live_phase_post_session"), timeout: 1.5))
    }
}
