import Combine
import XCTest
@testable import InsightKitApp

final class ImportSessionViewModelRecordFallbackTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testVisibleImportErrorStatusMessageIgnoresEmptyValues() {
        let viewModel = ImportSessionViewModel(rpcClient: RPCClientMock())

        XCTAssertNil(viewModel.visibleErrorStatusMessage)

        viewModel.errorMessage = "   "
        XCTAssertNil(viewModel.visibleErrorStatusMessage)

        viewModel.errorMessage = "转写失败：模型文件不存在"
        XCTAssertEqual(viewModel.visibleErrorStatusMessage, "转写失败：模型文件不存在")
    }

    func testVisibleImportStatusMessageIgnoresEmptyValues() {
        let viewModel = ImportSessionViewModel(rpcClient: RPCClientMock())

        XCTAssertNil(viewModel.visibleImportStatusMessage)

        viewModel.importStatusMessage = "   "
        XCTAssertNil(viewModel.visibleImportStatusMessage)

        viewModel.importStatusMessage = "正在生成逐字稿 · 45%"
        XCTAssertEqual(viewModel.visibleImportStatusMessage, "正在生成逐字稿 · 45%")
    }

    func testVisibleAnalysisStatusMessageIgnoresEmptyValues() {
        let viewModel = ImportSessionViewModel(rpcClient: RPCClientMock())

        XCTAssertNil(viewModel.visibleAnalysisStatusMessage)

        viewModel.analysisStatusMessage = "   "
        XCTAssertNil(viewModel.visibleAnalysisStatusMessage)

        viewModel.analysisStatusMessage = "智能分析未配置，转写继续。"
        XCTAssertEqual(viewModel.visibleAnalysisStatusMessage, "智能分析未配置，转写继续。")
    }

    func testMissingProviderConfigShowsImportFallbackStatus() {
        let viewModel = ImportSessionViewModel(rpcClient: RPCClientMock())
        let providers = AnalysisProvidersStatus(
            selectedVendor: .deepseek,
            activeReady: false,
            activeProbeOK: nil,
            activeProbeErrorCode: .missingKey,
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

        viewModel.applyAnalysisProvidersStatusForImport(providers)

        XCTAssertEqual(
            viewModel.visibleAnalysisStatusMessage,
            "智能分析未配置（DeepSeek：缺少 API Key），转写继续；定稿将使用本地提取草稿。"
        )
    }

    func testReadyProviderClearsImportFallbackStatus() {
        let viewModel = ImportSessionViewModel(rpcClient: RPCClientMock())
        viewModel.analysisStatusMessage = "智能分析未配置，转写继续。"
        let providers = AnalysisProvidersStatus(
            selectedVendor: .openai,
            activeReady: true,
            activeProbeOK: true,
            activeProbeErrorCode: .ok,
            activeProbeMessage: "连接成功。",
            vendors: [
                .init(
                    vendor: .openai,
                    baseURL: "https://api.openai.com/v1",
                    modelID: "gpt-4o-mini",
                    configured: true,
                    hasAPIKey: true,
                    modelReady: true
                ),
            ]
        )

        viewModel.applyAnalysisProvidersStatusForImport(providers)

        XCTAssertNil(viewModel.visibleAnalysisStatusMessage)
    }

    func testLocalAnalysisSkipsCloudProviderStatus() {
        let rpcClient = RPCClientMock()
        rpcClient.providersStatusError = NSError(domain: "unexpected-cloud-check", code: 1)
        let viewModel = ImportSessionViewModel(rpcClient: rpcClient)
        viewModel.analysisStatusMessage = "stale cloud warning"
        let cleared = expectation(description: "local mode clears stale cloud status")

        viewModel.$analysisStatusMessage
            .dropFirst()
            .sink { message in
                if message == nil {
                    cleared.fulfill()
                }
            }
            .store(in: &cancellables)

        _ = viewModel.refreshAnalysisStatusForImport(analysisMode: .local)
        wait(for: [cleared], timeout: 1)

        XCTAssertEqual(rpcClient.providersStatusCalls, 0)
        XCTAssertNil(viewModel.visibleAnalysisStatusMessage)
    }

    func testSuccessfulInsightRetryClearsPriorBlockingError() {
        let rpcClient = RPCClientMock()
        rpcClient.transcriptListStub = [
            TranscriptSegment(startMs: 0, endMs: 1_000, speaker: "A", source: "file", text: "Recovered"),
        ]
        let viewModel = ImportSessionViewModel(rpcClient: rpcClient)
        viewModel.errorMessage = "previous analysis failure"
        let cleared = expectation(description: "successful retry clears stale error")

        viewModel.$errorMessage
            .dropFirst()
            .sink { if $0 == nil { cleared.fulfill() } }
            .store(in: &cancellables)

        viewModel.loadCompletedArtifacts(meetingID: "recovered-import")
        wait(for: [cleared], timeout: 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCompletedImportShowsTranscriptBeforeSlowFinalInsight() {
        let rpcClient = RPCClientMock()
        rpcClient.transcriptListStub = [
            TranscriptSegment(
                startMs: 1_000,
                endMs: 3_000,
                speaker: "spk0",
                source: "file",
                text: "early transcript should not wait for final minutes"
            ),
        ]
        rpcClient.buildFinalDelaySec = 0.8
        let viewModel = ImportSessionViewModel(rpcClient: rpcClient)
        let transcriptLoaded = expectation(description: "transcript loads before slow final insight")

        viewModel.$transcriptEntries
            .dropFirst()
            .sink { entries in
                if entries.first?.text == "early transcript should not wait for final minutes" {
                    transcriptLoaded.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.loadCompletedArtifacts(meetingID: "file-import-fast-review")
        wait(for: [transcriptLoaded], timeout: 0.3)

        XCTAssertEqual(viewModel.transcriptEntries.first?.speaker, "spk0")
        XCTAssertEqual(rpcClient.buildFinalCalls, 1)
    }

    func testCancelImportCallsSidecarAndShowsVisibleStatus() {
        let rpcClient = RPCClientMock()
        let viewModel = ImportSessionViewModel(rpcClient: rpcClient)
        viewModel.sessionPhase = .processing
        viewModel.currentJobID = "job-import-cancel"
        viewModel.importProgress = 0.45
        viewModel.importStatusMessage = "正在生成逐字稿 · 45%"

        let exp = expectation(description: "cancel returns to selecting")
        viewModel.$sessionPhase
            .dropFirst()
            .sink { phase in
                if phase == .selecting,
                   rpcClient.cancelCalls.contains(where: { $0.jobID == "job-import-cancel" && $0.reason == "cancelled_by_user" }) {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.cancelImport()
        wait(for: [exp], timeout: 1)

        XCTAssertNil(viewModel.currentJobID)
        XCTAssertEqual(viewModel.visibleImportStatusMessage, "导入已取消。你可以重新选择文件。")
        XCTAssertNil(viewModel.visibleErrorStatusMessage)
        XCTAssertEqual(viewModel.importProgress, 0)
    }

    func testCancelImportFailureRemainsVisible() {
        let rpcClient = RPCClientMock()
        rpcClient.transcriptionCancelError = NSError(
            domain: "InsightKitTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "sidecar unavailable"]
        )
        let viewModel = ImportSessionViewModel(rpcClient: rpcClient)
        viewModel.sessionPhase = .processing
        viewModel.currentJobID = "job-import-cancel-fails"
        viewModel.importStatusMessage = "正在生成逐字稿 · 45%"

        let exp = expectation(description: "cancel failure visible")
        viewModel.$errorMessage
            .dropFirst()
            .sink { message in
                if message?.contains("取消导入失败") == true {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.cancelImport()
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(rpcClient.cancelCalls.count, 0)
        XCTAssertEqual(viewModel.sessionPhase, .processing)
        XCTAssertEqual(viewModel.visibleImportStatusMessage, "取消失败，转写任务可能仍在运行。")
        XCTAssertTrue(viewModel.visibleErrorStatusMessage?.contains("sidecar unavailable") == true)
    }

    func testLoadsPersistedArtifactsForCompletedImport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitImportFallback-\(UUID().uuidString)", isDirectory: true)
        let recordID = "file-import-fallback"
        let recordPath = root.appendingPathComponent(recordID, isDirectory: true)
        try FileManager.default.createDirectory(at: recordPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = RecordMetadata(
            id: recordID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: ["register"],
            summaryPreview: "用户注册流程讨论"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: recordPath.appendingPathComponent("metadata.json"))
        try Data([0x00]).write(to: recordPath.appendingPathComponent("recording.m4a"))

        let transcriptRows: [[String: Any]] = [
            ["start_ms": 1_000, "end_ms": 3_000, "speaker": "spk0", "text": "need an account"],
            ["start_ms": 12_000, "end_ms": 16_000, "speaker": "spk1", "text": "add an information section"],
        ]
        let transcriptData = try JSONSerialization.data(withJSONObject: transcriptRows, options: [.prettyPrinted])
        try transcriptData.write(to: recordPath.appendingPathComponent("transcript.json"))
        try "00:05 follow up with product".write(to: recordPath.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let package = InsightPackageV1(
            sessionOverview: .init(title: "注册流程", overview: "讨论无账户用户的注册提示。", topics: ["注册"]),
            highlightInsights: [
                .init(
                    quote: "add an information section",
                    reason: "明确提出解决方案",
                    speaker: "spk1",
                    evidenceSpan: .init(startMs: 12_000, endMs: 16_000)
                ),
            ],
            speakerPerspectives: [
                .init(
                    speaker: "spk1",
                    viewpoints: ["建议添加信息提示"],
                    evidenceSpans: [.init(startMs: 12_000, endMs: 16_000)]
                ),
            ],
            decisionLedger: [
                .init(
                    problem: "如何提示无账户用户",
                    options: ["直接报错", "增加提示"],
                    decision: "增加注册提示",
                    rationale: "减少困惑",
                    owner: "spk1",
                    needsReview: false,
                    evidenceSpan: .init(startMs: 12_000, endMs: 16_000)
                ),
            ],
            actionTracks: [
                .init(
                    task: "添加注册提示",
                    owner: "spk1",
                    dueAt: "",
                    priority: "medium",
                    status: "open",
                    needsReview: false,
                    evidenceSpan: .init(startMs: 12_000, endMs: 16_000)
                ),
            ],
            timelineBeats: [
                .init(timestamp: "00:12", title: "提出方案", summary: "添加信息提示。"),
            ],
            provenanceLinks: []
        )
        try encoder.encode(package).write(to: recordPath.appendingPathComponent("insight_package.json"))

        let recordsService = RecordsIndexService()
        recordsService.rootDirectory = root
        let viewModel = ImportSessionViewModel(rpcClient: RPCClientMock())
        viewModel.recordsService = recordsService

        XCTAssertTrue(viewModel.loadPersistedArtifactsForCompletedImport(meetingID: recordID))
        XCTAssertEqual(viewModel.recordingDuration, 30)
        XCTAssertEqual(viewModel.mediaURL?.lastPathComponent, "recording.m4a")
        XCTAssertEqual(viewModel.transcriptEntries.map(\.text), ["need an account", "add an information section"])
        XCTAssertEqual(viewModel.notes.first?.timestamp, 5)
        XCTAssertEqual(viewModel.smartMinutesData?.structuredSummary, "讨论无账户用户的注册提示。")
        XCTAssertEqual(viewModel.smartMinutesData?.speakerSummaries.first?.speakerName, "spk1")
        XCTAssertEqual(viewModel.smartMinutesData?.keyDecisions, ["增加注册提示"])
        XCTAssertEqual(viewModel.chapters.first?.timestamp, 12)
    }

    func testCompletedImportExportPrefersPersistedNativePDFOverRPC() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitImportExport-\(UUID().uuidString)", isDirectory: true)
        let recordID = "file-import-native-export"
        let recordPath = root.appendingPathComponent(recordID, isDirectory: true)
        try FileManager.default.createDirectory(at: recordPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = RecordMetadata(
            id: recordID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: ["export"],
            summaryPreview: "本地 PDF 导出"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: recordPath.appendingPathComponent("metadata.json"))
        try Data([0x00]).write(to: recordPath.appendingPathComponent("recording.m4a"))
        try """
        [
          {"start_ms":1000,"end_ms":3000,"speaker":"spk0","text":"export locally"}
        ]
        """.write(to: recordPath.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try """
        {
          "structured_summary": "本地导出不依赖 sidecar PDF runtime。",
          "highlights": ["native export"],
          "key_decisions": ["prefer native"],
          "action_items": ["keep export readable"],
          "timeline_beats": [
            {"timestamp":"00:01","title":"Export","summary":"Use native PDF renderer."}
          ]
        }
        """.write(to: recordPath.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)

        let recordsService = RecordsIndexService()
        recordsService.rootDirectory = root
        let rpcClient = RPCClientMock()
        let viewModel = ImportSessionViewModel(rpcClient: rpcClient)
        viewModel.recordsService = recordsService

        XCTAssertTrue(viewModel.loadPersistedArtifactsForCompletedImport(meetingID: recordID))
        viewModel.exportDocument(format: "pdf")

        XCTAssertTrue(rpcClient.documentExportCalls.isEmpty)
        let exportURL = try XCTUnwrap(viewModel.lastExportURL)
        XCTAssertEqual(exportURL.pathExtension, "pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        let data = try Data(contentsOf: exportURL)
        XCTAssertEqual(String(data: data.prefix(5), encoding: .utf8), "%PDF-")
    }

    func testCompletedImportExportPersistsInMemoryNotesBeforeNativeExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitImportNotesExport-\(UUID().uuidString)", isDirectory: true)
        let recordID = "file-import-note-export"
        let recordPath = root.appendingPathComponent(recordID, isDirectory: true)
        try FileManager.default.createDirectory(at: recordPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = RecordMetadata(
            id: recordID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: ["notes"],
            summaryPreview: "导入笔记写回"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: recordPath.appendingPathComponent("metadata.json"))
        try Data([0x00]).write(to: recordPath.appendingPathComponent("recording.m4a"))
        try """
        [
          {"start_ms":0,"end_ms":3000,"speaker":"spk0","text":"note should persist"}
        ]
        """.write(to: recordPath.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try """
        {
          "structured_summary": "导入后笔记需要写入记录资产。",
          "highlights": ["note should persist"],
          "key_decisions": [],
          "action_items": ["persist note before export"],
          "timeline_beats": [
            {"timestamp":"00:00","title":"Note","summary":"Persist import note."}
          ]
        }
        """.write(to: recordPath.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)
        try "".write(to: recordPath.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let recordsService = RecordsIndexService()
        recordsService.rootDirectory = root
        let rpcClient = RPCClientMock()
        let viewModel = ImportSessionViewModel(rpcClient: rpcClient)
        viewModel.recordsService = recordsService
        viewModel.notes = [TimestampedNote(text: "Fresh import 连续验收笔记", timestamp: 7)]

        XCTAssertTrue(viewModel.loadPersistedArtifactsForCompletedImport(meetingID: recordID))
        viewModel.exportDocument(format: "markdown")

        XCTAssertTrue(rpcClient.documentExportCalls.isEmpty)
        let notesContent = try String(contentsOf: recordPath.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertTrue(notesContent.contains("00:07 Fresh import 连续验收笔记"))
        let exportURL = try XCTUnwrap(viewModel.lastExportURL)
        let markdown = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## 时间绑定笔记"))
        XCTAssertTrue(markdown.contains("[00:07] Fresh import 连续验收笔记"))
    }

    func testCompletedImportShowsNativeExportFailureStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitImportExportFailure-\(UUID().uuidString)", isDirectory: true)
        let recordID = "file-import-export-failure"
        let recordPath = root.appendingPathComponent(recordID, isDirectory: true)
        try FileManager.default.createDirectory(at: recordPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try seedMinimalImportRecord(recordID: recordID, recordPath: recordPath)

        let recordsService = RecordsIndexService()
        recordsService.rootDirectory = root
        let rpcClient = RPCClientMock()
        let viewModel = ImportSessionViewModel(rpcClient: rpcClient)
        viewModel.recordsService = recordsService

        XCTAssertTrue(viewModel.loadPersistedArtifactsForCompletedImport(meetingID: recordID))
        viewModel.exportDocument(format: "docx")

        XCTAssertTrue(rpcClient.documentExportCalls.isEmpty)
        XCTAssertNil(viewModel.lastExportURL)
        XCTAssertEqual(
            viewModel.exportStatusMessage,
            "导出失败：不支持的导出格式：docx"
        )
    }

    private func seedMinimalImportRecord(recordID: String, recordPath: URL) throws {
        let metadata = RecordMetadata(
            id: recordID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: ["export"],
            summaryPreview: "导出失败状态"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: recordPath.appendingPathComponent("metadata.json"))
        try Data([0x00]).write(to: recordPath.appendingPathComponent("recording.m4a"))
        try """
        [
          {"start_ms":1000,"end_ms":3000,"speaker":"spk0","text":"export failure should be visible"}
        ]
        """.write(to: recordPath.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try """
        {
          "structured_summary": "导出失败必须可见。",
          "highlights": ["visible export error"],
          "key_decisions": [],
          "action_items": [],
          "timeline_beats": [
            {"timestamp":"00:01","title":"Export failure","summary":"Unsupported formats are reported."}
          ]
        }
        """.write(to: recordPath.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)
        try "".write(to: recordPath.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }
}
