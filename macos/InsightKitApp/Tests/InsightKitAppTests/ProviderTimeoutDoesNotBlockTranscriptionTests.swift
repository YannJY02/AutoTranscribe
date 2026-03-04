import XCTest
@testable import InsightKitApp

final class ProviderTimeoutDoesNotBlockTranscriptionTests: XCTestCase {
    func testImportContinuesWhenProviderStatusTimesOut() {
        let rpc = RPCClientMock()
        rpc.providersStatusError = NSError(
            domain: "InsightKit",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "调用超时: analysis.providers.status"]
        )

        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )

        vm.importFile(path: "/tmp/example.wav", title: "example")

        let exp = expectation(description: "import should proceed under provider timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.2)

        XCTAssertEqual(rpc.importCalls.count, 1)
        XCTAssertEqual(vm.analysisRuntimeState, .pausedTimeout)
        XCTAssertTrue(vm.inlineError?.message.contains("洞察已暂停") == true)
    }
}
