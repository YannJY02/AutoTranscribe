import XCTest
@testable import InsightKitApp

final class MeetingAssetSnapshotTests: XCTestCase {
    private var recordDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        recordDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightKitMeetingAssetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let recordDir {
            try? FileManager.default.removeItem(at: recordDir)
        }
        try super.tearDownWithError()
    }

    func testLoadsCompleteRecordWithAvailableHealth() throws {
        try seedMetadata()
        try seedMedia()
        try seedTranscript(speaker: "SPEAKER_00", text: "Canonical assets are aligned.")
        try seedInsightPackage(overview: "Official package overview")
        try "00:04 canonical note".write(to: recordDir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let snapshot = MeetingAssetSnapshot.load(recordPath: recordDir, duration: 30)

        XCTAssertEqual(snapshot.health.metadata.state, .available)
        XCTAssertEqual(snapshot.health.media.state, .available)
        XCTAssertEqual(snapshot.health.transcript.state, .available)
        XCTAssertEqual(snapshot.health.smartMinutes.state, .available)
        XCTAssertEqual(snapshot.health.notes.state, .available)
        XCTAssertFalse(snapshot.health.usesFallback)
        XCTAssertNil(snapshot.mediaStatusMessage)
        XCTAssertEqual(snapshot.transcriptEntries.map(\.text), ["Canonical assets are aligned."])
        XCTAssertEqual(snapshot.smartMinutes?.structuredSummary, "Official package overview")
        XCTAssertEqual(snapshot.notes.map(\.text), ["canonical note"])
    }

    func testLegacyMinutesFallbackIsReportedAsFallbackHealth() throws {
        try seedMetadata()
        try seedTranscript(speaker: "SPEAKER_00", text: "Legacy minutes stay readable.")
        try seedLegacyMinutes(summary: "Legacy summary")

        let snapshot = MeetingAssetSnapshot.load(recordPath: recordDir, duration: 30)

        XCTAssertEqual(snapshot.health.smartMinutes.state, .fallback)
        XCTAssertEqual(snapshot.health.smartMinutes.source, "minutes.json")
        XCTAssertTrue(snapshot.health.usesFallback)
        XCTAssertEqual(snapshot.smartMinutes?.structuredSummary, "Legacy summary")
    }

    func testMissingTranscriptWithMediaCanDriveRecovery() throws {
        try seedMetadata()
        try seedMedia()

        let snapshot = MeetingAssetSnapshot.load(recordPath: recordDir, duration: 30)

        XCTAssertEqual(snapshot.health.transcript.state, .missing)
        XCTAssertTrue(snapshot.health.canRecoverTranscript)
        XCTAssertTrue(snapshot.transcriptEntries.isEmpty)
    }

    func testMissingSmartMinutesWithTranscriptCanDriveGeneration() throws {
        try seedMetadata()
        try seedTranscript(speaker: "SPEAKER_00", text: "Generate Smart Minutes from transcript.")

        let snapshot = MeetingAssetSnapshot.load(recordPath: recordDir, duration: 30)

        XCTAssertEqual(snapshot.health.smartMinutes.state, .missing)
        XCTAssertTrue(snapshot.health.canGenerateSmartMinutes)
        XCTAssertNil(snapshot.smartMinutes)
    }

    func testMissingMediaKeepsTextContentWithMediaMissingHealth() throws {
        try seedMetadata()
        try seedTranscript(speaker: "Alice", text: "Text review still opens.")
        try seedInsightPackage(overview: "Text-only overview")
        try "00:02 text note".write(to: recordDir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let snapshot = MeetingAssetSnapshot.load(recordPath: recordDir, duration: 30)

        XCTAssertNil(snapshot.mediaURL)
        XCTAssertEqual(snapshot.health.media.state, .missing)
        XCTAssertTrue(snapshot.mediaStatusMessage?.contains("媒体文件缺失") == true)
        XCTAssertEqual(snapshot.transcriptEntries.map(\.text), ["Text review still opens."])
        XCTAssertEqual(snapshot.smartMinutes?.structuredSummary, "Text-only overview")
        XCTAssertEqual(snapshot.notes.map(\.text), ["text note"])
    }

    func testDamagedTranscriptReportsDamagedHealth() throws {
        try seedMetadata()
        try seedMedia()
        try "{not-json".write(to: recordDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)

        let snapshot = MeetingAssetSnapshot.load(recordPath: recordDir, duration: 30)

        XCTAssertEqual(snapshot.health.transcript.state, .damaged)
        XCTAssertTrue(snapshot.health.damagedFiles.contains("transcript.json"))
        XCTAssertTrue(snapshot.transcriptEntries.isEmpty)
    }

    func testSpeakerRenameWritesOfficialTranscriptThroughCanonicalPath() throws {
        try seedMetadata()
        try seedTranscript(speaker: "SPEAKER_00", text: "Rename the official transcript.")

        let changed = try MeetingAssetSnapshot.renameSpeaker(in: recordDir, from: "SPEAKER_00", to: "Alice")
        let snapshot = MeetingAssetSnapshot.load(recordPath: recordDir, duration: 30)

        XCTAssertTrue(changed)
        XCTAssertEqual(snapshot.transcriptEntries.map(\.speaker), ["Alice"])
        let transcriptJSON = try String(contentsOf: recordDir.appendingPathComponent("transcript.json"), encoding: .utf8)
        XCTAssertTrue(transcriptJSON.contains("Alice"))
        XCTAssertFalse(transcriptJSON.contains("SPEAKER_00"))
    }

    func testRecordReviewNotesSaveThroughCanonicalPath() throws {
        try seedMetadata()
        let metadata = try makeMetadata()
        let dataSource = RecordReviewDataSource(
            metadata: metadata,
            rootDirectory: recordDir.deletingLastPathComponent()
        )

        dataSource.onNoteCreated("canonical note writeback", at: 7)

        let notes = try String(contentsOf: recordDir.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("00:07 canonical note writeback"))
        XCTAssertEqual(MeetingAssetSnapshot.load(recordPath: recordDir, duration: 30).health.notes.state, .available)
    }

    func testFailedWritesPreservePreviousOfficialFiles() throws {
        try seedMetadata()
        try seedTranscript(speaker: "SPEAKER_00", text: "Keep this transcript.")
        try "00:01 keep this note".write(to: recordDir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let originalTranscript = try String(contentsOf: recordDir.appendingPathComponent("transcript.json"), encoding: .utf8)
        let originalNotes = try String(contentsOf: recordDir.appendingPathComponent("notes.md"), encoding: .utf8)
        let failingWriter: MeetingAssetSnapshot.DataWriter = { _, _ in throw TestWriteError.planned }

        XCTAssertThrowsError(try MeetingAssetSnapshot.writeNotes(
            [TimestampedNote(text: "new note", timestamp: 9)],
            to: recordDir,
            dataWriter: failingWriter
        ))
        XCTAssertThrowsError(try MeetingAssetSnapshot.renameSpeaker(
            in: recordDir,
            from: "SPEAKER_00",
            to: "Alice",
            dataWriter: failingWriter
        ))

        XCTAssertEqual(try String(contentsOf: recordDir.appendingPathComponent("notes.md"), encoding: .utf8), originalNotes)
        XCTAssertEqual(try String(contentsOf: recordDir.appendingPathComponent("transcript.json"), encoding: .utf8), originalTranscript)
    }

    private func seedMetadata() throws {
        let metadata = try makeMetadata()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: recordDir.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func makeMetadata() throws -> RecordMetadata {
        RecordMetadata(
            id: recordDir.lastPathComponent,
            createdAt: Date(timeIntervalSince1970: 1_779_520_000),
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: [],
            autoTags: [],
            summaryPreview: "Canonical fixture"
        )
    }

    private func seedMedia() throws {
        try "fake media".write(to: recordDir.appendingPathComponent("recording.m4a"), atomically: true, encoding: .utf8)
    }

    private func seedTranscript(speaker: String, text: String) throws {
        try """
        [
          {"start_ms":4000,"end_ms":6000,"speaker":"\(speaker)","text":"\(text)"}
        ]
        """.write(to: recordDir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
    }

    private func seedLegacyMinutes(summary: String) throws {
        try """
        {
          "structured_summary":"\(summary)",
          "highlights":["Legacy highlight"],
          "key_decisions":["Legacy decision"],
          "action_items":["Legacy action"],
          "timeline_beats":[{"timestamp":"00:04","title":"Legacy chapter","summary":"Legacy body"}]
        }
        """.write(to: recordDir.appendingPathComponent("minutes.json"), atomically: true, encoding: .utf8)
    }

    private func seedInsightPackage(overview: String) throws {
        try """
        {
          "session_overview":{"title":"Canonical","overview":"\(overview)","topics":["assets"]},
          "highlight_insights":[{"quote":"Canonical quote","reason":"Official package","speaker":"Alice","evidence_span":{"start_ms":4000,"end_ms":6000}}],
          "speaker_perspectives":[{"speaker":"Alice","viewpoints":["Official viewpoint"],"evidence_spans":[{"start_ms":4000,"end_ms":6000}]}],
          "decision_ledger":[{"problem":"Source","options":["package","minutes"],"decision":"Use package","rationale":"It is official","owner":"Alice","needs_review":false,"evidence_span":{"start_ms":4000,"end_ms":6000}}],
          "action_tracks":[{"task":"Use canonical source","owner":"Alice","due_at":"","priority":"medium","status":"open","needs_review":false,"evidence_span":{"start_ms":4000,"end_ms":6000}}],
          "timeline_beats":[{"timestamp":"00:04","title":"Canonical chapter","summary":"Canonical body"}],
          "provenance_links":[]
        }
        """.write(to: recordDir.appendingPathComponent("insight_package.json"), atomically: true, encoding: .utf8)
    }
}

private enum TestWriteError: Error {
    case planned
}
