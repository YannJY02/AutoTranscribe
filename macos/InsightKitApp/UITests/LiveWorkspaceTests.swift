import XCTest

final class LiveWorkspaceTests: InsightKitUITests {

    override var launchEnvironmentOverrides: [String: String] {
        ["INSIGHTKIT_UI_TEST_ROUTE": "live"]
    }

    override var launchArgumentOverrides: [String] {
        ["--ui-test-route=live"]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(waitForElement(element("live_workspace"), timeout: 8), "应直接进入实时转写工作区")
        XCTAssertTrue(waitForElement(button("live_start_recording_button", fallbackLabel: "开始录制"), timeout: 5), "开始录制按钮应显示")
    }

    func testSingleEntryGeneratedReviewFlowCoversPrimaryInteractions() throws {
        XCTAssertTrue(app.buttons["返回首页"].exists, "返回首页按钮应显示")

        assertToggleState(id: "mic", expected: "on")
        assertToggleState(id: "camera", expected: "off")
        assertToggleState(id: "screen", expected: "off")
        assertToggleState(id: "system", expected: "off")

        toggleSource(id: "camera")
        toggleSource(id: "screen")
        toggleSource(id: "system")
        assertToggleState(id: "camera", expected: "on")
        assertToggleState(id: "screen", expected: "on")
        assertToggleState(id: "system", expected: "on")
        attachScreenshot(named: "live-preparing-single-entry")

        startRecording()

        let noteInput = app.textViews["live_note_input"].exists
            ? app.textViews["live_note_input"]
            : app.textFields["live_note_input"]
        XCTAssertTrue(waitForElement(noteInput), "录制中应允许输入笔记")
        let submitButton = button("live_note_submit_button")
        enterText("note-123", into: noteInput)
        XCTAssertTrue(waitForElement(submitButton), "笔记提交按钮应显示")
        let draftText = element("live_note_draft_text")
        XCTAssertTrue(waitForElement(draftText), "应能读取笔记草稿标记")
        XCTAssertTrue(waitForStringValue("note-123", in: draftText, timeout: 3), "输入内容应同步到笔记草稿状态")
        XCTAssertTrue(waitForEnabled(submitButton, timeout: 3), "输入笔记后提交按钮应可用")
        submitButton.tap()
        let submitCount = element("live_note_submit_count")
        XCTAssertTrue(waitForElement(submitCount), "应能读取提交次数标记")
        XCTAssertTrue(waitForStringValue("1", in: submitCount, timeout: 3), "点击提交后应触发提交动作")
        let lastSubmittedText = element("live_note_last_submitted_text")
        XCTAssertTrue(waitForElement(lastSubmittedText), "应能读取最近一次提交文本")
        XCTAssertTrue(waitForStringValue("note-123", in: lastSubmittedText, timeout: 3), "提交动作应读到当前草稿内容")
        let notesCount = element("live_notes_count")
        XCTAssertTrue(waitForElement(notesCount), "应能读取笔记数量标记")
        XCTAssertTrue(waitForStringValue("1", in: notesCount, timeout: 3), "提交后笔记数量应增加")
        XCTAssertTrue(waitForElement(button("live_note_row_0"), timeout: 5), "新增笔记后应显示在列表中")
        attachScreenshot(named: "live-running-single-entry")

        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(waitForElement(element("live_phase_post_session"), timeout: 5))
        XCTAssertTrue(waitForElement(button("live_generate_minutes_button", fallbackLabel: "生成纪要"), timeout: 5))
        attachScreenshot(named: "live-post-session-single-entry")

        button("live_generate_minutes_button", fallbackLabel: "生成纪要").tap()
        XCTAssertTrue(waitForElement(element("live_phase_reviewing"), timeout: 5))
        XCTAssertTrue(waitForElement(element("live_smart_minutes_summary_title"), timeout: 5))
        XCTAssertTrue(waitForElement(element("live_smart_minutes_summary_body"), timeout: 5))
        XCTAssertTrue(waitForElement(button("live_chapter_row_0"), timeout: 5))

        let playbackLabel = app.staticTexts["live_current_playback_label"]
        XCTAssertTrue(waitForElement(playbackLabel), "回看态应显示当前播放时间")
        XCTAssertTrue(waitForStringValue("00:00", in: playbackLabel, timeout: 3))

        button("live_transcript_entry_1").tap()
        XCTAssertTrue(waitForStringValue("00:18", in: playbackLabel, timeout: 3))

        button("live_chapter_row_2").tap()
        XCTAssertTrue(waitForStringValue("00:42", in: playbackLabel, timeout: 3))

        button("live_note_row_0").tap()
        XCTAssertTrue(waitForStringValue("01:23", in: playbackLabel, timeout: 3))
        attachScreenshot(named: "live-review-generated-single-entry")
    }

    func testSingleEntrySkipMinutesFlow() throws {
        startRecording()
        app.typeKey(".", modifierFlags: .command)

        XCTAssertTrue(waitForElement(element("live_phase_post_session"), timeout: 5))
        XCTAssertTrue(waitForElement(button("live_skip_minutes_button", fallbackLabel: "跳过"), timeout: 5))
        button("live_skip_minutes_button", fallbackLabel: "跳过").tap()

        XCTAssertTrue(waitForElement(element("live_phase_reviewing"), timeout: 5))
        XCTAssertTrue(waitForElement(button("live_transcript_entry_0"), timeout: 5))
        XCTAssertTrue(waitForElement(element("live_notes_title"), timeout: 5))
        XCTAssertFalse(element("live_smart_minutes_summary_title").exists, "跳过纪要后不应显示纪要摘要")
        attachScreenshot(named: "live-review-skip-single-entry")
    }

    private func startRecording() {
        button("live_start_recording_button", fallbackLabel: "开始录制").tap()
        XCTAssertTrue(waitForElement(element("live_phase_running"), timeout: 5))
        XCTAssertTrue(waitForElement(button("live_pause_recording_button", fallbackLabel: "暂停"), timeout: 5))
        XCTAssertTrue(waitForElement(button("live_stop_recording_button", fallbackLabel: "停止录制"), timeout: 5))
        XCTAssertTrue(waitForElement(button("live_transcript_entry_0"), timeout: 5))
    }

    private func toggleSource(id: String) {
        button("live_source_toggle_\(id)").tap()
    }

    private func assertToggleState(id: String, expected: String) {
        let toggle = button("live_source_toggle_\(id)")
        XCTAssertTrue(waitForElement(toggle), "\(id) 开关应显示")
        XCTAssertEqual(stringValue(of: toggle), expected)
    }
}
