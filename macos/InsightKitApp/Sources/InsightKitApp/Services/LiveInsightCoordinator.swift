import Foundation

struct LiveInsightCoordinator {
    let minRefreshInterval: TimeInterval
    let minSegmentsBeforeRefresh: Int

    private(set) var pendingSegments: Int = 0
    private(set) var lastRefreshAt: Date?

    init(minRefreshInterval: TimeInterval = 15, minSegmentsBeforeRefresh: Int = 2) {
        self.minRefreshInterval = minRefreshInterval
        self.minSegmentsBeforeRefresh = minSegmentsBeforeRefresh
    }

    mutating func reset() {
        pendingSegments = 0
        lastRefreshAt = nil
    }

    mutating func registerIngested(_ count: Int, now: Date = Date()) -> Bool {
        guard count > 0 else { return false }
        pendingSegments += count

        if lastRefreshAt == nil {
            return true
        }

        if pendingSegments >= minSegmentsBeforeRefresh {
            return true
        }

        guard let lastRefreshAt else {
            return false
        }

        return now.timeIntervalSince(lastRefreshAt) >= minRefreshInterval
    }

    mutating func markRefreshed(at date: Date = Date()) {
        lastRefreshAt = date
        pendingSegments = 0
    }
}
