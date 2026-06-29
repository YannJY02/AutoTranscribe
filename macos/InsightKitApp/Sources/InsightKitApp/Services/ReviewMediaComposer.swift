import AVFoundation
import Foundation

protocol ReviewMediaComposing {
    func composeVideoWithAudio(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        timeline: ReviewMediaCompositionTimeline
    ) throws -> URL
}

extension ReviewMediaComposing {
    func composeVideoWithAudio(videoURL: URL, audioURL: URL, outputURL: URL) throws -> URL {
        try composeVideoWithAudio(videoURL: videoURL, audioURL: audioURL, outputURL: outputURL, timeline: .zeroAligned)
    }
}

struct ReviewMediaCompositionTimeline: Codable, Equatable {
    let videoStartSec: TimeInterval
    let audioStartSec: TimeInterval

    static let zeroAligned = ReviewMediaCompositionTimeline(videoStartSec: 0, audioStartSec: 0)
}

enum ReviewMediaComposerError: LocalizedError {
    case missingVideoTrack
    case missingAudioTrack
    case invalidTimelineDuration
    case invalidTimelineIntersection
    case exportSessionUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "视频文件没有可合成的视频轨。"
        case .missingAudioTrack:
            return "音频文件没有可合成的音频轨。"
        case .invalidTimelineDuration:
            return "音视频合成时间线无效。"
        case .invalidTimelineIntersection:
            return "音视频合成时间线没有可播放的重叠区间。"
        case .exportSessionUnavailable:
            return "无法创建 macOS 媒体合成会话。"
        case .exportFailed(let detail):
            return "音视频合成失败：\(detail)"
        }
    }
}

struct AVFoundationReviewMediaComposer: ReviewMediaComposing {
    func composeVideoWithAudio(videoURL: URL, audioURL: URL, outputURL: URL) throws -> URL {
        try composeVideoWithAudio(videoURL: videoURL, audioURL: audioURL, outputURL: outputURL, timeline: .zeroAligned)
    }

    func composeVideoWithAudio(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        timeline: ReviewMediaCompositionTimeline
    ) throws -> URL {
        _ = timeline
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let loaded = try loadTracks(videoAsset: videoAsset, audioAsset: audioAsset)

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ReviewMediaComposerError.missingVideoTrack
        }
        guard let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ReviewMediaComposerError.missingAudioTrack
        }

        let sourceWindow = try sourceWindow(
            videoDuration: loaded.videoDuration,
            audioDuration: loaded.audioDuration,
            timeline: timeline
        )
        guard CMTimeCompare(sourceWindow.duration, .zero) > 0 else {
            throw ReviewMediaComposerError.invalidTimelineDuration
        }

        let videoRange = CMTimeRange(start: sourceWindow.videoStart, duration: sourceWindow.duration)
        try compositionVideo.insertTimeRange(videoRange, of: loaded.videoTrack, at: .zero)
        compositionVideo.preferredTransform = loaded.videoTransform

        let audioRange = CMTimeRange(start: sourceWindow.audioStart, duration: sourceWindow.duration)
        try compositionAudio.insertTimeRange(audioRange, of: loaded.audioTrack, at: .zero)

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ReviewMediaComposerError.exportSessionUnavailable
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()

        guard exporter.status == .completed else {
            let detail = exporter.error?.localizedDescription ?? "\(exporter.status.rawValue)"
            throw ReviewMediaComposerError.exportFailed(detail)
        }
        return outputURL
    }

    private func loadTracks(videoAsset: AVURLAsset, audioAsset: AVURLAsset) throws -> LoadedReviewMediaTracks {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box {
            var result: Result<LoadedReviewMediaTracks, Error>?
        }
        let box = Box()

        Task {
            do {
                let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
                let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
                guard let videoTrack = videoTracks.first else {
                    throw ReviewMediaComposerError.missingVideoTrack
                }
                guard let audioTrack = audioTracks.first else {
                    throw ReviewMediaComposerError.missingAudioTrack
                }
                let videoDuration = try await videoAsset.load(.duration)
                let audioDuration = try await audioAsset.load(.duration)
                let videoTransform = try await videoTrack.load(.preferredTransform)
                box.result = .success(
                    LoadedReviewMediaTracks(
                        videoTrack: videoTrack,
                        audioTrack: audioTrack,
                        videoDuration: videoDuration,
                        audioDuration: audioDuration,
                        videoTransform: videoTransform
                    )
                )
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try box.result?.get() ?? {
            throw ReviewMediaComposerError.exportSessionUnavailable
        }()
    }

    private func sourceWindow(
        videoDuration: CMTime,
        audioDuration: CMTime,
        timeline: ReviewMediaCompositionTimeline
    ) throws -> ReviewMediaSourceWindow {
        let timescale: CMTimeScale = 600
        let videoTimelineStart = CMTime(seconds: max(0, timeline.videoStartSec), preferredTimescale: timescale)
        let audioTimelineStart = CMTime(seconds: max(0, timeline.audioStartSec), preferredTimescale: timescale)
        let videoTimelineEnd = videoTimelineStart + videoDuration
        let audioTimelineEnd = audioTimelineStart + audioDuration

        let intersectionStart = CMTimeMaximum(videoTimelineStart, audioTimelineStart)
        let intersectionEnd = CMTimeMinimum(videoTimelineEnd, audioTimelineEnd)
        guard CMTimeCompare(intersectionEnd, intersectionStart) > 0 else {
            throw ReviewMediaComposerError.invalidTimelineIntersection
        }

        let duration = intersectionEnd - intersectionStart
        return ReviewMediaSourceWindow(
            videoStart: intersectionStart - videoTimelineStart,
            audioStart: intersectionStart - audioTimelineStart,
            duration: duration
        )
    }
}

private struct LoadedReviewMediaTracks {
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack
    let videoDuration: CMTime
    let audioDuration: CMTime
    let videoTransform: CGAffineTransform
}

private struct ReviewMediaSourceWindow {
    let videoStart: CMTime
    let audioStart: CMTime
    let duration: CMTime
}
