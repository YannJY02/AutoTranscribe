import XCTest
@testable import InsightKitApp

final class TranscriptionProviderGateTests: XCTestCase {
    func testImportContinuesWhenProviderConfigMissing() {
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
                    baseURL: "https://api.deepseek.com",
                    modelID: "deepseek-v4-flash",
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

        let exp = expectation(description: "import can start without provider config")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(rpc.importCalls.count, 1)
        XCTAssertEqual(vm.analysisRuntimeState, .missingConfig)
        XCTAssertTrue(vm.inlineError?.message.contains("本地提取草稿") == true)
    }
}
