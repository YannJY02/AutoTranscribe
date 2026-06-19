import AVFoundation
import AVKit
import SwiftUI

/// Unified media player supporting both video playback and audio waveform visualization.
/// Uses Coordinator to hold AVPlayer instance across SwiftUI view identity changes.
struct MediaPlayerView: NSViewRepresentable {
    let url: URL?
    let isPlaying: Bool
    let seekRequest: MediaSeekRequest?
    let onSeek: ((TimeInterval) -> Void)?
    let onTimeUpdate: ((TimeInterval) -> Void)?

    init(
        url: URL? = nil,
        isPlaying: Bool = false,
        seekRequest: MediaSeekRequest? = nil,
        onSeek: ((TimeInterval) -> Void)? = nil,
        onTimeUpdate: ((TimeInterval) -> Void)? = nil
    ) {
        self.url = url
        self.isPlaying = isPlaying
        self.seekRequest = seekRequest
        self.onSeek = onSeek
        self.onTimeUpdate = onTimeUpdate
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSeek: onSeek, onTimeUpdate: onTimeUpdate)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = Self.controlsStyle(forMediaURL: url)
        playerView.showsFullScreenToggleButton = false
        context.coordinator.playerView = playerView
        if let url {
            context.coordinator.loadURL(url)
        }
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let coordinator = context.coordinator
        let controlsStyle = Self.controlsStyle(forMediaURL: url)
        if nsView.controlsStyle != controlsStyle {
            nsView.controlsStyle = controlsStyle
        }
        if coordinator.currentURL != url {
            if let url {
                coordinator.loadURL(url)
            } else {
                coordinator.unload()
            }
        }
        if let seekRequest {
            coordinator.seekIfNeeded(seekRequest)
        }
        if isPlaying {
            coordinator.player?.play()
        } else {
            coordinator.player?.pause()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.dismantle(from: nsView)
    }

    static func controlsStyle(forMediaURL url: URL?) -> AVPlayerViewControlsStyle {
        switch url?.pathExtension.lowercased() {
        case "mp4", "mov", "mkv":
            return .inline
        default:
            return .minimal
        }
    }

    class Coordinator {
        var player: AVPlayer?
        weak var playerView: AVPlayerView?
        var currentURL: URL?
        var timeObserver: Any?
        var lastAppliedSeekRequestID: UUID?
        var lastNotifiedTime: TimeInterval?
        let onSeek: ((TimeInterval) -> Void)?
        let onTimeUpdate: ((TimeInterval) -> Void)?

        init(onSeek: ((TimeInterval) -> Void)?, onTimeUpdate: ((TimeInterval) -> Void)?) {
            self.onSeek = onSeek
            self.onTimeUpdate = onTimeUpdate
        }

        func loadURL(_ url: URL) {
            releasePlayer()
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            playerView?.player = newPlayer
            currentURL = url
            addTimeObserver()
        }

        func seekIfNeeded(_ request: MediaSeekRequest) {
            guard lastAppliedSeekRequestID != request.id else { return }
            lastAppliedSeekRequestID = request.id
            let time = CMTime(seconds: request.time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.player != nil, self.lastAppliedSeekRequestID == request.id else { return }
                self.onTimeUpdate?(request.time)
            }
        }

        func unload() {
            releasePlayer()
            playerView?.player = nil
            currentURL = nil
            lastAppliedSeekRequestID = nil
            lastNotifiedTime = nil
        }

        func dismantle(from nsView: AVPlayerView) {
            unload()
            nsView.player = nil
            if playerView === nsView {
                playerView = nil
            }
        }

        private func addTimeObserver() {
            guard let player else { return }
            let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                if let last = lastNotifiedTime, abs(seconds - last) < 0.5 {
                    return
                }
                lastNotifiedTime = seconds
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.player != nil else { return }
                    self.onTimeUpdate?(seconds)
                }
            }
        }

        private func releasePlayer() {
            removeTimeObserver()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }

        private func removeTimeObserver() {
            if let observer = timeObserver, let player {
                player.removeTimeObserver(observer)
            }
            timeObserver = nil
            lastNotifiedTime = nil
        }

        deinit {
            unload()
        }
    }
}
