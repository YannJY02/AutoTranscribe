import XCTest
@testable import InsightKitApp

final class TranscriptionProviderGateTests: XCTestCase {
    func testImportIsBlockedWhenProviderConfigMissing() {
        let rpc = RPCClientMock()
        rpc.providersStatusStub = AnalysisProvidersStatus(
            selectedVendor: .deepseek,
            activeReady: false,
            activeProbeOK: nil,
            activeProbeErrorCode: .missingConfiguration,
            activeProbeMessage: "缺少配置",
            vendors: [
                .init(
                    vendor: .deepseek,
                    baseURL: "https://api.deepseek.com/v1",
                    modelID: "deepseek-chat",
                    configured: false,
                    hasAPIKey: false,
                    modelReady: true
                ),
            ]
        )

        let vm = TranscriptionSessionViewModel(
            rpcClient: rpc,
            autoRefresh: false,
            autoPolling: false,
            bootstrapSidecar: false
        )

        vm.importFile(path: "/tmp/example.wav", title: "example")

        let exp = expectation(description: "import blocked by missing provider config")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(rpc.importCalls.isEmpty)
        XCTAssertNotNil(vm.inlineError)
        XCTAssertTrue(vm.inlineError?.message.contains("未配置完成") == true)
    }
}
