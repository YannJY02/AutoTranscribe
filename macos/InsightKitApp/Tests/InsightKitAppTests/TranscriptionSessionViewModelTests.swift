import Combine
import XCTest
@testable import InsightKitApp

final class TranscriptionSessionViewModelTests: XCTestCase {
    func testWatcherBeginsAnalyticsOnlyWhenAQueuedJobStartsRunning() {
        let rpc = RPCClientMock()
        let startedAt = Date().addingTimeInterval(1)
        let running = TranscriptionJob(
            id: "running", meetingID: "meeting-running", sourcePath: "/tmp/running.wav", title: "running",
            state: .running, progress: 20, stage: "running", error: "", reason: "",
            startedAt: startedAt, endedAt: nil
        )
        let queued = TranscriptionJob(
            id: "queued", meetingID: "meeting-queued", sourcePath: "/tmp/queued.wav", title: "queued",
            state: .queued, progress: 0, stage: "queued", error: "", reason: "",
            startedAt: startedAt, endedAt: nil
        )
        rpc.transcriptionStatusStub = TranscriptionStatusResult(
            watcher: .init(isRunning: true, dirs: ["/tmp"], queueSize: 1, activeJobID: running.id),
            queue: [queued], activeJob: running, lastCompleted: nil, jobs: [running, queued]
        )
        let lock = NSLock()
        var analyticsSubmissions = 0
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false,
            analyticsSubmit: { _ in
                lock.lock()
                analyticsSubmissions += 1
                lock.unlock()
            }
        )

        let refreshed = expectation(description: "watcher batch refreshed")
        var cancellables = Set<AnyCancellable>()
        vm.$jobs
            .dropFirst()
            .sink { jobs in
                if Set(jobs.map(\.id)) == ["running", "queued"] { refreshed.fulfill() }
            }
            .store(in: &cancellables)

        vm.startWatcher(dirs: ["/tmp"])

        wait(for: [refreshed], timeout: 1)
        lock.lock()
        let count = analyticsSubmissions
        lock.unlock()
        XCTAssertEqual(count, 1)
    }

    func testWatcherSkipsRestoredJobsWithUnknownStartTime() {
        let rpc = RPCClientMock()
        rpc.transcriptionStatusStub = TranscriptionStatusResult(
            watcher: .init(isRunning: true, dirs: ["/tmp"], queueSize: 0, activeJobID: nil),
            queue: [],
            activeJob: TranscriptionJob(
                id: "restored-active", meetingID: "meeting-active", sourcePath: "/tmp/active.wav", title: "active",
                state: .running, progress: 50, stage: "running", error: "", reason: "",
                startedAt: nil, endedAt: nil
            ),
            lastCompleted: nil,
            jobs: [
                TranscriptionJob(
                    id: "historical", meetingID: "meeting", sourcePath: "/tmp/old.wav", title: "old",
                    state: .completed, progress: 100, stage: "completed", error: "", reason: "",
                    startedAt: nil, endedAt: Date()
                ),
                TranscriptionJob(
                    id: "restored-active", meetingID: "meeting-active", sourcePath: "/tmp/active.wav", title: "active",
                    state: .running, progress: 50, stage: "running", error: "", reason: "",
                    startedAt: nil, endedAt: nil
                ),
            ]
        )
        let lock = NSLock()
        var analyticsSubmissions = 0
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false,
            analyticsSubmit: { _ in
                lock.lock()
                analyticsSubmissions += 1
                lock.unlock()
            }
        )

        let refreshed = expectation(description: "watcher status refreshed")
        var cancellables = Set<AnyCancellable>()
        vm.$jobs
            .dropFirst()
            .sink { jobs in
                if Set(jobs.map(\.id)) == ["historical", "restored-active"] {
                    refreshed.fulfill()
                }
            }
            .store(in: &cancellables)

        vm.startWatcher(dirs: ["/tmp"])

        wait(for: [refreshed], timeout: 1)
        lock.lock()
        let count = analyticsSubmissions
        lock.unlock()
        XCTAssertEqual(count, 0)
    }

    func testNewCompletionKeepsMeetingSelectionStableWhileAnotherJobIsActive() {
        let rpc = RPCClientMock()
        let completed = TranscriptionJob(
            id: "job-a", meetingID: "meeting-a", sourcePath: "/tmp/a.wav", title: "a",
            state: .completed, progress: 100, stage: "completed", error: "", reason: "",
            startedAt: Date().addingTimeInterval(-10), endedAt: Date()
        )
        let active = TranscriptionJob(
            id: "job-b", meetingID: "meeting-b", sourcePath: "/tmp/b.wav", title: "b",
            state: .running, progress: 50, stage: "running", error: "", reason: "",
            startedAt: Date(), endedAt: nil
        )
        rpc.transcriptionStatusStub = TranscriptionStatusResult(
            watcher: .init(isRunning: true, dirs: ["/tmp"], queueSize: 1, activeJobID: active.id),
            queue: [], activeJob: active,
            lastCompleted: .init(job: completed, meetingID: completed.meetingID, segmentsCount: 1, updatedAt: Date()),
            jobs: [active, completed]
        )
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc, autoRefresh: false, autoPolling: false, bootstrapSidecar: false
        )

        vm.refreshStatus()
        let first = expectation(description: "new completion selected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(vm.currentMeetingID, "meeting-a")
            vm.refreshStatus()
            first.fulfill()
        }
        wait(for: [first], timeout: 1)
        let second = expectation(description: "completed selection remains stable")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(vm.currentMeetingID, "meeting-a")
            second.fulfill()
        }
        wait(for: [second], timeout: 1)
    }

    func testAcceptedImportPublishesMeetingBeforeStatusRefreshSucceeds() {
        let rpc = RPCClientMock()
        rpc.transcriptionStatusError = NSError(domain: "test", code: 1)
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc, autoRefresh: false, autoPolling: false, bootstrapSidecar: false
        )

        vm.importFile(path: "/tmp/input.wav")

        let accepted = expectation(description: "accepted import state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(vm.currentMeetingID, "m-1")
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 1)
    }

    func testLocalAnalysisSkipsCloudProviderStatus() {
        let rpc = RPCClientMock()
        rpc.providersStatusError = NSError(domain: "unexpected-cloud-check", code: 1)
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        vm.analysisRuntimeState = .missingConfig
        vm.inlineError = InlineErrorState(message: "stale cloud warning", occurredAt: Date())
        let cleared = expectation(description: "local mode clears stale cloud status")
        var cancellables = Set<AnyCancellable>()

        vm.$inlineError
            .dropFirst()
            .sink { error in
                if error == nil {
                    cleared.fulfill()
                }
            }
            .store(in: &cancellables)

        _ = vm.refreshProviderStateNonBlocking(analysisMode: .local)
        wait(for: [cleared], timeout: 1)

        XCTAssertEqual(rpc.providersStatusCalls, 0)
        XCTAssertEqual(vm.analysisRuntimeState, .ready)
        XCTAssertNil(vm.inlineError)
    }

    func testSuccessfulFinalInsightRetryClearsStaleError() {
        let vm = TranscriptionSessionViewModel(
            rpcClient: RPCClientMock(),
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        vm.currentMeetingID = "retry-meeting"
        vm.errorMessage = "previous analysis failure"

        vm.buildFinalInsight()

        let completed = expectation(description: "final insight retry succeeded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { completed.fulfill() }
        wait(for: [completed], timeout: 1)
        XCTAssertNil(vm.errorMessage)
    }

    func testPreemptForLiveCancelsRunningJobAndStopsWatcher() throws {
        let rpc = RPCClientMock()
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )

        vm.watcherState = TranscriptionWatcherState(isRunning: true, dirs: ["/tmp"], queueSize: 1, activeJobID: "j-1")
        vm.jobs = [
            TranscriptionJob(
                id: "j-1",
                meetingID: "m-1",
                sourcePath: "/tmp/a.wav",
                title: "a",
                state: .running,
                progress: 45,
                stage: "running",
                error: "",
                reason: "",
                startedAt: Date(),
                endedAt: nil
            )
        ]

        vm.preemptForLive()

        let exp = expectation(description: "preempt calls")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(rpc.watchStopCalls, 1)
        XCTAssertTrue(rpc.cancelCalls.contains(where: { $0.jobID == "j-1" && $0.reason == "preempted_by_live" }))
    }

    func testTranscriptionExportPrefersPersistedNativePDFOverRPC() throws {
        let root = RecordExportTestFixture.makeRoot(prefix: "InsightKitTranscriptionExport")
        let recordID = "file-native-export"
        try RecordExportTestFixture.seedRecord(root: root, recordID: recordID, source: .imported)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordsService = RecordsIndexService()
        recordsService.rootDirectory = root
        let rpc = RPCClientMock()
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )
        vm.recordsService = recordsService
        vm.currentMeetingID = recordID
        XCTAssertTrue(vm.hasPersistedRecordForExport)

        var cancellables = Set<AnyCancellable>()
        let exp = expectation(description: "native transcription export")
        exp.assertForOverFulfill = false
        vm.$lastExportPath
            .dropFirst()
            .sink { path in
                if !path.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)
        vm.exportDocument(format: "pdf")

        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(rpc.documentExportCalls.isEmpty)
        XCTAssertEqual(URL(fileURLWithPath: vm.lastExportPath).pathExtension, "pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.lastExportPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: vm.lastExportPath))
        XCTAssertEqual(String(data: data.prefix(5), encoding: .utf8), "%PDF-")
    }
}
