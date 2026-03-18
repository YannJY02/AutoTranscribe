import AppKit
import AVFoundation
import Foundation

/// Service for indexing, searching, and managing transcription records.
/// Records are stored as folders under rootDirectory, each containing:
/// metadata.json, recording.mp4/m4a, transcript.json, notes.md, minutes.json
final class RecordsIndexService: ObservableObject {
    @Published var records: [RecordMetadata] = []

    private let fileManager = FileManager.default
    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    var rootDirectory: URL {
        get {
            let path = UserDefaults.standard.string(forKey: "RecordsRootDirectory")
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Documents/InsightKit/Records").path
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "RecordsRootDirectory")
        }
    }

    // MARK: - Scanning

    func refreshIndex() {
        let root = rootDirectory
        ensureDirectoryExists(root)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            records = []
            return
        }

        var loaded: [RecordMetadata] = []
        for folder in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let metaURL = folder.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? jsonDecoder.decode(RecordMetadata.self, from: data) else { continue }
            loaded.append(meta)
        }

        records = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func recentRecords(limit: Int) -> [RecordMetadata] {
        if records.isEmpty { refreshIndex() }
        return Array(records.prefix(limit))
    }

    // MARK: - CRUD

    func saveRecord(_ metadata: RecordMetadata, at path: URL) {
        ensureDirectoryExists(path)
        let metaURL = path.appendingPathComponent("metadata.json")
        if let data = try? jsonEncoder.encode(metadata) {
            try? data.write(to: metaURL)
        }
        // Refresh index to include new record
        refreshIndex()
    }

    func deleteRecord(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let folder = rootDirectory.appendingPathComponent(record.id)
        try? fileManager.removeItem(at: folder)
        refreshIndex()
    }

    // MARK: - Search & Filter

    func searchRecords(query: String) -> [RecordMetadata] {
        guard !query.isEmpty else { return records }
        let lower = query.lowercased()
        return records.filter { record in
            record.id.lowercased().contains(lower)
                || (record.summaryPreview ?? "").lowercased().contains(lower)
                || record.userTags.contains(where: { $0.lowercased().contains(lower) })
                || record.autoTags.contains(where: { $0.lowercased().contains(lower) })
        }
    }

    func filterRecords(tags: [String], type: MediaType?) -> [RecordMetadata] {
        records.filter { record in
            let matchesTags = tags.isEmpty || !Set(tags).isDisjoint(with: Set(record.userTags + record.autoTags))
            let matchesType = type == nil || record.mediaType == type
            return matchesTags && matchesType
        }
    }

    func allTags() -> [String] {
        let allTags = records.flatMap { $0.userTags + $0.autoTags }
        return Array(Set(allTags)).sorted()
    }

    // MARK: - Tag Management

    func addTag(_ tag: String, to recordID: String) {
        guard let idx = records.firstIndex(where: { $0.id == recordID }) else { return }
        if !records[idx].userTags.contains(tag) {
            records[idx].userTags.append(tag)
            persistMetadata(records[idx])
        }
    }

    func removeTag(_ tag: String, from recordID: String) {
        guard let idx = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[idx].userTags.removeAll { $0 == tag }
        persistMetadata(records[idx])
    }

    // MARK: - Thumbnail

    func generateThumbnail(for recordPath: URL) async -> URL? {
        let thumbnailURL = recordPath.appendingPathComponent("thumbnail.png")
        if fileManager.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL
        }

        // Find media file
        let extensions = ["mp4", "mov", "mkv", "m4a", "mp3", "wav"]
        var mediaURL: URL?
        for ext in extensions {
            let candidate = recordPath.appendingPathComponent("recording.\(ext)")
            if fileManager.fileExists(atPath: candidate.path) {
                mediaURL = candidate
                break
            }
        }
        guard let url = mediaURL else { return nil }

        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        do {
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
            try pngData.write(to: thumbnailURL)
            return thumbnailURL
        } catch {
            return nil
        }
    }

    // MARK: - Storage Stats

    var storageUsedBytes: Int64 {
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    var storageUsedLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: storageUsedBytes)
    }

    // MARK: - Helpers

    private func ensureDirectoryExists(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func persistMetadata(_ metadata: RecordMetadata) {
        let folder = rootDirectory.appendingPathComponent(metadata.id)
        let metaURL = folder.appendingPathComponent("metadata.json")
        if let data = try? jsonEncoder.encode(metadata) {
            try? data.write(to: metaURL)
        }
    }
}
