import XCTest
@testable import InsightKitApp

// MARK: - Helpers

private func makeEmptyPackage(timelineBeats: [InsightPackageV1.TimelineBeat] = []) -> InsightPackageV1 {
    InsightPackageV1(
        sessionOverview: .init(title: "", overview: "", topics: []),
        highlightInsights: [],
        speakerPerspectives: [],
        decisionLedger: [],
        actionTracks: [],
        timelineBeats: timelineBeats,
        provenanceLinks: []
    )
}

private func makeRefreshResult(beats: [InsightPackageV1.TimelineBeat] = []) -> InsightRefreshResult {
    InsightRefreshResult(
        package: makeEmptyPackage(timelineBeats: beats),
        updatedAt: Date(),
        provider: "openai",
        needsReviewCount: 0
    )
}

private func makeViewModel() -> LiveSessionViewModel {
    LiveSessionViewModel(
        rpcClient: RPCClientMock(),
        sidecarManager: SidecarManager(),
        micCapture: MicCaptureService(),
        systemAudioCapture: SystemAudioCaptureService(),
        mixBus: AudioMixBus(),
        chunkAssembler: ChunkAssembler(),
        asrService: LiveASRService()
    )
}

// MARK: - Chapter Update Tests

final class ChapterUpdateIntegrationTests: XCTestCase {

    @MainActor
    func testUpdateWorkbenchPopulatesChapters() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.chapters.isEmpty)

        let beats: [InsightPackageV1.TimelineBeat] = [
            .init(timestamp: "01:30", title: "开场", summary: "介绍议题"),
            .init(timestamp: "05:00", title: "讨论", summary: "核心讨论"),
        ]
        vm.updateWorkbench(makeRefreshResult(beats: beats))

        XCTAssertEqual(vm.chapters.count, 2)
        XCTAssertEqual(vm.chapters[0].title, "开场")
        XCTAssertEqual(vm.chapters[1].title, "讨论")
    }

    @MainActor
    func testUpdateWorkbenchParsesMMSSTimestamp() {
        let vm = makeViewModel()
        let beats = [InsightPackageV1.TimelineBeat(timestamp: "01:30", title: "T", summary: "S")]
        vm.updateWorkbench(makeRefreshResult(beats: beats))

        XCTAssertEqual(vm.chapters[0].timestamp, 90.0)
    }

    @MainActor
    func testUpdateWorkbenchParsesHHMMSSTimestamp() {
        let vm = makeViewModel()
        let beats = [InsightPackageV1.TimelineBeat(timestamp: "01:02:03", title: "T", summary: "S")]
        vm.updateWorkbench(makeRefreshResult(beats: beats))

        XCTAssertEqual(vm.chapters[0].timestamp, 3723.0)
    }

    @MainActor
    func testUpdateWorkbenchWithEmptyBeatsLeavesChaptersEmpty() {
        let vm = makeViewModel()
        vm.updateWorkbench(makeRefreshResult(beats: []))
        XCTAssertTrue(vm.chapters.isEmpty)
    }

    @MainActor
    func testUpdateWorkbenchReplacesExistingChapters() {
        let vm = makeViewModel()
        vm.updateWorkbench(makeRefreshResult(beats: [
            .init(timestamp: "00:10", title: "A", summary: ""),
        ]))
        XCTAssertEqual(vm.chapters.count, 1)

        vm.updateWorkbench(makeRefreshResult(beats: [
            .init(timestamp: "00:10", title: "B", summary: ""),
            .init(timestamp: "00:20", title: "C", summary: ""),
        ]))
        XCTAssertEqual(vm.chapters.count, 2)
        XCTAssertEqual(vm.chapters[0].title, "B")
    }
}

// MARK: - Notes Editable State Tests

final class NotesEditableStateTests: XCTestCase {

    @MainActor
    func testIsEditableFalseInPreparingPhase() {
        let vm = makeViewModel()
        vm.sessionPhase = .preparing
        XCTAssertFalse(vm.isEditable)
    }

    @MainActor
    func testIsEditableTrueInRunningPhase() {
        let vm = makeViewModel()
        vm.sessionPhase = .running
        XCTAssertTrue(vm.isEditable)
    }

    @MainActor
    func testIsEditableTrueInPostSessionPhase() {
        let vm = makeViewModel()
        vm.sessionPhase = .postSession
        XCTAssertTrue(vm.isEditable)
    }

    @MainActor
    func testIsEditableTrueInReviewingPhase() {
        let vm = makeViewModel()
        vm.sessionPhase = .reviewing
        XCTAssertTrue(vm.isEditable)
    }

    @MainActor
    func testRecordingTimeReturnsRecordingDuration() {
        let vm = makeViewModel()
        vm.recordingDuration = 42.5
        XCTAssertEqual(vm.recordingTime, 42.5)
    }

    @MainActor
    func testOnNoteCreatedAppendsNote() {
        let vm = makeViewModel()
        vm.sessionPhase = .running
        vm.onNoteCreated("测试笔记", at: 10.0)

        XCTAssertEqual(vm.notes.count, 1)
        XCTAssertEqual(vm.notes[0].text, "测试笔记")
        XCTAssertEqual(vm.notes[0].timestamp, 10.0)
    }
}

// MARK: - Session Phase State Machine Tests

final class SessionPhaseStateMachineTests: XCTestCase {

    @MainActor
    func testOnSkipMinutesSetsReviewingPhase() {
        let vm = makeViewModel()
        vm.sessionPhase = .postSession
        vm.onSkipMinutes()
        XCTAssertEqual(vm.sessionPhase, .reviewing)
    }

    @MainActor
    func testCanGenerateMinutesTrueInPostSession() {
        let vm = makeViewModel()
        vm.sessionPhase = .postSession
        XCTAssertTrue(vm.canGenerateMinutes)
    }

    @MainActor
    func testCanGenerateMinutesTrueInReviewing() {
        let vm = makeViewModel()
        vm.sessionPhase = .reviewing
        XCTAssertTrue(vm.canGenerateMinutes)
    }

    @MainActor
    func testCanGenerateMinutesFalseInPreparing() {
        let vm = makeViewModel()
        vm.sessionPhase = .preparing
        XCTAssertFalse(vm.canGenerateMinutes)
    }

    @MainActor
    func testCanGenerateMinutesFalseInRunning() {
        let vm = makeViewModel()
        vm.sessionPhase = .running
        XCTAssertFalse(vm.canGenerateMinutes)
    }

    @MainActor
    func testResetForNewSessionRestoresPreparingPhase() {
        let vm = makeViewModel()
        vm.sessionPhase = .reviewing
        vm.resetForNewSession()
        XCTAssertEqual(vm.sessionPhase, .preparing)
    }

    @MainActor
    func testResetForNewSessionClearsChaptersAndNotes() {
        let vm = makeViewModel()
        vm.updateWorkbench(makeRefreshResult(beats: [
            .init(timestamp: "00:10", title: "A", summary: ""),
        ]))
        vm.onNoteCreated("note", at: 5.0)
        XCTAssertFalse(vm.chapters.isEmpty)
        XCTAssertFalse(vm.notes.isEmpty)

        vm.resetForNewSession()

        XCTAssertTrue(vm.chapters.isEmpty)
        XCTAssertTrue(vm.notes.isEmpty)
    }
}
