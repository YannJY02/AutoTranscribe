import AVFoundation
import Foundation

protocol MediaAssetInspecting {
    func hasAudioTrack(url: URL) -> Bool
    func durationSec(url: URL) -> Double?
}

struct AVFoundationMediaAssetInspector: MediaAssetInspecting {
    func hasAudioTrack(url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        final class Box {
            var hasAudio = false
        }
        let box = Box()

        Task {
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            box.hasAudio = !tracks.isEmpty
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 3) == .success else {
            return false
        }
        return box.hasAudio
    }

    func durationSec(url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        final class Box {
            var duration: CMTime?
        }
        let box = Box()

        Task {
            box.duration = try? await asset.load(.duration)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 3) == .success,
              let duration = box.duration,
              duration.isValid,
              !duration.isIndefinite else {
            return nil
        }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        return seconds
    }
}
