import XCTest
@testable import InsightKitApp

final class TranscriptionErrorThrottleTests: XCTestCase {
    func testDuplicateErrorsAreThrottled() {
        let rpc = RPCClientMock()
        rpc.transcriptionStatusError = NSError(
            domain: "InsightKitTests",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "mock transcription failure"]
        )
        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )

        vm.refreshStatus()
        let first = expectation(description: "first error published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            first.fulfill()
        }
        wait(for: [first], timeout: 1.0)
        let firstError = vm.inlineError
        XCTAssertNotNil(firstError)

        vm.refreshStatus()
        let second = expectation(description: "second poll")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            second.fulfill()
        }
        wait(for: [second], timeout: 1.0)

        XCTAssertEqual(vm.inlineError?.occurredAt, firstError?.occurredAt)
    }
}
