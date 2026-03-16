import Foundation
import AVFoundation

// MARK: - Warmup Backlog

struct WarmupBacklogUpdate: Equatable {
    let queue: [AudioChunk]
    let droppedExisting: [AudioChunk]
    let droppedIncoming: Bool
    let bufferedAudioMs: Int
}

struct WarmupBacklogPolicy {
    let maxChunks: Int
    let maxBufferedAudioMs: Int

    func enqueue(_ chunk: AudioChunk, into queued: [AudioChunk]) -> WarmupBacklogUpdate {
        guard maxChunks > 0, maxBufferedAudioMs > 0 else {
            return WarmupBacklogUpdate(queue: queued, droppedExisting: [], droppedIncoming: true, bufferedAudioMs: queued.bufferedAudioMs)
        }

        var nextQueue = queued
        var droppedExisting: [AudioChunk] = []
        let incomingDuration = max(0, chunk.endMs - chunk.startMs)

        while !nextQueue.isEmpty && (nextQueue.count >= maxChunks || nextQueue.bufferedAudioMs + incomingDuration > maxBufferedAudioMs) {
            if let silentIndex = nextQueue.firstIndex(where: \.isLikelySilent) {
                droppedExisting.append(nextQueue.remove(at: silentIndex))
                continue
            }
            if chunk.isLikelySilent {
                return WarmupBacklogUpdate(
                    queue: nextQueue,
                    droppedExisting: droppedExisting,
                    droppedIncoming: true,
                    bufferedAudioMs: nextQueue.bufferedAudioMs
                )
            }
            droppedExisting.append(nextQueue.removeFirst())
        }

        if nextQueue.count >= maxChunks || nextQueue.bufferedAudioMs + incomingDuration > maxBufferedAudioMs {
            return WarmupBacklogUpdate(
                queue: nextQueue,
                droppedExisting: droppedExisting,
                droppedIncoming: true,
                bufferedAudioMs: nextQueue.bufferedAudioMs
            )
        }

        nextQueue.append(chunk)
        return WarmupBacklogUpdate(
            queue: nextQueue,
            droppedExisting: droppedExisting,
            droppedIncoming: false,
            bufferedAudioMs: nextQueue.bufferedAudioMs
        )
    }
}

// MARK: - Warmup Retry

enum WarmupRetryAction: Equatable {
    case retry(afterSeconds: Int)
    case failSession
}

struct WarmupRetryPolicy {
    let maxAutomaticRetries: Int
    let retryDelaySec: Int

    func action(forFailureCount failureCount: Int) -> WarmupRetryAction {
        if failureCount <= maxAutomaticRetries {
            return .retry(afterSeconds: retryDelaySec)
        }
        return .failSession
    }
}

// MARK: - Capture State Mapper

enum LiveCaptureStateMapper {
    static func captureState(warmReady: Bool, hasTranscript: Bool) -> CaptureState {
        guard warmReady else { return .warmingModel }
        return hasTranscript ? .transcribing : .capturing
    }
}

// MARK: - AudioChunk Array Helper

extension Array where Element == AudioChunk {
    var bufferedAudioMs: Int {
        reduce(0) { partialResult, chunk in
            partialResult + Swift.max(0, chunk.endMs - chunk.startMs)
        }
    }
}
