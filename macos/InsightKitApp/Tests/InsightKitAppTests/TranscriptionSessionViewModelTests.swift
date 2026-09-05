import Combine
import XCTest
@testable import InsightKitApp

final class TranscriptionSessionViewModelTests: XCTestCase {
    func testWatcherBatchDoesNotEmitEligibleImportAnalytics() {
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
        XCTAssertEqual(count, 0)
        XCTAssertNil(vm.transcriptAnalyticsContext())
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

    func testExplicitImportsAreSerializedUntilTheAcceptedAttemptTerminates() {
        let rpc = RPCClientMock()
        rpc.transcriptionStatusError = NSError(domain: "test", code: 1)
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc, autoRefresh: false, autoPolling: false, bootstrapSidecar: false
        )

        vm.importFile(path: "/tmp/first.wav")
        vm.importFile(path: "/tmp/second.wav")

        let accepted = expectation(description: "first import accepted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(rpc.importCalls.map(\.path), ["/tmp/first.wav"])
            XCTAssertFalse(vm.canStartExplicitImport)
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 1)
    }

    func testCancellingExplicitImportReleasesAdmissionWithoutStatusEcho() {
        let rpc = RPCClientMock()
        rpc.transcriptionImportResults = [
            .init(jobID: "job-cancel", meetingID: "meeting-cancel", state: .queued),
        ]
        rpc.transcriptionStatusError = NSError(domain: "test", code: 1)
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc, autoRefresh: false, autoPolling: false, bootstrapSidecar: false,
            analyticsSubmit: { _ in }
        )

        vm.importFile(path: "/tmp/cancel.wav")
        let accepted = expectation(description: "explicit import accepted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertFalse(vm.canStartExplicitImport)
            rpc.transcriptionStatusError = nil
            vm.cancelJob(jobID: "job-cancel")
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 1)

        let cancelled = expectation(description: "cancellation releases admission")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertTrue(vm.canStartExplicitImport)
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 1)
    }

    func testUnqualifiedSuccessfulExportReleasesExplicitImportAdmission() {
        let rpc = RPCClientMock()
        rpc.transcriptionStatusError = NSError(domain: "test", code: 1)
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc, autoRefresh: false, autoPolling: false, bootstrapSidecar: false,
            analyticsSubmit: { _ in }
        )

        vm.importFile(path: "/tmp/unqualified.wav")
        let accepted = expectation(description: "explicit import accepted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertFalse(vm.canStartExplicitImport)
            vm.exportDocument()
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 1)

        let exported = expectation(description: "unqualified export closes admission")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(rpc.documentExportCalls.count, 1)
            XCTAssertTrue(vm.canStartExplicitImport)
            exported.fulfill()
        }
        wait(for: [exported], timeout: 1)
    }

    func testCompletedExplicitJobsAreAllBuiltAndFailedLastCompletedIsSkipped() {
        let rpc = RPCClientMock()
        rpc.transcriptionImportResults = [
            .init(jobID: "job-1", meetingID: "meeting-1", state: .queued),
            .init(jobID: "job-2", meetingID: "meeting-2", state: .queued),
        ]
        rpc.transcriptionStatusError = NSError(domain: "test", code: 1)
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false,
            analyticsSubmit: { _ in }
        )

        vm.importFile(path: "/tmp/first.wav")
        let firstAccepted = expectation(description: "first accepted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { firstAccepted.fulfill() }
        wait(for: [firstAccepted], timeout: 1)

        let failed = TranscriptionJob(
            id: "job-1", meetingID: "meeting-1", sourcePath: "/tmp/first.wav", title: "first",
            state: .failed, progress: 100, stage: "failed", error: "fixture", reason: "",
            startedAt: Date().addingTimeInterval(-2), endedAt: Date().addingTimeInterval(-1)
        )
        rpc.transcriptionStatusError = nil
        rpc.transcriptionStatusStub = .init(
            watcher: .init(), queue: [], activeJob: nil,
            lastCompleted: .init(job: failed, meetingID: failed.meetingID, segmentsCount: 0, updatedAt: Date()),
            jobs: [failed]
        )
        vm.refreshStatus()
        let failureObserved = expectation(description: "failed job closes admission without building")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(vm.canStartExplicitImport)
            XCTAssertEqual(rpc.buildFinalCalls, 0)
            failureObserved.fulfill()
        }
        wait(for: [failureObserved], timeout: 1)

        rpc.transcriptionStatusError = NSError(domain: "test", code: 2)
        vm.importFile(path: "/tmp/second.wav")
        let secondAccepted = expectation(description: "second accepted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { secondAccepted.fulfill() }
        wait(for: [secondAccepted], timeout: 1)

        let completed1 = TranscriptionJob(
            id: "job-1", meetingID: "meeting-1", sourcePath: "/tmp/first.wav", title: "first",
            state: .completed, progress: 100, stage: "completed", error: "", reason: "",
            startedAt: Date().addingTimeInterval(-4), endedAt: Date().addingTimeInterval(-2)
        )
        let completed2 = TranscriptionJob(
            id: "job-2", meetingID: "meeting-2", sourcePath: "/tmp/second.wav", title: "second",
            state: .completed, progress: 100, stage: "completed", error: "", reason: "",
            startedAt: Date().addingTimeInterval(-3), endedAt: Date().addingTimeInterval(-1)
        )
        rpc.transcriptionStatusError = nil
        rpc.transcriptionStatusStub = .init(
            watcher: .init(), queue: [], activeJob: nil,
            lastCompleted: .init(job: completed2, meetingID: completed2.meetingID, segmentsCount: 1, updatedAt: Date()),
            jobs: [completed1, completed2]
        )
        vm.refreshStatus()
        let bothBuilt = expectation(description: "all explicit completions built")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            XCTAssertEqual(rpc.buildFinalMeetingIDs, ["meeting-1", "meeting-2"])
            bothBuilt.fulfill()
        }
        wait(for: [bothBuilt], timeout: 1)
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

        let suiteName = "TranscriptionSessionViewModelTests-records-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recordsService = RecordsIndexService(defaults: defaults, environment: [:])
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
