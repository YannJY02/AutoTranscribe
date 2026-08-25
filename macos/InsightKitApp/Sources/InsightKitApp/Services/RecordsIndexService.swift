import AppKit
import AVFoundation
import Darwin
import Foundation

/// Service for indexing, searching, and managing transcription records.
/// Records are stored as folders under rootDirectory, each containing:
/// metadata.json, recording.mp4/m4a, transcript.json, notes.md, insight_package.json, minutes.json
final class RecordsIndexService: ObservableObject {
    static let rootDirectoryDefaultsKey = "RecordsRootDirectory"
    private static let datalessFileFlag: UInt32 = 0x40000000

    @Published var records: [RecordMetadata] = []

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let environment: [String: String]
    private let bookmarkStore: SecurityScopedBookmarkStore
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
    private var contentSearchIndex: [String: String] = [:]

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bookmarkStore: SecurityScopedBookmarkStore? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.environment = environment
        self.bookmarkStore = bookmarkStore ?? SecurityScopedBookmarkStore(defaults: defaults, environment: environment)
    }

    static func defaultRootDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if SecurityScopedBookmarkStore.isAppSandboxed(environment: environment) {
            return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("InsightKit/Records", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/InsightKit/Records", isDirectory: true)
    }

    static func currentRootDirectory(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let url = configuredRootDirectory(environment: environment) {
            return url
        }
        let bookmarkStore = SecurityScopedBookmarkStore(defaults: defaults, environment: environment)
        if let url = bookmarkStore.resolveBookmark() {
            return url
        }
        if let path = defaults.string(forKey: rootDirectoryDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultRootDirectory(fileManager: fileManager, environment: environment)
    }

    var rootDirectory: URL {
        get {
            if let url = Self.configuredRootDirectory(environment: environment) {
                return url
            }
            if let url = bookmarkStore.resolveBookmark() {
                return url
            }
            if let path = defaults.string(forKey: Self.rootDirectoryDefaultsKey), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Self.defaultRootDirectory(fileManager: fileManager, environment: environment)
        }
        set {
            defaults.set(newValue.path, forKey: Self.rootDirectoryDefaultsKey)
            bookmarkStore.saveBookmark(for: newValue)
        }
    }

    private static func configuredRootDirectory(environment: [String: String]) -> URL? {
        guard let path = environment["INSIGHTKIT_RECORDS_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"),
              path != "/"
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func isSafeRecordID(_ recordID: String) -> Bool {
        guard let first = recordID.unicodeScalars.first,
              recordID.count <= 128,
              CharacterSet.alphanumerics.contains(first)
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return recordID.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - Scanning

    func refreshIndex() {
        let root = rootDirectory
        let accessToken = bookmarkStore.accessToken(for: root)
        defer { accessToken?.stop() }
        let snapshot = Self.loadIndex(root: root, fileManager: fileManager)
        records = snapshot.records
        contentSearchIndex = snapshot.contentSearchIndex
    }

    func refreshIndexAsync() {
        let root = rootDirectory
        let fileManager = self.fileManager
        let bookmarkStore = self.bookmarkStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let accessToken = bookmarkStore.accessToken(for: root)
            defer { accessToken?.stop() }
            let snapshot = Self.loadIndex(root: root, fileManager: fileManager)
            DispatchQueue.main.async {
                self?.records = snapshot.records
                self?.contentSearchIndex = snapshot.contentSearchIndex
            }
        }
    }

    func recentRecords(limit: Int) -> [RecordMetadata] {
        if records.isEmpty { refreshIndex() }
        return Array(records.prefix(limit))
    }

    func prepareUITestSeedIfRequested() {
        guard environment["INSIGHTKIT_UI_TEST_MODE"] == "1",
              let recordID = environment["INSIGHTKIT_UI_TEST_SEED_RECORD_ID"],
              Self.isSafeRecordID(recordID)
        else { return }

        let metadata = RecordMetadata(
            id: recordID,
            createdAt: Date(timeIntervalSince1970: 1_782_720_000),
            duration: 30,
            mediaType: .audio,
            source: .imported,
            userTags: ["release"],
            autoTags: ["restart"],
            summaryPreview: "restart persistence evidence"
        )
        saveRecord(metadata, at: rootDirectory.appendingPathComponent(recordID, isDirectory: true))
    }

    // MARK: - CRUD

    func saveRecord(_ metadata: RecordMetadata, at path: URL) {
        let accessToken = bookmarkStore.accessToken(for: rootDirectory)
        defer { accessToken?.stop() }
        ensureDirectoryExists(path)
        let metaURL = path.appendingPathComponent("metadata.json")
        if let data = try? jsonEncoder.encode(metadata) {
            try? data.write(to: metaURL)
        }
        // Refresh index to include new record
        refreshIndex()
    }

    func deleteRecord(id: String) {
        let accessToken = bookmarkStore.accessToken(for: rootDirectory)
        defer { accessToken?.stop() }
        guard let record = records.first(where: { $0.id == id }) else { return }
        guard let folder = recordFolderURL(for: record.id) else { return }
        try? fileManager.removeItem(at: folder)
        refreshIndex()
    }

    func renameRecord(id: String, to title: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        records[idx].title = normalizedTitle.isEmpty ? nil : normalizedTitle
        persistMetadata(records[idx])
        refreshIndex()
    }

    // MARK: - Search & Filter

    func searchRecords(query: String) -> [RecordMetadata] {
        guard !query.isEmpty else { return records }
        let lower = query.lowercased()
        return records.filter { record in
            record.id.lowercased().contains(lower)
                || record.displayTitle.lowercased().contains(lower)
                || (record.title ?? "").lowercased().contains(lower)
                || (record.summaryPreview ?? "").lowercased().contains(lower)
                || record.userTags.contains(where: { $0.lowercased().contains(lower) })
                || record.autoTags.contains(where: { $0.lowercased().contains(lower) })
                || recordContentMatches(record, lowercasedQuery: lower)
        }
    }

    func filterRecords(tags: [String], type: MediaType?) -> [RecordMetadata] {
        filterRecords(criteria: RecordFilterCriteria(tags: Set(tags), type: type))
    }

    func filterRecords(criteria: RecordFilterCriteria) -> [RecordMetadata] {
        records.filter { record in
            recordMatches(record, criteria: criteria)
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

        guard let url = MeetingAssetSnapshot.canonicalMediaURL(in: recordPath) else { return nil }

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
        let accessToken = bookmarkStore.accessToken(for: rootDirectory)
        defer { accessToken?.stop() }
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

    private static func loadIndex(
        root: URL,
        fileManager: FileManager
    ) -> (records: [RecordMetadata], contentSearchIndex: [String: String]) {
        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [:])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [RecordMetadata] = []
        var loadedSearchIndex: [String: String] = [:]
        for folder in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let metaURL = folder.appendingPathComponent("metadata.json")
            guard isLocallyReadableRegularFile(metaURL),
                  let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(RecordMetadata.self, from: data) else { continue }
            loaded.append(meta)
            loadedSearchIndex[meta.id] = buildContentSearchText(for: folder)
        }

        return (loaded.sorted { $0.createdAt > $1.createdAt }, loadedSearchIndex)
    }

    private func persistMetadata(_ metadata: RecordMetadata) {
        let accessToken = bookmarkStore.accessToken(for: rootDirectory)
        defer { accessToken?.stop() }
        guard let folder = recordFolderURL(for: metadata.id) else { return }
        let metaURL = folder.appendingPathComponent("metadata.json")
        if let data = try? jsonEncoder.encode(metadata) {
            try? data.write(to: metaURL)
        }
    }

    func recordFolderURL(for recordID: String) -> URL? {
        Self.recordFolderURL(for: recordID, rootDirectory: rootDirectory, fileManager: fileManager)
    }

    static func recordFolderURL(
        for recordID: String,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let direct = rootDirectory.appendingPathComponent(recordID, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: direct.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return direct
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for folder in contents {
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &childIsDirectory),
                  childIsDirectory.boolValue
            else { continue }
            let metaURL = folder.appendingPathComponent("metadata.json")
            guard isLocallyReadableRegularFile(metaURL),
                  let data = try? Data(contentsOf: metaURL),
                  let metadata = try? decoder.decode(RecordMetadata.self, from: data),
                  metadata.id == recordID
            else { continue }
            return folder
        }

        return nil
    }

    private func recordContentMatches(_ record: RecordMetadata, lowercasedQuery: String) -> Bool {
        contentSearchIndex[record.id]?.contains(lowercasedQuery) == true
    }

    private static func buildContentSearchText(for folder: URL) -> String {
        let filenames = ["transcript.json", "insight_package.json", "minutes.json", "notes.md"]
        var parts: [String] = []
        for name in filenames {
            let url = folder.appendingPathComponent(name)
            guard isLocallyReadableRegularFile(url) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            parts.append(text)
        }
        return parts.joined(separator: "\n").lowercased()
    }

    private static func isLocallyReadableRegularFile(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else {
            return false
        }
        return !isDatalessFile(url)
    }

    private static func isDatalessFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (UInt32(info.st_flags) & datalessFileFlag) != 0
    }

    private func recordMatches(_ record: RecordMetadata, criteria: RecordFilterCriteria) -> Bool {
        let matchesTags = criteria.tags.isEmpty
            || !criteria.tags.isDisjoint(with: Set(record.userTags + record.autoTags))
        let matchesType = criteria.type == nil || record.mediaType == criteria.type
        let matchesTime = criteria.timeFilter?.contains(
            record.createdAt,
            now: criteria.now,
            calendar: criteria.calendar
        ) ?? true
        return matchesTags && matchesType && matchesTime
    }
}
