import AVFoundation
import AVKit
import SwiftUI

/// Unified media player supporting both video playback and audio waveform visualization.
/// Uses Coordinator to hold AVPlayer instance across SwiftUI view identity changes.
struct MediaPlayerView: NSViewRepresentable {
    let url: URL?
    let isPlaying: Bool
    let onSeek: ((TimeInterval) -> Void)?
    let onTimeUpdate: ((TimeInterval) -> Void)?

    init(
        url: URL? = nil,
        isPlaying: Bool = false,
        onSeek: ((TimeInterval) -> Void)? = nil,
        onTimeUpdate: ((TimeInterval) -> Void)? = nil
    ) {
        self.url = url
        self.isPlaying = isPlaying
        self.onSeek = onSeek
        self.onTimeUpdate = onTimeUpdate
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSeek: onSeek, onTimeUpdate: onTimeUpdate)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        context.coordinator.playerView = playerView
        if let url {
            context.coordinator.loadURL(url)
        }
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.currentURL != url {
            if let url {
                coordinator.loadURL(url)
            } else {
                coordinator.unload()
            }
        }
        if isPlaying {
            coordinator.player?.play()
        } else {
            coordinator.player?.pause()
        }
    }

    class Coordinator {
        var player: AVPlayer?
        var playerView: AVPlayerView?
        var currentURL: URL?
        var timeObserver: Any?
        let onSeek: ((TimeInterval) -> Void)?
        let onTimeUpdate: ((TimeInterval) -> Void)?

        init(onSeek: ((TimeInterval) -> Void)?, onTimeUpdate: ((TimeInterval) -> Void)?) {
            self.onSeek = onSeek
            self.onTimeUpdate = onTimeUpdate
        }

        func loadURL(_ url: URL) {
            removeTimeObserver()
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            playerView?.player = newPlayer
            currentURL = url
            addTimeObserver()
        }

        func unload() {
            removeTimeObserver()
            player?.pause()
            player = nil
            playerView?.player = nil
            currentURL = nil
        }

        private func addTimeObserver() {
            guard let player else { return }
            let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                self?.onTimeUpdate?(time.seconds)
            }
        }

        private func removeTimeObserver() {
            if let observer = timeObserver, let player {
                player.removeTimeObserver(observer)
            }
            timeObserver = nil
        }

        deinit {
            removeTimeObserver()
        }
    }
}
