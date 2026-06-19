import Combine
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
