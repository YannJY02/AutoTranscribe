import AVFoundation
import AVKit
import SwiftUI

/// Unified media player supporting both video playback and audio waveform visualization.
/// Uses Coordinator to hold AVPlayer instance across SwiftUI view identity changes.
struct MediaPlayerView: NSViewRepresentable {
    enum PlaybackIntent: Equatable {
        case userControlled
        case play
        case pause
    }

    let url: URL?
    let isPlaying: Bool?
    let seekRequest: MediaSeekRequest?
    let onSeek: ((TimeInterval) -> Void)?
    let onTimeUpdate: ((TimeInterval) -> Void)?

    init(
        url: URL? = nil,
        isPlaying: Bool? = nil,
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
        playerView.videoGravity = Self.videoGravity(forMediaURL: url)
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
        let videoGravity = Self.videoGravity(forMediaURL: url)
        if nsView.videoGravity != videoGravity {
            nsView.videoGravity = videoGravity
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
        switch Self.playbackIntent(for: isPlaying) {
        case .userControlled:
            break
        case .play:
            coordinator.player?.play()
        case .pause:
            coordinator.player?.pause()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.dismantle(from: nsView)
    }

    static func controlsStyle(forMediaURL url: URL?) -> AVPlayerViewControlsStyle {
        .default
    }

    static func videoGravity(forMediaURL url: URL?) -> AVLayerVideoGravity {
        .resizeAspect
    }

    static func isVideoMediaURL(_ url: URL?) -> Bool {
        switch url?.pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "m4v":
            return true
        default:
            return false
        }
    }

    static func playbackIntent(for isPlaying: Bool?) -> PlaybackIntent {
        guard let isPlaying else { return .userControlled }
        return isPlaying ? .play : .pause
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

enum ReviewMediaKind: Equatable {
    case audio
    case video

    init(recordMediaType: MediaType) {
        switch recordMediaType {
        case .audio:
            self = .audio
        case .video:
            self = .video
        }
    }

    static func resolved(forMediaURL url: URL?, override: ReviewMediaKind?) -> ReviewMediaKind {
        if let override { return override }
        return MediaPlayerView.isVideoMediaURL(url) ? .video : .audio
    }
}

struct ReviewMediaPlayerLayout {
    static let videoAspectRatio: CGFloat = 16.0 / 9.0
    static let audioHeight: CGFloat = 128
    static let audioMaximumWidth: CGFloat = 520

    static func frameSize(
        forMediaURL url: URL?,
        mediaKind: ReviewMediaKind? = nil,
        availableWidth: CGFloat,
        maximumVideoHeight: CGFloat
    ) -> CGSize {
        let safeWidth = max(0, availableWidth)
        if ReviewMediaKind.resolved(forMediaURL: url, override: mediaKind) == .video {
            let safeHeight = max(0, maximumVideoHeight)
            let width = min(safeWidth, safeHeight * videoAspectRatio)
            return CGSize(width: width, height: width / videoAspectRatio)
        }
        return CGSize(width: min(safeWidth, audioMaximumWidth), height: audioHeight)
    }

    static func containerHeight(
        forMediaURL url: URL?,
        mediaKind: ReviewMediaKind? = nil,
        maximumVideoHeight: CGFloat
    ) -> CGFloat {
        ReviewMediaKind.resolved(forMediaURL: url, override: mediaKind) == .video ? maximumVideoHeight : audioHeight
    }
}

struct ReviewMediaPlayerView: View {
    let url: URL?
    let mediaKind: ReviewMediaKind?
    let isPlaying: Bool?
    let seekRequest: MediaSeekRequest?
    let maximumVideoHeight: CGFloat
    let accessibilityID: String
    let onSeek: ((TimeInterval) -> Void)?
    let onTimeUpdate: ((TimeInterval) -> Void)?

    init(
        url: URL?,
        mediaKind: ReviewMediaKind? = nil,
        isPlaying: Bool? = nil,
        seekRequest: MediaSeekRequest? = nil,
        maximumVideoHeight: CGFloat = 360,
        accessibilityID: String = "review_media_player",
        onSeek: ((TimeInterval) -> Void)? = nil,
        onTimeUpdate: ((TimeInterval) -> Void)? = nil
    ) {
        self.url = url
        self.mediaKind = mediaKind
        self.isPlaying = isPlaying
        self.seekRequest = seekRequest
        self.maximumVideoHeight = maximumVideoHeight
        self.accessibilityID = accessibilityID
        self.onSeek = onSeek
        self.onTimeUpdate = onTimeUpdate
    }

    var body: some View {
        GeometryReader { proxy in
            let resolvedKind = ReviewMediaKind.resolved(forMediaURL: url, override: mediaKind)
            let size = ReviewMediaPlayerLayout.frameSize(
                forMediaURL: url,
                mediaKind: mediaKind,
                availableWidth: proxy.size.width,
                maximumVideoHeight: maximumVideoHeight
            )

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                MediaPlayerView(
                    url: url,
                    isPlaying: isPlaying,
                    seekRequest: seekRequest,
                    onSeek: onSeek,
                    onTimeUpdate: onTimeUpdate
                )
                .frame(width: size.width, height: size.height)
                .background(
                    resolvedKind == .video ? Color.black : InsightTheme.surface
                )
                .clipShape(RoundedRectangle(cornerRadius: InsightTheme.cornerRadius))
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: ReviewMediaPlayerLayout.containerHeight(
            forMediaURL: url,
            mediaKind: mediaKind,
            maximumVideoHeight: maximumVideoHeight
        ))
        .accessibilityIdentifier(accessibilityID)
    }
}
