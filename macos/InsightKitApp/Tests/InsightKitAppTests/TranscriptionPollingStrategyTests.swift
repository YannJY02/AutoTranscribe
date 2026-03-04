import XCTest
@testable import InsightKitApp

final class TranscriptionPollingStrategyTests: XCTestCase {
    func testPollingModeSwitchesBetweenIdleAndActive() {
        let rpc = RPCClientMock()
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )

        rpc.transcriptionStatusStub = TranscriptionStatusResult(
            watcher: .init(isRunning: false, dirs: [], queueSize: 0, activeJobID: nil),
            queue: [],
            activeJob: nil,
            lastCompleted: nil,
            jobs: []
        )

        vm.refreshStatus()
        let idleExp = expectation(description: "idle status")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(vm.pollingMode, .idle)
            idleExp.fulfill()
        }
        wait(for: [idleExp], timeout: 1.0)

        rpc.transcriptionStatusStub = TranscriptionStatusResult(
            watcher: .init(isRunning: true, dirs: ["/tmp"], queueSize: 1, activeJobID: "job-1"),
            queue: [],
            activeJob: TranscriptionJob(
                id: "job-1",
                meetingID: "m-1",
                sourcePath: "/tmp/a.wav",
                title: "a",
                state: .running,
                progress: 10,
                stage: "running",
                error: "",
                reason: "",
                startedAt: Date(),
                endedAt: nil
            ),
            lastCompleted: nil,
            jobs: [
                TranscriptionJob(
                    id: "job-1",
                    meetingID: "m-1",
                    sourcePath: "/tmp/a.wav",
                    title: "a",
                    state: .running,
                    progress: 10,
                    stage: "running",
                    error: "",
                    reason: "",
                    startedAt: Date(),
                    endedAt: nil
                ),
            ]
        )

        vm.refreshStatus()
        let activeExp = expectation(description: "active status")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(vm.pollingMode, .active)
            activeExp.fulfill()
        }
        wait(for: [activeExp], timeout: 1.0)
    }

    func testRefreshStatusIsSingleFlight() {
        let rpc = RPCClientMock()
        rpc.transcriptionStatusDelaySec = 0.3
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )

        vm.refreshStatus()
        vm.refreshStatus()

        let done = expectation(description: "single flight done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            XCTAssertEqual(rpc.transcriptionStatusCalls, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)
    }
}
