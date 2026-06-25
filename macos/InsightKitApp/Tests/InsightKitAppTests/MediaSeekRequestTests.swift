import XCTest
import AVKit
@testable import InsightKitApp

final class MediaSeekRequestTests: XCTestCase {
    func testMediaPlayerUsesMinimalControlsForAudioAndInlineControlsForVideo() {
        XCTAssertEqual(
            MediaPlayerView.controlsStyle(forMediaURL: URL(fileURLWithPath: "/tmp/sample.m4a")),
            .minimal
        )
        XCTAssertEqual(
            MediaPlayerView.controlsStyle(forMediaURL: URL(fileURLWithPath: "/tmp/sample.mp4")),
            .inline
        )
    }

    @MainActor
    func testMediaPlayerDismantleReleasesPlayerAndView() throws {
        let coordinator = MediaPlayerView.Coordinator(onSeek: nil, onTimeUpdate: nil)
        let playerView = AVPlayerView()
        coordinator.playerView = playerView

        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitMediaPlayerTests-\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: mediaURL.path, contents: Data())
        addTeardownBlock {
            try? FileManager.default.removeItem(at: mediaURL)
        }

        coordinator.loadURL(mediaURL)

        XCTAssertNotNil(coordinator.player)
        XCTAssertNotNil(playerView.player)
        XCTAssertEqual(coordinator.currentURL, mediaURL)

        coordinator.dismantle(from: playerView)

        XCTAssertNil(coordinator.player)
        XCTAssertNil(playerView.player)
        XCTAssertNil(coordinator.currentURL)
    }

    func testImportTranscriptTapCreatesSeekRequest() {
        let vm = ImportSessionViewModel()
        let entry = TranscriptEntry(timestamp: 42.5, speaker: "SPEAKER_00", text: "next topic")

        vm.onTranscriptEntryTapped(entry)

        XCTAssertEqual(vm.currentPlaybackTime, 42.5)
        XCTAssertEqual(vm.mediaSeekRequest?.time, 42.5)
    }

    func testImportRepeatedTapCreatesDistinctSeekRequest() {
        let vm = ImportSessionViewModel()
        let note = TimestampedNote(text: "decision", timestamp: 12)

        vm.onNoteTapped(note)
        let first = vm.mediaSeekRequest?.id
        vm.onNoteTapped(note)

        XCTAssertEqual(vm.mediaSeekRequest?.time, 12)
        XCTAssertNotEqual(vm.mediaSeekRequest?.id, first)
    }

    func testLiveReviewTranscriptTapCreatesSeekRequest() {
        let vm = LiveSessionViewModel(rpcClient: RPCClientMock())
        vm.sessionPhase = .reviewing
        let entry = TranscriptEntry(timestamp: 31, speaker: nil, text: "chapter start")

        vm.onTranscriptEntryTapped(entry)

        XCTAssertEqual(vm.currentPlaybackTime, 31)
        XCTAssertEqual(vm.mediaSeekRequest?.time, 31)
    }

    func testLiveReviewTranscriptTapRequestsPlayback() {
        let vm = LiveSessionViewModel(rpcClient: RPCClientMock())
        vm.sessionPhase = .reviewing
        let entry = TranscriptEntry(timestamp: 31, speaker: nil, text: "chapter start")

        vm.onTranscriptEntryTapped(entry)

        XCTAssertTrue(vm.reviewSourcePlaybackRequested)
    }

    func testLiveReviewChapterTapRequestsPlayback() {
        let vm = LiveSessionViewModel(rpcClient: RPCClientMock())
        vm.sessionPhase = .reviewing
        let chapter = ChapterSummary(timestamp: 12, title: "Opening", summary: "Started the review.")

        vm.onChapterTapped(chapter)

        XCTAssertEqual(vm.mediaSeekRequest?.time, 12)
        XCTAssertTrue(vm.reviewSourcePlaybackRequested)
    }

    func testRecordReviewChapterTapCreatesVisibleSeekStatus() throws {
        let dataSource = try makeRecordReviewDataSource()
        let chapter = ChapterSummary(timestamp: 11, title: "提出解决方案", summary: "告知用户注册。")

        dataSource.onChapterTapped(chapter)

        XCTAssertEqual(dataSource.currentPlaybackTime, 11)
        XCTAssertEqual(dataSource.mediaSeekRequest?.time, 11)
        XCTAssertEqual(dataSource.seekStatusMessage, "已跳转到 00:11 · 章节：提出解决方案")
    }

    func testRecordReviewTranscriptAndNoteTapsCreateDistinctSeekRequests() throws {
        let dataSource = try makeRecordReviewDataSource()
        let entry = TranscriptEntry(timestamp: 19.8, speaker: "spk1", text: "they need to register for it")
        let note = TimestampedNote(text: "检查注册提示", timestamp: 29)

        dataSource.onTranscriptEntryTapped(entry)
        let transcriptRequestID = try XCTUnwrap(dataSource.mediaSeekRequest?.id)

        XCTAssertEqual(dataSource.currentPlaybackTime, 19.8)
        XCTAssertEqual(dataSource.mediaSeekRequest?.time, 19.8)
        XCTAssertEqual(dataSource.seekStatusMessage, "已跳转到 00:20 · 逐字稿：spk1")

        dataSource.onNoteTapped(note)

        XCTAssertEqual(dataSource.currentPlaybackTime, 29)
        XCTAssertEqual(dataSource.mediaSeekRequest?.time, 29)
        XCTAssertNotEqual(dataSource.mediaSeekRequest?.id, transcriptRequestID)
        XCTAssertEqual(dataSource.seekStatusMessage, "已跳转到 00:29 · 笔记：检查注册提示")
    }

    private func makeRecordReviewDataSource() throws -> RecordReviewDataSource {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitRecordSeekTests-\(UUID().uuidString)")
        let recordDir = root.appendingPathComponent("record-seek")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let metadata = RecordMetadata(
            id: "record-seek",
            createdAt: Date(),
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: [],
            summaryPreview: nil
        )
        return RecordReviewDataSource(metadata: metadata, rootDirectory: root)
    }
}
