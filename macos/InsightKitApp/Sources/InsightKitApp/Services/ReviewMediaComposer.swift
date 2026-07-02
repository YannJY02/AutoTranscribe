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

struct ReviewMediaCompositionPauseInterval: Codable, Equatable {
    let startSec: TimeInterval
    let endSec: TimeInterval

    var durationSec: TimeInterval {
        max(0, endSec - startSec)
    }

    init(startSec: TimeInterval, endSec: TimeInterval) {
        self.startSec = max(0, startSec)
        self.endSec = max(self.startSec, endSec)
    }
}

struct ReviewMediaCompositionTimeline: Codable, Equatable {
    let videoStartSec: TimeInterval
    let audioStartSec: TimeInterval
    let videoPauseIntervals: [ReviewMediaCompositionPauseInterval]

    static let zeroAligned = ReviewMediaCompositionTimeline(videoStartSec: 0, audioStartSec: 0)

    init(
        videoStartSec: TimeInterval,
        audioStartSec: TimeInterval,
        videoPauseIntervals: [ReviewMediaCompositionPauseInterval] = []
    ) {
        self.videoStartSec = videoStartSec
        self.audioStartSec = audioStartSec
        self.videoPauseIntervals = videoPauseIntervals
    }

    enum CodingKeys: String, CodingKey {
        case videoStartSec
        case audioStartSec
        case videoPauseIntervals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoStartSec = try container.decode(TimeInterval.self, forKey: .videoStartSec)
        audioStartSec = try container.decode(TimeInterval.self, forKey: .audioStartSec)
        videoPauseIntervals = try container.decodeIfPresent(
            [ReviewMediaCompositionPauseInterval].self,
            forKey: .videoPauseIntervals
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(videoStartSec, forKey: .videoStartSec)
        try container.encode(audioStartSec, forKey: .audioStartSec)
        if !videoPauseIntervals.isEmpty {
            try container.encode(videoPauseIntervals, forKey: .videoPauseIntervals)
        }
    }
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

        for segment in sourceWindow.videoSegments {
            try compositionVideo.insertTimeRange(segment.sourceRange, of: loaded.videoTrack, at: segment.insertAt)
        }
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
        let videoDurationSec = finiteDurationSec(videoDuration)
        let audioDurationSec = finiteDurationSec(audioDuration)
        let activeVideoRanges = activeVideoSourceRanges(
            videoDurationSec: videoDurationSec,
            timeline: timeline
        )
        let activeVideoDurationSec = activeVideoRanges.reduce(0) { $0 + $1.durationSec }

        let videoTimelineStartSec = max(0, timeline.videoStartSec)
        let audioTimelineStartSec = max(0, timeline.audioStartSec)
        let videoTimelineEndSec = videoTimelineStartSec + activeVideoDurationSec
        let audioTimelineEndSec = audioTimelineStartSec + audioDurationSec

        let intersectionStartSec = max(videoTimelineStartSec, audioTimelineStartSec)
        let intersectionEndSec = min(videoTimelineEndSec, audioTimelineEndSec)
        guard intersectionEndSec > intersectionStartSec else {
            throw ReviewMediaComposerError.invalidTimelineIntersection
        }

        let durationSec = intersectionEndSec - intersectionStartSec
        let videoActiveStartSec = max(0, intersectionStartSec - videoTimelineStartSec)
        let audioSourceStartSec = max(0, intersectionStartSec - audioTimelineStartSec)
        let videoSegments = try videoSegments(
            activeRanges: activeVideoRanges,
            activeStartSec: videoActiveStartSec,
            durationSec: durationSec,
            timescale: timescale
        )
        return ReviewMediaSourceWindow(
            videoSegments: videoSegments,
            audioStart: CMTime(seconds: audioSourceStartSec, preferredTimescale: timescale),
            duration: CMTime(seconds: durationSec, preferredTimescale: timescale)
        )
    }

    private func finiteDurationSec(_ time: CMTime) -> TimeInterval {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private func activeVideoSourceRanges(
        videoDurationSec: TimeInterval,
        timeline: ReviewMediaCompositionTimeline
    ) -> [ReviewMediaSourceRange] {
        guard videoDurationSec > 0 else { return [] }
        let pauseRanges = timeline.videoPauseIntervals
            .compactMap { interval -> ReviewMediaSourceRange? in
                let start = min(max(0, interval.startSec), videoDurationSec)
                let end = min(max(start, interval.endSec), videoDurationSec)
                guard end > start else { return nil }
                return ReviewMediaSourceRange(startSec: start, durationSec: end - start)
            }
            .sorted { $0.startSec < $1.startSec }

        var mergedPauses: [ReviewMediaSourceRange] = []
        for pause in pauseRanges {
            guard let last = mergedPauses.last else {
                mergedPauses.append(pause)
                continue
            }
            let lastEnd = last.startSec + last.durationSec
            if pause.startSec <= lastEnd {
                mergedPauses[mergedPauses.count - 1] = ReviewMediaSourceRange(
                    startSec: last.startSec,
                    durationSec: max(lastEnd, pause.startSec + pause.durationSec) - last.startSec
                )
            } else {
                mergedPauses.append(pause)
            }
        }

        var activeRanges: [ReviewMediaSourceRange] = []
        var cursor: TimeInterval = 0
        for pause in mergedPauses {
            if pause.startSec > cursor {
                activeRanges.append(ReviewMediaSourceRange(startSec: cursor, durationSec: pause.startSec - cursor))
            }
            cursor = max(cursor, pause.startSec + pause.durationSec)
        }
        if videoDurationSec > cursor {
            activeRanges.append(ReviewMediaSourceRange(startSec: cursor, durationSec: videoDurationSec - cursor))
        }
        return activeRanges
    }

    private func videoSegments(
        activeRanges: [ReviewMediaSourceRange],
        activeStartSec: TimeInterval,
        durationSec: TimeInterval,
        timescale: CMTimeScale
    ) throws -> [ReviewMediaVideoSegment] {
        let epsilon: TimeInterval = 0.001
        var activeCursor: TimeInterval = 0
        var outputCursor: TimeInterval = 0
        var remaining = durationSec
        var segments: [ReviewMediaVideoSegment] = []

        for range in activeRanges {
            let activeEnd = activeCursor + range.durationSec
            defer { activeCursor = activeEnd }
            guard activeStartSec < activeEnd - epsilon else { continue }

            let startInsideRange = max(0, activeStartSec - activeCursor)
            let available = max(0, range.durationSec - startInsideRange)
            let take = min(remaining, available)
            guard take > epsilon else { continue }

            let sourceStartSec = range.startSec + startInsideRange
            segments.append(ReviewMediaVideoSegment(
                sourceRange: CMTimeRange(
                    start: CMTime(seconds: sourceStartSec, preferredTimescale: timescale),
                    duration: CMTime(seconds: take, preferredTimescale: timescale)
                ),
                insertAt: CMTime(seconds: outputCursor, preferredTimescale: timescale)
            ))
            remaining -= take
            outputCursor += take
            if remaining <= epsilon {
                break
            }
        }

        guard remaining <= 0.02, !segments.isEmpty else {
            throw ReviewMediaComposerError.invalidTimelineIntersection
        }
        return segments
    }
}

private struct LoadedReviewMediaTracks {
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack
    let videoDuration: CMTime
    let audioDuration: CMTime
    let videoTransform: CGAffineTransform
}

private struct ReviewMediaSourceRange {
    let startSec: TimeInterval
    let durationSec: TimeInterval
}

private struct ReviewMediaVideoSegment {
    let sourceRange: CMTimeRange
    let insertAt: CMTime
}

private struct ReviewMediaSourceWindow {
    let videoSegments: [ReviewMediaVideoSegment]
    let audioStart: CMTime
    let duration: CMTime
}
