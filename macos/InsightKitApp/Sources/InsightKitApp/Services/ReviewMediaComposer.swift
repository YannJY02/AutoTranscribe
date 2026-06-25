import AVFoundation
import Foundation

protocol ReviewMediaComposing {
    func composeVideoWithAudio(videoURL: URL, audioURL: URL, outputURL: URL) throws -> URL
}

enum ReviewMediaComposerError: LocalizedError {
    case missingVideoTrack
    case missingAudioTrack
    case exportSessionUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "视频文件没有可合成的视频轨。"
        case .missingAudioTrack:
            return "音频文件没有可合成的音频轨。"
        case .exportSessionUnavailable:
            return "无法创建 macOS 媒体合成会话。"
        case .exportFailed(let detail):
            return "音视频合成失败：\(detail)"
        }
    }
}

struct AVFoundationReviewMediaComposer: ReviewMediaComposing {
    func composeVideoWithAudio(videoURL: URL, audioURL: URL, outputURL: URL) throws -> URL {
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

        let videoRange = CMTimeRange(start: .zero, duration: loaded.videoDuration)
        try compositionVideo.insertTimeRange(videoRange, of: loaded.videoTrack, at: .zero)
        compositionVideo.preferredTransform = loaded.videoTransform

        let audioDuration = CMTimeMinimum(loaded.audioDuration, loaded.videoDuration)
        let audioRange = CMTimeRange(start: .zero, duration: audioDuration)
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
}

private struct LoadedReviewMediaTracks {
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack
    let videoDuration: CMTime
    let audioDuration: CMTime
    let videoTransform: CGAffineTransform
}
