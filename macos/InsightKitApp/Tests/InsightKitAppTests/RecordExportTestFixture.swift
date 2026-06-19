import Foundation
@testable import InsightKitApp

enum RecordExportTestFixture {
    static func makeRoot(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    @discardableResult
    static func seedRecord(
        root: URL,
        recordID: String,
        source: RecordSource = .imported
    ) throws -> URL {
        let recordPath = root.appendingPathComponent(recordID, isDirectory: true)
        try FileManager.default.createDirectory(at: recordPath, withIntermediateDirectories: true)

        let metadata = RecordMetadata(
            id: recordID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30,
            mediaType: .audio,
            source: source,
            userTags: [],
            autoTags: ["export"],
            summaryPreview: source == .live ? "实时会议本地导出" : "转写会议本地导出"
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
        return recordPath
    }
}
