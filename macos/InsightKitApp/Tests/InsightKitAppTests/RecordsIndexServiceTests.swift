import Darwin
import XCTest
@testable import InsightKitApp

final class RecordsIndexServiceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitRecordsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        UserDefaults.standard.removeObject(forKey: RecordsIndexService.rootDirectoryDefaultsKey)
        try super.tearDownWithError()
    }

    func testDefaultRecordsRootUsesDocumentsOutsideSandbox() throws {
        let root = RecordsIndexService.defaultRootDirectory(environment: [:])

        XCTAssertTrue(root.path.hasSuffix("/Documents/InsightKit/Records"))
    }

    func testDefaultRecordsRootUsesApplicationSupportWhenSandboxed() throws {
        let root = RecordsIndexService.defaultRootDirectory(
            environment: ["APP_SANDBOX_CONTAINER_ID": "com.yannjy.insightkit"]
        )

        XCTAssertTrue(root.path.hasSuffix("/Library/Application Support/InsightKit/Records"))
    }

    func testCurrentRootDirectoryUsesPersistedCustomRootForSidecarAlignment() throws {
        let suiteName = "RecordsIndexServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customRoot = tempRoot.appendingPathComponent("CustomRecords", isDirectory: true)

        let service = RecordsIndexService(defaults: defaults, environment: [:])
        service.rootDirectory = customRoot

        XCTAssertEqual(service.rootDirectory.standardizedFileURL, customRoot.standardizedFileURL)
        XCTAssertEqual(
            RecordsIndexService.currentRootDirectory(defaults: defaults, environment: [:]).standardizedFileURL,
            customRoot.standardizedFileURL
        )
    }

    func testSearchRecordsIncludesTranscriptMinutesAndNotesContent() throws {
        let recordDir = tempRoot.appendingPathComponent("record-1")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        try """
        {
          "id": "record-1",
          "createdAt": "2026-05-22T00:00:00Z",
          "duration": 7.6,
          "mediaType": "audio",
          "source": "imported",
          "userTags": [],
          "autoTags": ["milestone"],
          "summaryPreview": "local summary"
        }
        """.write(to: recordDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        try """
        [{"start_ms":0,"end_ms":1900,"speaker":"A","text":"The product milestone is confirmed."}]
        """.write(to: recordDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try """
        {"structured_summary":"The local record ships first.","highlights":[],"key_decisions":[],"action_items":[]}
        """.write(to: recordDir.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)
        try "00:03 export verification note".write(
            to: recordDir.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = RecordsIndexService()
        service.rootDirectory = tempRoot
        service.refreshIndex()

        XCTAssertEqual(service.searchRecords(query: "product milestone").map(\.id), ["record-1"])
        XCTAssertEqual(service.searchRecords(query: "local record ships").map(\.id), ["record-1"])
        XCTAssertEqual(service.searchRecords(query: "export verification").map(\.id), ["record-1"])
    }

    func testSearchRecordsUsesRefreshTimeContentIndex() throws {
        let recordDir = tempRoot.appendingPathComponent("record-indexed")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        try """
        {
          "id": "record-indexed",
          "createdAt": "2026-05-22T00:00:00Z",
          "duration": 7.6,
          "mediaType": "audio",
          "source": "imported",
          "userTags": [],
          "autoTags": [],
          "summaryPreview": "indexed summary"
        }
        """.write(to: recordDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        let notesURL = recordDir.appendingPathComponent("notes.md")
        try "00:03 cached-search-token".write(to: notesURL, atomically: true, encoding: .utf8)

        let service = RecordsIndexService()
        service.rootDirectory = tempRoot
        service.refreshIndex()
        try FileManager.default.removeItem(at: notesURL)

        XCTAssertEqual(service.searchRecords(query: "cached-search-token").map(\.id), ["record-indexed"])
    }

    func testRefreshIndexSkipsNonRegularRecordFilesWithoutBlocking() throws {
        try seedRecord(
            id: "healthy-record",
            createdAt: "2026-05-22T00:00:00Z",
            mediaType: "audio",
            userTags: [],
            autoTags: []
        )
        let healthyDir = tempRoot.appendingPathComponent("healthy-record")
        try """
        [{"start_ms":0,"end_ms":1900,"speaker":"A","text":"transcript-token"}]
        """.write(to: healthyDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try makeFIFO(at: healthyDir.appendingPathComponent("notes.md"))

        let blockedDir = tempRoot.appendingPathComponent("blocked-record")
        try FileManager.default.createDirectory(at: blockedDir, withIntermediateDirectories: true)
        try makeFIFO(at: blockedDir.appendingPathComponent("metadata.json"))

        let service = RecordsIndexService()
        service.rootDirectory = tempRoot
        service.refreshIndex()

        XCTAssertEqual(service.records.map(\.id), ["healthy-record"])
        XCTAssertEqual(service.searchRecords(query: "transcript-token").map(\.id), ["healthy-record"])
    }

    func testFilterRecordsCombinesTagsTypeAndTimeRange() throws {
        try seedRecord(
            id: "week-audio",
            createdAt: "2026-05-25T03:00:00Z",
            mediaType: "audio",
            userTags: ["review"],
            autoTags: ["注册流程"]
        )
        try seedRecord(
            id: "month-video",
            createdAt: "2026-05-05T03:00:00Z",
            mediaType: "video",
            userTags: ["demo"],
            autoTags: ["注册流程"]
        )
        try seedRecord(
            id: "older-audio",
            createdAt: "2026-04-30T03:00:00Z",
            mediaType: "audio",
            userTags: ["archive"],
            autoTags: ["旧记录"]
        )

        let service = RecordsIndexService()
        service.rootDirectory = tempRoot
        service.refreshIndex()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-05-25T12:00:00Z")!

        XCTAssertEqual(
            service.filterRecords(criteria: RecordFilterCriteria(timeFilter: .thisWeek, now: now, calendar: calendar))
                .map(\.id),
            ["week-audio"]
        )
        XCTAssertEqual(
            service.filterRecords(criteria: RecordFilterCriteria(timeFilter: .thisMonth, now: now, calendar: calendar))
                .map(\.id),
            ["week-audio", "month-video"]
        )
        XCTAssertEqual(
            service.filterRecords(criteria: RecordFilterCriteria(timeFilter: .older, now: now, calendar: calendar))
                .map(\.id),
            ["older-audio"]
        )
        XCTAssertEqual(
            service.filterRecords(criteria: RecordFilterCriteria(tags: ["注册流程"], type: .video, timeFilter: .thisMonth, now: now, calendar: calendar))
                .map(\.id),
            ["month-video"]
        )
    }

    func testRecordReviewLoadsTimelineBeatsAsChapters() throws {
        let recordDir = tempRoot.appendingPathComponent("record-2")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        try """
        [
          {"start_ms":0,"end_ms":1000,"speaker":"spk0","text":"We should ship local first."},
          {"start_ms":5000,"end_ms":7000,"speaker":"spk1","text":"I will verify the release export."}
        ]
        """.write(to: recordDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try """
        {"structured_summary":"summary","highlights":["ship local first"],"key_decisions":["use native export"],"action_items":["verify release export"],"timeline_beats":[{"timestamp":"00:05","title":"Decision","summary":"Ship local first."}]}
        """.write(to: recordDir.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)

        let metadata = RecordMetadata(
            id: "record-2",
            createdAt: Date(),
            duration: 10,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: [],
            summaryPreview: nil
        )

        let dataSource = RecordReviewDataSource(metadata: metadata, rootDirectory: tempRoot)

        XCTAssertEqual(dataSource.chapters.count, 1)
        XCTAssertEqual(dataSource.chapters.first?.timestamp, 5)
        XCTAssertEqual(dataSource.smartMinutesData?.chapters.first?.title, "Decision")
        XCTAssertEqual(dataSource.smartMinutesData?.highlights, ["ship local first"])
        XCTAssertEqual(dataSource.smartMinutesData?.keyDecisions, ["use native export"])
        XCTAssertEqual(dataSource.smartMinutesData?.actionItems, ["verify release export"])
        XCTAssertEqual(dataSource.smartMinutesData?.speakerSummaries.map(\.speakerName), ["spk0", "spk1"])
        XCTAssertTrue(dataSource.smartMinutesData?.speakerSummaries.first?.summary.contains("1 条发言") == true)
    }

    func testRecordReviewShowsVisibleMissingMediaStatus() throws {
        let recordDir = tempRoot.appendingPathComponent("record-3")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        try """
        [{"start_ms":0,"end_ms":1200,"speaker":"A","text":"Media is unavailable."}]
        """.write(to: recordDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)

        let metadata = RecordMetadata(
            id: "record-3",
            createdAt: Date(),
            duration: 12,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: [],
            summaryPreview: nil
        )

        let dataSource = RecordReviewDataSource(metadata: metadata, rootDirectory: tempRoot)

        XCTAssertNil(dataSource.mediaURL)
        XCTAssertTrue(dataSource.mediaStatusMessage?.contains("媒体文件缺失") == true)
        XCTAssertEqual(dataSource.transcriptEntries.count, 1)
    }

    private func seedRecord(
        id: String,
        createdAt: String,
        mediaType: String,
        userTags: [String],
        autoTags: [String]
    ) throws {
        let recordDir = tempRoot.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        let userTagsJSON = try String(data: JSONSerialization.data(withJSONObject: userTags), encoding: .utf8)!
        let autoTagsJSON = try String(data: JSONSerialization.data(withJSONObject: autoTags), encoding: .utf8)!
        try """
        {
          "id": "\(id)",
          "createdAt": "\(createdAt)",
          "duration": 30,
          "mediaType": "\(mediaType)",
          "source": "imported",
          "userTags": \(userTagsJSON),
          "autoTags": \(autoTagsJSON),
          "summaryPreview": "\(id)"
        }
        """.write(to: recordDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    }

    private func makeFIFO(at url: URL) throws {
        let result = Darwin.mkfifo(url.path, mode_t(0o600))
        if result != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
            )
        }
    }
}
