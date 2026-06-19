import Foundation

struct SecurityScopedBookmarkStore {
    static let recordsRootBookmarkKey = "RecordsRootDirectoryBookmarkV1"

    private let defaults: UserDefaults
    private let environment: [String: String]

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.environment = environment
    }

    var shouldUseSecurityScope: Bool {
        Self.isAppSandboxed(environment: environment)
    }

    static func isAppSandboxed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["INSIGHTKIT_FORCE_APP_CONTAINER_RECORDS"] == "1" {
            return true
        }
        return environment["APP_SANDBOX_CONTAINER_ID"]?.isEmpty == false
    }

    func saveBookmark(for url: URL, key: String = Self.recordsRootBookmarkKey) {
        guard shouldUseSecurityScope else { return }
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: key)
        } catch {
            defaults.removeObject(forKey: key)
        }
    }

    func resolveBookmark(key: String = Self.recordsRootBookmarkKey) -> URL? {
        guard shouldUseSecurityScope,
              let data = defaults.data(forKey: key)
        else { return nil }

        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                saveBookmark(for: url, key: key)
            }
            return url
        } catch {
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    func accessToken(for url: URL) -> SecurityScopedAccessToken? {
        guard shouldUseSecurityScope else { return nil }
        return SecurityScopedAccessToken(url: url)
    }
}

struct SecurityScopedAccessToken {
    private let url: URL
    private let didStartAccessing: Bool

    init?(url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        guard didStart else { return nil }
        self.url = url
        self.didStartAccessing = didStart
    }

    func stop() {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
