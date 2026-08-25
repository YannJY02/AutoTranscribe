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

    func testRecordsRootEnvironmentOverrideWinsForAppAndSidecarAlignment() throws {
        let suiteName = "RecordsIndexServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(tempRoot.appendingPathComponent("Ignored").path, forKey: RecordsIndexService.rootDirectoryDefaultsKey)
        let configuredRoot = tempRoot.appendingPathComponent("EnvironmentRecords", isDirectory: true)
        let environment = ["INSIGHTKIT_RECORDS_ROOT": configuredRoot.path]

        let service = RecordsIndexService(defaults: defaults, environment: environment)

        XCTAssertEqual(service.rootDirectory.standardizedFileURL, configuredRoot.standardizedFileURL)
        XCTAssertEqual(
            RecordsIndexService.currentRootDirectory(defaults: defaults, environment: environment).standardizedFileURL,
            configuredRoot.standardizedFileURL
        )
    }

    func testRecordsRootEnvironmentOverrideRejectsUnsafePaths() throws {
        let suiteName = "RecordsIndexServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fallbackRoot = tempRoot.appendingPathComponent("Fallback", isDirectory: true)
        defaults.set(fallbackRoot.path, forKey: RecordsIndexService.rootDirectoryDefaultsKey)

        for configuredPath in ["relative/path", "/"] {
            XCTAssertEqual(
                RecordsIndexService.currentRootDirectory(
                    defaults: defaults,
                    environment: ["INSIGHTKIT_RECORDS_ROOT": configuredPath]
                ).standardizedFileURL,
                fallbackRoot.standardizedFileURL
            )
        }
    }

    func testPrepareUITestSeedCreatesRequestedRecord() throws {
        let service = RecordsIndexService(environment: [
            "INSIGHTKIT_RECORDS_ROOT": tempRoot.path,
            "INSIGHTKIT_UI_TEST_MODE": "1",
            "INSIGHTKIT_UI_TEST_SEED_RECORD_ID": "record-restart-proof",
        ])

        service.prepareUITestSeedIfRequested()

        XCTAssertEqual(service.records.map(\.id), ["record-restart-proof"])
        XCTAssertEqual(service.records.first?.summaryPreview, "restart persistence evidence")
    }

    func testPrepareUITestSeedRejectsUnsafeRecordID() throws {
        let service = RecordsIndexService(environment: [
            "INSIGHTKIT_RECORDS_ROOT": tempRoot.path,
            "INSIGHTKIT_UI_TEST_MODE": "1",
            "INSIGHTKIT_UI_TEST_SEED_RECORD_ID": "../escape",
        ])

        service.prepareUITestSeedIfRequested()

        XCTAssertTrue(service.records.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.deletingLastPathComponent().appendingPathComponent("escape").path
            )
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
        try """
        {
          "session_overview":{"title":"Canonical","overview":"The canonical package search token is indexed.","topics":["search"]},
          "highlight_insights":[],
          "speaker_perspectives":[],
          "decision_ledger":[],
          "action_tracks":[],
          "timeline_beats":[],
          "provenance_links":[]
        }
        """.write(to: recordDir.appendingPathComponent("insight_package.json"), atomically: true, encoding: .utf8)
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
        XCTAssertEqual(service.searchRecords(query: "canonical package search token").map(\.id), ["record-1"])
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

    func testRefreshIndexReadsOptionalPresentationStatusAndKeepsLegacyRecordsCompatible() throws {
        let fallbackDir = tempRoot.appendingPathComponent("fallback-record")
        let legacyDir = tempRoot.appendingPathComponent("legacy-record")
        try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try """
        {
          "id": "fallback-record",
          "createdAt": "2026-05-22T00:00:00Z",
          "duration": 7.6,
          "mediaType": "video",
          "source": "live",
          "userTags": [],
          "autoTags": [],
          "summaryPreview": "fallback summary",
          "presentationStatus": "screenOnlyFallback"
        }
        """.write(to: fallbackDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
        try """
        {
          "id": "legacy-record",
          "createdAt": "2026-05-23T00:00:00Z",
          "duration": 7.6,
          "mediaType": "video",
          "source": "live",
          "userTags": [],
          "autoTags": [],
          "summaryPreview": "legacy summary"
        }
        """.write(to: legacyDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        let service = RecordsIndexService()
        service.rootDirectory = tempRoot
        service.refreshIndex()

        XCTAssertEqual(service.records.first(where: { $0.id == "fallback-record" })?.presentationStatus, .screenOnlyFallback)
        XCTAssertNil(service.records.first(where: { $0.id == "legacy-record" })?.presentationStatus)
    }

    func testRecordReviewShowsPresentationFallbackOnlyWhenCameraWasNotSaved() throws {
        let fallback = RecordMetadata(
            id: "fallback-record",
            createdAt: Date(),
            duration: 10,
            mediaType: .video,
            source: .live,
            userTags: [],
            autoTags: [],
            summaryPreview: nil,
            presentationStatus: .screenOnlyFallback
        )
        let captured = RecordMetadata(
            id: "captured-record",
            createdAt: Date(),
            duration: 10,
            mediaType: .video,
            source: .live,
            userTags: [],
            autoTags: [],
            summaryPreview: nil,
            presentationStatus: .presenterOverlayCaptured
        )
        let cameraOverlayCaptured = RecordMetadata(
            id: "camera-overlay-captured-record",
            createdAt: Date(),
            duration: 10,
            mediaType: .video,
            source: .live,
            userTags: [],
            autoTags: [],
            summaryPreview: nil,
            presentationStatus: .screenPlusCameraCaptured
        )
        let unavailable = RecordMetadata(
            id: "visual-unavailable-record",
            createdAt: Date(),
            duration: 10,
            mediaType: .audio,
            source: .live,
            userTags: [],
            autoTags: [],
            summaryPreview: nil,
            presentationStatus: .visualMediaUnavailable
        )
        let legacy = RecordMetadata(
            id: "legacy-record",
            createdAt: Date(),
            duration: 10,
            mediaType: .video,
            source: .live,
            userTags: [],
            autoTags: [],
            summaryPreview: nil
        )

        let fallbackDataSource = RecordReviewDataSource(metadata: fallback, rootDirectory: tempRoot)
        let capturedDataSource = RecordReviewDataSource(metadata: captured, rootDirectory: tempRoot)
        let cameraOverlayCapturedDataSource = RecordReviewDataSource(metadata: cameraOverlayCaptured, rootDirectory: tempRoot)
        let unavailableDataSource = RecordReviewDataSource(metadata: unavailable, rootDirectory: tempRoot)
        let legacyDataSource = RecordReviewDataSource(metadata: legacy, rootDirectory: tempRoot)

        XCTAssertTrue(fallbackDataSource.presentationStatusMessage?.contains("摄像头没有写入 Record") == true)
        XCTAssertNil(capturedDataSource.presentationStatusMessage)
        XCTAssertNil(cameraOverlayCapturedDataSource.presentationStatusMessage)
        XCTAssertTrue(unavailableDataSource.presentationStatusMessage?.contains("没有保存到视频画面") == true)
        XCTAssertNil(legacyDataSource.presentationStatusMessage)
    }

    func testRecordDisplayTitlePrefersManualTitleThenSummaryThenReadableFallback() throws {
        let createdAt = ISO8601DateFormatter().date(from: "2026-05-22T10:30:00Z")!
        let manuallyRenamed = RecordMetadata(
            id: "live-technical-id",
            createdAt: createdAt,
            duration: 30,
            mediaType: .audio,
            source: .live,
            title: "Client planning review",
            userTags: [],
            autoTags: [],
            summaryPreview: "Summary preview"
        )
        let summarized = RecordMetadata(
            id: "import-technical-id",
            createdAt: createdAt,
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: [],
            summaryPreview: "Quarterly roadmap"
        )
        let fallback = RecordMetadata(
            id: "opaque-id",
            createdAt: createdAt,
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: [],
            summaryPreview: nil
        )

        XCTAssertEqual(manuallyRenamed.displayTitle, "Client planning review")
        XCTAssertEqual(summarized.displayTitle, "Quarterly roadmap")
        XCTAssertTrue(fallback.displayTitle.contains("导入记录"))
        XCTAssertNotEqual(fallback.displayTitle, "opaque-id")
    }

    func testGeneratedRecordDisplayTitleUsesShortStandardizedTitle() throws {
        let createdAt = ISO8601DateFormatter().date(from: "2026-05-22T10:30:00Z")!
        let record = RecordMetadata(
            id: "import-technical-id",
            createdAt: createdAt,
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: [],
            summaryPreview: "  - Quarterly roadmap update covers launch risk, hiring plan, pricing experiments, and next steps."
        )

        XCTAssertTrue(record.displayTitle.hasPrefix("Quarterly roadmap update covers"))
        XCTAssertTrue(record.displayTitle.hasSuffix("..."))
        XCTAssertLessThanOrEqual(record.displayTitle.count, 44)
        XCTAssertFalse(record.displayTitle.contains("pricing experiments"))
    }

    func testRecordFolderResolverFindsReadableFolderByMetadataID() throws {
        let readableFolder = "20260627-1015-import-quarterly-roadmap-abcdef12"
        let recordDir = tempRoot.appendingPathComponent(readableFolder)
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        try """
        {
          "id": "file-11112222-3333-4444-5555-abcdef123456",
          "createdAt": "2026-06-27T10:15:00Z",
          "duration": 30,
          "mediaType": "audio",
          "source": "imported",
          "userTags": [],
          "autoTags": [],
          "summaryPreview": "Quarterly roadmap"
        }
        """.write(to: recordDir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        let service = RecordsIndexService()
        service.rootDirectory = tempRoot

        XCTAssertEqual(
            service.recordFolderURL(for: "file-11112222-3333-4444-5555-abcdef123456")?.lastPathComponent,
            readableFolder
        )
    }

    func testRenameRecordPersistsManualTitleAndSearchUsesIt() throws {
        try seedRecord(
            id: "record-to-rename",
            createdAt: "2026-05-22T00:00:00Z",
            mediaType: "audio",
            userTags: [],
            autoTags: []
        )
        let service = RecordsIndexService()
        service.rootDirectory = tempRoot
        service.refreshIndex()

        service.renameRecord(id: "record-to-rename", to: "Customer demo review")

        XCTAssertEqual(service.records.first?.title, "Customer demo review")
        XCTAssertEqual(service.records.first?.displayTitle, "Customer demo review")
        XCTAssertEqual(service.searchRecords(query: "customer demo").map(\.id), ["record-to-rename"])

        let metadataURL = tempRoot
            .appendingPathComponent("record-to-rename")
            .appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(RecordMetadata.self, from: data)
        XCTAssertEqual(persisted.title, "Customer demo review")
    }

    func testRecordReviewRenamesSpeakerAndExportUsesCorrectedLabel() throws {
        let recordDir = tempRoot.appendingPathComponent("speaker-record")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        try """
        [
          {"start_ms":0,"end_ms":1000,"speaker":"SPEAKER_00","text":"We should rename speakers."},
          {"start_ms":2000,"end_ms":3000,"speaker":"SPEAKER_00","text":"The export should follow."}
        ]
        """.write(to: recordDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try """
        {"structured_summary":"summary","highlights":[],"key_decisions":[],"action_items":[]}
        """.write(to: recordDir.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)

        let metadata = RecordMetadata(
            id: "speaker-record",
            createdAt: Date(),
            duration: 10,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: [],
            summaryPreview: "Speaker edit fixture"
        )
        let dataSource = RecordReviewDataSource(metadata: metadata, rootDirectory: tempRoot)

        dataSource.renameSpeaker(from: "SPEAKER_00", to: "Alice")

        XCTAssertEqual(dataSource.transcriptEntries.map(\.speaker), ["Alice", "Alice"])
        XCTAssertEqual(dataSource.smartMinutesData?.speakerSummaries.map(\.speakerName), ["Alice"])

        let transcriptJSON = try String(contentsOf: recordDir.appendingPathComponent("transcript.json"), encoding: .utf8)
        XCTAssertTrue(transcriptJSON.contains("Alice"))
        XCTAssertFalse(transcriptJSON.contains("SPEAKER_00"))

        let markdown = try RecordDocumentExporter.renderMarkdown(metadata: metadata, recordPath: recordDir)
        XCTAssertTrue(markdown.contains("Alice"))
        XCTAssertFalse(markdown.contains("SPEAKER_00"))
    }

    func testSpeakerRenamePresentationBuildsVisibleActionsForKnownSpeakers() throws {
        let presentation = RecordSpeakerRenamePresentation.make(
            editableSpeakers: ["SPEAKER_00"],
            stripAccessibilityID: "live_summary_speaker_rename_strip",
            buttonAccessibilityID: "live_summary_speaker_rename_button"
        )

        XCTAssertTrue(presentation.showsSpeakerStrip)
        XCTAssertEqual(presentation.speakerStripAccessibilityID, "live_summary_speaker_rename_strip")
        XCTAssertEqual(presentation.speakerActions.map(\.accessibilityID), ["live_summary_speaker_rename_button"])
    }

    func testTranscriptRowWithSpeakerShowsVisibleRenameAction() {
        let entry = TranscriptEntry(timestamp: 4, speaker: "SPEAKER_00", text: "audio-only review")

        let presentation = RecordSpeakerRenamePresentation.rowAction(for: entry)

        XCTAssertEqual(presentation?.speakerLabel, "SPEAKER_00")
        XCTAssertEqual(presentation?.accessibilityID, "record_transcript_speaker_rename")
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

    func testRecordReviewPrefersInsightPackageAsCanonicalSmartMinutesSource() throws {
        let recordDir = tempRoot.appendingPathComponent("canonical-record")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        try """
        [
          {"start_ms":0,"end_ms":1000,"speaker":"SPEAKER_00","text":"The package should be canonical."}
        ]
        """.write(to: recordDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        try """
        {
          "structured_summary":"Flattened fallback summary",
          "highlights":[],
          "key_decisions":[],
          "action_items":[],
          "timeline_beats":[{"timestamp":"00:01","title":"Fallback","summary":"Fallback chapter"}]
        }
        """.write(to: recordDir.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)
        try """
        {
          "session_overview":{"title":"Canonical","overview":"Canonical package overview","topics":["source"]},
          "highlight_insights":[{"quote":"Canonical quote","reason":"It came from the package","speaker":"Alice","evidence_span":{"start_ms":0,"end_ms":1000}}],
          "speaker_perspectives":[{"speaker":"Alice","viewpoints":["Package viewpoint"],"evidence_spans":[{"start_ms":0,"end_ms":1000}]}],
          "decision_ledger":[{"problem":"Which source","options":["minutes","package"],"decision":"Use the package","rationale":"It is complete","owner":"Alice","needs_review":false,"evidence_span":{"start_ms":0,"end_ms":1000}}],
          "action_tracks":[{"task":"Verify shared asset","owner":"Alice","due_at":"","priority":"medium","status":"open","needs_review":false,"evidence_span":{"start_ms":0,"end_ms":1000}}],
          "timeline_beats":[{"timestamp":"00:01","title":"Package chapter","summary":"Package chapter summary"}],
          "provenance_links":[]
        }
        """.write(to: recordDir.appendingPathComponent("insight_package.json"), atomically: true, encoding: .utf8)

        let metadata = RecordMetadata(
            id: "canonical-record",
            createdAt: Date(),
            duration: 10,
            mediaType: .audio,
            source: .live,
            userTags: [],
            autoTags: [],
            summaryPreview: nil
        )

        let dataSource = RecordReviewDataSource(metadata: metadata, rootDirectory: tempRoot)

        XCTAssertEqual(dataSource.smartMinutesData?.structuredSummary, "Canonical package overview")
        XCTAssertEqual(dataSource.smartMinutesData?.highlights, ["Canonical quote"])
        XCTAssertEqual(dataSource.smartMinutesData?.speakerSummaries.map(\.speakerName), ["Alice"])
        XCTAssertEqual(dataSource.smartMinutesData?.speakerSummaries.first?.summary, "Package viewpoint")
        XCTAssertEqual(dataSource.smartMinutesData?.keyDecisions, ["Use the package"])
        XCTAssertEqual(dataSource.smartMinutesData?.actionItems, ["Verify shared asset"])
        XCTAssertEqual(dataSource.chapters.map(\.title), ["Package chapter"])
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
