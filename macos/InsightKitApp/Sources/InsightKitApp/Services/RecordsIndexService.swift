import Foundation

/// Service for indexing, searching, and managing transcription records.
/// Step 4: Stub with interface only. Step 7 will fill implementations.
final class RecordsIndexService: ObservableObject {
    @Published var records: [RecordMetadata] = []

    var rootDirectory: URL {
        get {
            let path = UserDefaults.standard.string(forKey: "RecordsRootDirectory")
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Documents/InsightKit/Records").path
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "RecordsRootDirectory")
        }
    }

    func recentRecords(limit: Int) -> [RecordMetadata] {
        // Step 7: scan rootDirectory and return most recent records
        []
    }

    func saveRecord(_ metadata: RecordMetadata, at path: URL) {
        // Step 7: write metadata.json to path
    }

    func deleteRecord(id: String) {
        // Step 7: remove record folder
    }

    func searchRecords(query: String) -> [RecordMetadata] {
        // Step 7: full-text search across transcripts, notes, minutes
        []
    }

    func filterRecords(tags: [String], type: MediaType?) -> [RecordMetadata] {
        // Step 7: filter by tags and media type
        []
    }

    func allTags() -> [String] {
        // Step 7: aggregate all user tags
        []
    }

    func generateThumbnail(for recordPath: URL) async -> URL? {
        // Step 7: AVAssetImageGenerator for video, waveform for audio
        nil
    }
}
