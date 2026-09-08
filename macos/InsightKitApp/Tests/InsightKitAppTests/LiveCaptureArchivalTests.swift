import AVFoundation
import Combine
import XCTest
@testable import InsightKitApp

final class LiveCaptureArchivalTests: XCTestCase {
    func testStopPreservesAcceptedAudioWhileTranscriptionIsBlocked() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let pipeline = fixture.pipeline
        let entered = expectation(description: "first chunk occupies transcription pipeline")
        pipeline.onFirstChunk = { entered.fulfill() }
        defer { pipeline.releaseFirstChunk.signal() }

        viewModel.handleMixedSamples(Array(repeating: 0.1, count: 32_000))
        wait(for: [entered], timeout: 2)
        viewModel.handleMixedSamples(Array(repeating: 0.2, count: 128_000))
        viewModel.handleMixedSamples(Array(repeating: 0.3, count: 128_000))
        viewModel.handleMixedSamples(Array(repeating: 0.4, count: 8_000))

        let archived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: fixture.chunkDirectory.path)) ?? []
            return files.filter { $0.hasSuffix(".wav") }.count == 3
        }, object: nil)
        wait(for: [archived], timeout: 2)

        var cancellables = Set<AnyCancellable>()
        let saved = expectation(description: "record saved after all accepted audio is archived")
        viewModel.$lastExportPath.filter { !$0.isEmpty }.prefix(1)
            .sink { _ in saved.fulfill() }.store(in: &cancellables)

        viewModel.stopLiveSession()
        XCTAssertTrue(fixture.rpc.recordsSaveCalls.isEmpty)
        pipeline.releaseFirstChunk.signal()
        wait(for: [saved], timeout: 5)

        let save = try XCTUnwrap(fixture.rpc.recordsSaveCalls.first)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: save.sourcePath))
        XCTAssertEqual(audio.length, 296_000, "ASR latency must not shorten the saved recording")
        audio.framePosition = audio.length - 8_000
        let tail = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8_000))
        try audio.read(into: tail)
        XCTAssertEqual(tail.frameLength, 8_000)
        XCTAssertEqual(try XCTUnwrap(tail.floatChannelData)[0][7_999], 0.4, accuracy: 0.0001)
    }

    func testPausePreservesPreviouslyAcceptedAudioAndExcludesPausedAudio() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let entered = expectation(description: "first chunk occupies transcription pipeline")
        fixture.pipeline.onFirstChunk = { entered.fulfill() }
        defer { fixture.pipeline.releaseFirstChunk.signal() }
        viewModel.handleMixedSamples(Array(repeating: 0.1, count: 32_000))
        wait(for: [entered], timeout: 2)
        viewModel.handleMixedSamples(Array(repeating: 0.2, count: 128_000))
        viewModel.pauseLiveSession()
        viewModel.handleMixedSamples(Array(repeating: 0.9, count: 128_000))
        viewModel.resumeLiveSession()
        viewModel.handleMixedSamples(Array(repeating: 0.3, count: 8_000))

        var cancellables = Set<AnyCancellable>()
        let saved = expectation(description: "paused recording saved")
        viewModel.$lastExportPath.filter { !$0.isEmpty }.prefix(1)
            .sink { _ in saved.fulfill() }.store(in: &cancellables)
        viewModel.stopLiveSession()
        fixture.pipeline.releaseFirstChunk.signal()
        wait(for: [saved], timeout: 5)

        let save = try XCTUnwrap(fixture.rpc.recordsSaveCalls.first)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: save.sourcePath))
        XCTAssertEqual(audio.length, 168_000)
    }

    func testRuntimeFinalizationFailurePreservesRecordedAudioBeforeChunkCleanup() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        fixture.rpc.sessionStopForFinalizationError = NSError(
            domain: "LiveCaptureArchivalTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "planned finalization failure"]
        )
        var cancellables = Set<AnyCancellable>()
        let failed = expectation(description: "runtime finalization failed")
        viewModel.$captureState.filter {
            if case .error = $0 { return true }
            return false
        }.prefix(1).sink { _ in failed.fulfill() }.store(in: &cancellables)

        viewModel.handleMixedSamples(Array(repeating: 0.3, count: 8_000))
        viewModel.stopLiveSession()
        wait(for: [failed], timeout: 5)
        viewModel.pipelineQueue.sync {}
        viewModel.rpcQueue.sync {}

        let mediaURL = try XCTUnwrap(viewModel.temporaryRecordingURL)
        let audio = try AVAudioFile(forReading: mediaURL)
        XCTAssertEqual(audio.length, 8_000, "A transcript/runtime failure must not delete captured media")
    }

    func testMixedSourcePauseFlushesAcceptedTailAndRejectsPausedBuffersBeforeMixing() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        viewModel.mixBus.setMode(.mixed)
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.configureAudioCaptureCallbacks(meetingID: meetingID)
        viewModel.handleCapturedBuffer(makeBuffer(value: 0.2, count: 1_600), source: .microphone, meetingID: meetingID)
        viewModel.pauseLiveSession()
        viewModel.handleCapturedBuffer(makeBuffer(value: 0.9, count: 1_600), source: .microphone, meetingID: meetingID)
        viewModel.resumeLiveSession()
        viewModel.handleCapturedBuffer(makeBuffer(value: 0.4, count: 1_600), source: .microphone, meetingID: meetingID)
        // A retired source callback must not enter the current session's mixer.
        viewModel.handleCapturedBuffer(makeBuffer(value: 0.9, count: 1_600), source: .microphone, meetingID: "retired")

        var cancellables = Set<AnyCancellable>()
        let saved = expectation(description: "mixed pause recording saved")
        viewModel.$lastExportPath.filter { !$0.isEmpty }.prefix(1)
            .sink { _ in saved.fulfill() }.store(in: &cancellables)
        viewModel.stopLiveSession()
        wait(for: [saved], timeout: 5)

        let save = try XCTUnwrap(fixture.rpc.recordsSaveCalls.first)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: save.sourcePath))
        XCTAssertEqual(audio.length, 3_200)
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 3_200))
        try audio.read(into: samples)
        XCTAssertEqual(samples.floatChannelData![0][0], 0.12, accuracy: 0.0001)
        XCTAssertEqual(samples.floatChannelData![0][3_199], 0.24, accuracy: 0.0001)
    }

    func testAudioTimelineStartsAtSourceReceiptBeforeMixerBuffering() async throws {
        var uptime: TimeInterval = 100
        let fixture = try makeFixture(recordingUptime: { uptime })
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.mixBus.setMode(.mixed)
        viewModel.handleCapturedBuffer(makeBuffer(value: 0.2, count: 1_600), source: .microphone, meetingID: meetingID)
        XCTAssertEqual(viewModel.stateQueue.sync { viewModel.captureTimeline.audioStartSec ?? 0 }, 99.9, accuracy: 0.0001)
        uptime = 100.5
        await viewModel.mixBus.finish()
        viewModel.audioArchiveQueue.sync {}
        XCTAssertEqual(viewModel.stateQueue.sync { viewModel.captureTimeline.audioStartSec ?? 0 }, 99.9, accuracy: 0.0001,
                       "Mixer buffering delay must not become an AV composition offset")
    }

    func testSystemAudioCallbackPreservesSourceTimeThroughDelayedArchival() async throws {
        var uptime: TimeInterval = 100.51
        let fixture = try makeFixture(recordingUptime: { uptime })
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.mixBus.setMode(.systemAudio)
        viewModel.configureAudioCaptureCallbacks(meetingID: meetingID)
        viewModel.systemAudioCapture.onBuffer?(makeBuffer(value: 0.2, count: 160), 100)
        XCTAssertEqual(viewModel.stateQueue.sync { viewModel.captureTimeline.audioStartSec ?? 0 }, 100,
                       accuracy: 0.000001, "Source PTS must survive the capture callback wiring")

        uptime = 101
        await viewModel.mixBus.finish()
        viewModel.audioArchiveQueue.sync {}
        XCTAssertEqual(viewModel.stateQueue.sync { viewModel.captureTimeline.audioStartSec ?? 0 }, 100,
                       accuracy: 0.000001, "Archival receipt must not reanchor source-timed audio")
    }

    func testAlreadyWarmASRWaitsUntilTheMeetingSessionExists() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.stateQueue.sync { viewModel.runtimeSessionStartingMeetingID = meetingID }
        fixture.pipeline.releaseFirstChunk.signal()
        viewModel.handleMixedSamples(Array(repeating: 0.2, count: 32_000))
        viewModel.audioArchiveQueue.sync {}
        viewModel.pipelineQueue.sync {}
        XCTAssertEqual(fixture.pipeline.processedChunkCount, 0)

        viewModel.stateQueue.sync { viewModel.runtimeSessionStartingMeetingID = nil }
        viewModel.pipelineQueue.sync { viewModel.pumpChunkQueueIfNeeded(meetingID: meetingID) }
        XCTAssertEqual(fixture.pipeline.processedChunkCount, 1)
    }

    func testRecordingBeginsWhileRuntimeIsQueuedAndStopCannotRestartCapture() throws {
        let engine = ArchivalMicEngine()
        let mic = MicCaptureService(engine: engine, permissionProvider: ArchivalMicPermission())
        let fixture = try makeFixture(micCapture: mic, active: false)
        let viewModel = fixture.viewModel
        let runtimeHeld = expectation(description: "runtime is still preparing")
        let releaseRuntime = DispatchSemaphore(value: 0)
        defer { releaseRuntime.signal() }
        viewModel.rpcQueue.async {
            runtimeHeld.fulfill()
            _ = releaseRuntime.wait(timeout: .now() + 10)
        }
        wait(for: [runtimeHeld], timeout: 2)
        var cancellables = Set<AnyCancellable>()
        let recording = expectation(description: "media capture starts before the runtime is ready")
        viewModel.$sessionPhase.filter { $0 == .running }.prefix(1)
            .sink { _ in recording.fulfill() }.store(in: &cancellables)

        viewModel.startLiveSession()
        XCTAssertTrue(viewModel.isPreparingRecording)
        XCTAssertFalse(viewModel.isActivelyRecording)
        wait(for: [recording], timeout: 2)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertTrue(viewModel.isActivelyRecording)
        XCTAssertNotNil(viewModel.recordingDurationTimer)
        let stopped = expectation(description: "stopped recording is saved")
        viewModel.$lastExportPath.filter { !$0.isEmpty }.prefix(1)
            .sink { _ in stopped.fulfill() }.store(in: &cancellables)
        viewModel.stopLiveSession()
        XCTAssertFalse(viewModel.isActivelyRecording)
        XCTAssertNil(viewModel.recordingDurationTimer)
        releaseRuntime.signal()
        wait(for: [stopped], timeout: 5)
        XCTAssertEqual(engine.startCount, 1, "Completing old runtime work must not restart capture")
        XCTAssertFalse(engine.isCapturing)
        XCTAssertNil(viewModel.recordingDurationTimer)
    }

    func testSelectedVideoStaysPreparingUntilFirstFrameAndStopCancelsThatWait() throws {
        let engine = ArchivalMicEngine()
        let mic = MicCaptureService(engine: engine, permissionProvider: ArchivalMicPermission())
        let fixture = try makeFixture(micCapture: mic)
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.visualPreviewSource = .screen
        viewModel.videoCaptureService.isCapturing = true
        viewModel.sessionPhase = .preparing
        viewModel.beginCaptureStartup(meetingID: meetingID, mode: .microphone, systemSourceID: nil)
        let armed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            viewModel.temporaryRecordingURL != nil
        }, object: nil)
        wait(for: [armed], timeout: 2)
        XCTAssertTrue(viewModel.isPreparingRecording)
        XCTAssertFalse(viewModel.isActivelyRecording)
        XCTAssertNil(viewModel.recordingDurationTimer)
        viewModel.handleMixedSamples(Array(repeating: 0.3, count: 32_000))
        viewModel.audioArchiveQueue.sync {}
        viewModel.pipelineQueue.sync {}
        XCTAssertEqual(fixture.pipeline.processedChunkCount, 0, "Provisional audio must not enter ASR")

        var cancellables = Set<AnyCancellable>()
        let cancelled = expectation(description: "cancelled first-frame wait discards provisional media")
        viewModel.$isFinalizingLiveSession.dropFirst().filter { !$0 }.prefix(1)
            .sink { _ in cancelled.fulfill() }.store(in: &cancellables)
        viewModel.stopLiveSession()
        viewModel.videoCaptureService.onRecordingFirstFrame?(ProcessInfo.processInfo.systemUptime)
        wait(for: [cancelled], timeout: 5)
        XCTAssertFalse(viewModel.isActivelyRecording)
        XCTAssertNil(viewModel.recordingDurationTimer)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertEqual(viewModel.sessionPhase, .preparing)
        XCTAssertTrue(fixture.rpc.recordsSaveCalls.isEmpty)
        XCTAssertTrue(viewModel.lastExportPath.isEmpty)
        XCTAssertNil(viewModel.temporaryRecordingURL)
        XCTAssertNil(viewModel.currentBuildTargetID())
        XCTAssertEqual(fixture.pipeline.processedChunkCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.chunkDirectory.path).isEmpty)
    }

    func testFirstFrameTimeoutDiscardsAudioFromAnUnstartedVisualRecording() throws {
        let engine = ArchivalMicEngine()
        let fixture = try makeFixture(micCapture: MicCaptureService(
            engine: engine, permissionProvider: ArchivalMicPermission()
        ))
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.visualPreviewSource = .screen
        viewModel.videoCaptureService.isCapturing = true
        var cancellables = Set<AnyCancellable>()
        let stopped = expectation(description: "first-frame timeout finishes cleanup")
        viewModel.$isFinalizingLiveSession.dropFirst().filter { !$0 }.prefix(1)
            .sink { _ in stopped.fulfill() }.store(in: &cancellables)
        viewModel.beginCaptureStartup(
            meetingID: meetingID, mode: .microphone, systemSourceID: nil, readinessTimeoutSec: 0.05
        )
        wait(for: [stopped], timeout: 3)
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertEqual(viewModel.recordingDuration, 0)
        XCTAssertNil(viewModel.recordingDurationTimer)
        XCTAssertTrue(fixture.rpc.recordsSaveCalls.isEmpty)
        XCTAssertNil(viewModel.temporaryRecordingURL)
        XCTAssertEqual(fixture.pipeline.processedChunkCount, 0)
        XCTAssertTrue(viewModel.errorMessage?.contains("未收到可录制的视频画面") == true)
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(atPath: fixture.chunkDirectory.path)) ?? []
        XCTAssertTrue(remainingFiles.isEmpty)
    }

    func testAcceptedVisualStartRetainsAudioAcrossTheFirstFrameBoundary() throws {
        let engine = ArchivalMicEngine()
        let fixture = try makeFixture(micCapture: MicCaptureService(
            engine: engine, permissionProvider: ArchivalMicPermission()
        ))
        fixture.pipeline.releaseFirstChunk.signal()
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.visualPreviewSource = .screen
        viewModel.videoCaptureService.isCapturing = true
        viewModel.beginCaptureStartup(meetingID: meetingID, mode: .microphone, systemSourceID: nil)
        let armed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            viewModel.temporaryRecordingURL != nil
        }, object: nil)
        wait(for: [armed], timeout: 2)
        viewModel.handleMixedSamples(Array(repeating: 0.3, count: 8_000))
        viewModel.audioArchiveQueue.sync {}
        let sourceStart = viewModel.stateQueue.sync { viewModel.captureTimeline.audioStartSec }
        var cancellables = Set<AnyCancellable>()
        let started = expectation(description: "first frame accepts the recording")
        viewModel.$sessionPhase.filter { $0 == .running }.prefix(1)
            .sink { _ in started.fulfill() }.store(in: &cancellables)
        viewModel.videoCaptureService.onRecordingFirstFrame?(ProcessInfo.processInfo.systemUptime)
        wait(for: [started], timeout: 2)
        XCTAssertFalse(viewModel.stateQueue.sync { viewModel.visualRecordingStartPending })
        XCTAssertEqual(viewModel.stateQueue.sync { viewModel.captureTimeline.audioStartSec }, sourceStart)
        viewModel.handleMixedSamples(Array(repeating: 0.4, count: 8_000))
        let saved = expectation(description: "accepted audio interval is preserved")
        viewModel.$lastExportPath.filter { !$0.isEmpty }.prefix(1)
            .sink { _ in saved.fulfill() }.store(in: &cancellables)
        viewModel.stopLiveSession()
        wait(for: [saved], timeout: 5)
        let save = try XCTUnwrap(fixture.rpc.recordsSaveCalls.first)
        // The fake source only signals readiness, so this fixture saves the
        // audio fallback. All samples remain available to real A/V composition.
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: save.sourcePath))
        XCTAssertEqual(audio.length, 18_048)
    }

    func testCurrentVideoFailureStopsRecordingAndStaleFailureCannotStopIt() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.sessionPhase = .running
        viewModel.visualPreviewSource = .screen
        viewModel.videoCaptureService.isCapturing = true
        viewModel.configureVideoCaptureCallbacks(meetingID: "retired-meeting")
        let staleFailure = try XCTUnwrap(viewModel.videoCaptureService.onRecordingFailure)
        viewModel.configureVideoCaptureCallbacks(meetingID: meetingID)
        staleFailure("retired writer failure")
        XCTAssertTrue(viewModel.isActivelyRecording)
        XCTAssertNil(viewModel.errorMessage)

        viewModel.handleMixedSamples(Array(repeating: 0.3, count: 8_000))
        var cancellables = Set<AnyCancellable>()
        let saved = expectation(description: "active writer failure stops and preserves audio")
        viewModel.$lastExportPath.filter { !$0.isEmpty }.prefix(1)
            .sink { _ in saved.fulfill() }.store(in: &cancellables)
        viewModel.videoCaptureService.onRecordingFailure?("planned video writer failure")
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.errorMessage, "planned video writer failure")
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(viewModel.captureState, .error("planned video writer failure"))
        XCTAssertFalse(viewModel.isActivelyRecording)
        let save = try XCTUnwrap(fixture.rpc.recordsSaveCalls.first)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: save.sourcePath))
        XCTAssertEqual(audio.length, 8_000)
    }

    func testStopInvalidatesAStillPreparingVisualPreview() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let generation = viewModel.stateQueue.sync { viewModel.visualPreviewGeneration }
        XCTAssertTrue(viewModel.isCurrentVisualPreview(generation))
        viewModel.stopLiveSession()
        XCTAssertFalse(viewModel.isCurrentVisualPreview(generation))
    }

    func testDelayedPreviewSetupCompletesBeforeTheRecordingWriterIsArmed() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.visualPreviewSource = .screen
        // An overlay camera can report capturing while screen setup is pending.
        viewModel.videoCaptureService.isCapturing = true
        let setupGate = AsyncStream<Void>.makeStream()
        defer { setupGate.continuation.finish() }
        viewModel.visualPreviewSetupTask = Task { @MainActor in
            for await _ in setupGate.stream {
                // Reconfiguration must finish before there is a writer to clear.
                viewModel.videoCaptureService.stopRecording()
                viewModel.visualPreviewSetupTask = nil
                return
            }
        }
        let waiting = expectation(description: "recording waits for preview setup")
        let ready = expectation(description: "recording accepts its first frame after setup")
        let starting = Task { @MainActor in
            waiting.fulfill()
            do {
                try await viewModel.startVisualRecordingWhenReady(meetingID: meetingID)
                ready.fulfill()
            } catch {
                XCTFail("Preview setup should complete before recording starts: \(error)")
            }
        }
        defer { starting.cancel() }
        wait(for: [waiting], timeout: 2)
        XCTAssertNil(viewModel.temporaryRecordingURL, "Pending preview reconfiguration must not clear a newly armed writer")

        setupGate.continuation.yield(())
        let armed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            viewModel.temporaryRecordingURL != nil
        }, object: nil)
        wait(for: [armed], timeout: 2)
        viewModel.videoCaptureService.onRecordingFirstFrame?(ProcessInfo.processInfo.systemUptime)
        wait(for: [ready], timeout: 2)
    }

    @MainActor
    func testPreviewReadinessTimeoutDoesNotArmTheRecordingWriter() async throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.visualPreviewSource = .screen
        do {
            try await viewModel.startVisualRecordingWhenReady(meetingID: meetingID, timeoutSec: 0.05)
            XCTFail("A source that never becomes ready must not begin recording")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("视频采集尚未就绪"))
        }
        XCTAssertNil(viewModel.temporaryRecordingURL)
    }

    @MainActor
    func testPendingPermissionAndPreviewSetupDoNotConsumeReadinessTimeout() async throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.visualPreviewSource = .screen
        viewModel.visualPreviewPreparationPending = true
        var startingFinished = false
        let starting = Task { @MainActor in
            defer { startingFinished = true }
            try await viewModel.startVisualRecordingWhenReady(meetingID: meetingID, timeoutSec: 0.05)
        }
        defer { starting.cancel() }
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(startingFinished, "An open permission dialog must remain cancellable without timing out")
        XCTAssertNil(viewModel.temporaryRecordingURL)

        let setupGate = AsyncStream<Void>.makeStream()
        defer { setupGate.continuation.finish() }
        viewModel.visualPreviewSetupTask = Task {
            for await _ in setupGate.stream { return }
        }
        viewModel.visualPreviewPreparationPending = false
        viewModel.videoCaptureService.isCapturing = true
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(startingFinished, "A system sharing picker must not consume the stalled-source timeout")
        XCTAssertNil(viewModel.temporaryRecordingURL)

        setupGate.continuation.yield(())
        viewModel.visualPreviewSetupTask = nil
        for _ in 0..<100 where viewModel.temporaryRecordingURL == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(viewModel.temporaryRecordingURL)
        viewModel.videoCaptureService.onRecordingFirstFrame?(ProcessInfo.processInfo.systemUptime)
        try await starting.value
        XCTAssertTrue(startingFinished)
    }

    @MainActor
    func testCancelDuringInteractivePreviewSetupDoesNotArmAWriter() async throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        let meetingID = try XCTUnwrap(viewModel.currentActiveMeetingID())
        viewModel.visualPreviewSource = .screen
        viewModel.visualPreviewPreparationPending = true
        let starting = Task { @MainActor in
            try await viewModel.startVisualRecordingWhenReady(meetingID: meetingID, timeoutSec: 0.05)
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        starting.cancel()
        do {
            try await starting.value
            XCTFail("Explicit Cancel must end interactive setup")
        } catch is CancellationError {
        } catch {
            XCTFail("Interactive setup should cancel, not time out: \(error)")
        }
        XCTAssertNil(viewModel.temporaryRecordingURL)
    }

    func testPauseAndStopCaptureExactMonotonicDurationBetweenTimerTicks() throws {
        var uptime: TimeInterval = 100
        let fixture = try makeFixture(recordingUptime: { uptime })
        let viewModel = fixture.viewModel
        viewModel.transcriptSegments = [
            TranscriptSegment(startMs: 0, endMs: 1_800, speaker: "SPEAKER_00", source: "mic", text: "clock fixture")
        ]
        viewModel.startRecordingDurationTimer()
        uptime = 101.375
        viewModel.pauseLiveSession()
        XCTAssertEqual(viewModel.recordingDuration, 1.375, accuracy: 0.0001)
        uptime = 106.375
        viewModel.resumeLiveSession()
        uptime = 106.8
        var cancellables = Set<AnyCancellable>()
        let saved = expectation(description: "precise elapsed duration saved")
        viewModel.$lastExportPath.filter { !$0.isEmpty }.prefix(1)
            .sink { _ in saved.fulfill() }.store(in: &cancellables)
        viewModel.stopLiveSession()
        XCTAssertEqual(viewModel.recordingDuration, 1.8, accuracy: 0.0001)
        uptime = 120
        viewModel.updateRecordingDuration(at: uptime)
        XCTAssertEqual(viewModel.recordingDuration, 1.8, accuracy: 0.0001)
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(fixture.rpc.recordsSaveCalls.first?.durationSec ?? 0, 1.8, accuracy: 0.0001)
    }

    func testRecordingClockExcludesWaitingForTheSelectedVideoToBegin() throws {
        var uptime: TimeInterval = 103
        let fixture = try makeFixture(recordingUptime: { uptime })
        let viewModel = fixture.viewModel
        viewModel.stateQueue.sync {
            viewModel.captureTimeline.markAudioStartIfNeeded(at: 100)
            viewModel.captureTimeline.markVideoStart(at: 103)
        }
        viewModel.beginRecordingClockForCapturedMedia()
        XCTAssertEqual(viewModel.recordingDuration, 0, accuracy: 0.0001)
        uptime = 113
        viewModel.stopRecordingDurationTimer()
        XCTAssertEqual(viewModel.recordingDuration, 10, accuracy: 0.0001)
    }

    private func makeBuffer(value: Float, count: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        buffer.floatChannelData![0].initialize(repeating: value, count: count)
        return buffer
    }

    private func makeFixture(
        micCapture: MicCaptureService = MicCaptureService(),
        active: Bool = true,
        recordingUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws -> (
        viewModel: LiveSessionViewModel,
        pipeline: BlockingLiveTranscriptPipeline,
        rpc: RPCClientMock,
        chunkDirectory: URL
    ) {
        let meetingID = "capture-archive-test-\(UUID().uuidString)"
        let chunkDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(meetingID)
        let mediaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKit").appendingPathComponent(meetingID)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: chunkDirectory)
            try? FileManager.default.removeItem(at: mediaDirectory)
        }
        let pipeline = BlockingLiveTranscriptPipeline()
        let rpc = RPCClientMock()
        let viewModel = LiveSessionViewModel(
            rpcClient: rpc,
            sidecarManager: SidecarManager(),
            micCapture: micCapture,
            chunkAssembler: ChunkAssembler(chunkDir: chunkDirectory),
            transcriptPipeline: pipeline,
            finalMediaTranscriber: ArchivalMediaTranscriber(),
            analyticsSubmit: { _ in },
            recordingUptime: recordingUptime
        )
        viewModel.asrWarmStatus = ASRWarmStatus(
            ready: true, state: .ready, inProgress: false, attempt: 1, lastWarmMs: 0, lastError: ""
        )
        if active { viewModel.stateQueue.sync {
            viewModel._isRunningLock.lock()
            viewModel._isRunning = true
            viewModel._isRunningLock.unlock()
            viewModel._sessionState.activeMeetingID = meetingID
        } }
        if active { viewModel.sessionHandle = SessionHandle(activeMeetingID: meetingID, lastMeetingID: nil) }
        addTeardownBlock {
            if let url = viewModel.temporaryRecordingURL {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        return (viewModel, pipeline, rpc, chunkDirectory)
    }
}

private final class BlockingLiveTranscriptPipeline: LiveTranscriptProcessing {
    let releaseFirstChunk = DispatchSemaphore(value: 0)
    var onFirstChunk: (() -> Void)?
    private var processedFirstChunk = false
    private(set) var processedChunkCount = 0

    func reset() {}

    func process(chunk: AudioChunk, context: LiveTranscriptPipelineContext) throws -> LiveTranscriptPipelineOutcome {
        processedChunkCount += 1
        if !processedFirstChunk {
            processedFirstChunk = true
            onFirstChunk?()
            guard releaseFirstChunk.wait(timeout: .now() + 10) == .success else {
                throw NSError(domain: "LiveCaptureArchivalTests", code: 1)
            }
        }
        return LiveTranscriptPipelineOutcome(
            chunkIndex: chunk.index, latencyMs: 0, ingestedCount: 0, transcriptSegments: [],
            captureState: .capturing, firstSegmentMs: nil, lastTranscriptAt: nil,
            refresh: .none, providerMetric: nil, analysisRuntimeState: nil, errorMessage: nil
        )
    }
}

private struct ArchivalMediaTranscriber: FinalMediaTranscribing {
    func transcribeFinalMedia(mediaPath: String, source: String) throws -> [TranscriptSegment] { [] }
}

private struct ArchivalMicPermission: MicCapturePermissionProviding {
    func requestPermissionIfNeeded() async -> Bool { true }
}

private final class ArchivalMicEngine: MicCaptureEngineProviding {
    private var tap: ((AVAudioPCMBuffer) -> Void)?
    private(set) var startCount = 0
    private(set) var isCapturing = false

    func inputFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }
    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        tap = onBuffer
    }
    func removeTap() { tap = nil }
    func prepare() {}
    func start() throws {
        startCount += 1
        isCapturing = true
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat(), frameCapacity: 2_048)!
        buffer.frameLength = 2_048
        buffer.floatChannelData![0].initialize(repeating: 0.2, count: 2_048)
        tap?(buffer)
    }
    func stop() { isCapturing = false }
}
