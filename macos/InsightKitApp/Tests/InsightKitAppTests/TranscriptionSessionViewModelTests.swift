import XCTest
@testable import InsightKitApp

final class TranscriptionSessionViewModelTests: XCTestCase {
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
}
