import Foundation

struct LiveMediaCaptureTimeline: Codable, Equatable {
    var videoStartSec: TimeInterval?
    var audioStartSec: TimeInterval?
    var compositionTimeline: ReviewMediaCompositionTimeline = .zeroAligned

    mutating func reset() {
        videoStartSec = nil
        audioStartSec = nil
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

    private mutating func updateCompositionTimeline() {
        guard let videoStartSec, let audioStartSec else {
            compositionTimeline = .zeroAligned
            return
        }

        let origin = min(videoStartSec, audioStartSec)
        compositionTimeline = ReviewMediaCompositionTimeline(
            videoStartSec: max(0, videoStartSec - origin),
            audioStartSec: max(0, audioStartSec - origin)
        )
    }
}
