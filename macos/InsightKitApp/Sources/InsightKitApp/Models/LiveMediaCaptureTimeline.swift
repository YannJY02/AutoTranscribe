import Foundation

struct LiveMediaCapturePauseInterval: Codable, Equatable {
    let startSec: TimeInterval
    let endSec: TimeInterval

    var durationSec: TimeInterval {
        max(0, endSec - startSec)
    }
}

struct LiveMediaCaptureTimeline: Codable, Equatable {
    var videoStartSec: TimeInterval?
    var audioStartSec: TimeInterval?
    var pauseIntervals: [LiveMediaCapturePauseInterval] = []
    var currentPauseStartSec: TimeInterval?
    var compositionTimeline: ReviewMediaCompositionTimeline = .zeroAligned

    mutating func reset() {
        videoStartSec = nil
        audioStartSec = nil
        pauseIntervals = []
        currentPauseStartSec = nil
        compositionTimeline = .zeroAligned
    }

    mutating func markVideoStart(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        videoStartSec = time
        updateCompositionTimeline()
    }

    mutating func markAudioStartIfNeeded(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard audioStartSec == nil else { return }
        audioStartSec = time
        updateCompositionTimeline()
    }

    mutating func markAudioBufferStartIfNeeded(
        receivedAt time: TimeInterval = ProcessInfo.processInfo.systemUptime,
        sampleCount: Int,
        sampleRate: Int
    ) {
        guard audioStartSec == nil else { return }
        let bufferDurationSec = sampleCount > 0 && sampleRate > 0
            ? Double(sampleCount) / Double(sampleRate)
            : 0
        markAudioStartIfNeeded(at: max(0, time - bufferDurationSec))
    }

    mutating func markPauseStart(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard currentPauseStartSec == nil else { return }
        currentPauseStartSec = time
        updateCompositionTimeline()
    }

    mutating func markPauseEnd(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let currentPauseStartSec else { return }
        self.currentPauseStartSec = nil
        if time > currentPauseStartSec {
            pauseIntervals.append(LiveMediaCapturePauseInterval(startSec: currentPauseStartSec, endSec: time))
        }
        updateCompositionTimeline()
    }

    private mutating func updateCompositionTimeline() {
        guard let videoStartSec, let audioStartSec else {
            compositionTimeline = .zeroAligned
            return
        }

        let videoActiveStartSec = activeTime(at: videoStartSec)
        let audioActiveStartSec = activeTime(at: audioStartSec)
        let origin = min(videoActiveStartSec, audioActiveStartSec)
        compositionTimeline = ReviewMediaCompositionTimeline(
            videoStartSec: max(0, videoActiveStartSec - origin),
            audioStartSec: max(0, audioActiveStartSec - origin),
            videoPauseIntervals: videoPauseIntervalsRelativeToVideoStart(videoStartSec: videoStartSec)
        )
    }

    private func videoPauseIntervalsRelativeToVideoStart(
        videoStartSec: TimeInterval
    ) -> [ReviewMediaCompositionPauseInterval] {
        pauseIntervals.compactMap { interval in
            let start = max(0, interval.startSec - videoStartSec)
            let end = max(start, interval.endSec - videoStartSec)
            guard end > start else { return nil }
            return ReviewMediaCompositionPauseInterval(startSec: start, endSec: end)
        }
    }

    private func activeTime(at time: TimeInterval) -> TimeInterval {
        time - pausedDuration(before: time)
    }

    private func pausedDuration(before time: TimeInterval) -> TimeInterval {
        var total: TimeInterval = 0
        for interval in pauseIntervals where time > interval.startSec {
            total += max(0, min(time, interval.endSec) - interval.startSec)
        }
        if let currentPauseStartSec, time > currentPauseStartSec {
            total += time - currentPauseStartSec
        }
        return total
    }
}
