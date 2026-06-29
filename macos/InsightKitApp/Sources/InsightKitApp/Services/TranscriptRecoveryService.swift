import Foundation

struct TranscriptRecoveryResult: Equatable {
    let recordPath: URL
    let mediaURL: URL
    let segments: [TranscriptSegment]
    let health: MeetingAssetHealth
    let smartMinutesMayNeedRegeneration: Bool
}

enum TranscriptRecoveryError: LocalizedError, Equatable {
    case notRecoverable(String)
    case recoveredEmptyTranscript

    var errorDescription: String? {
        switch self {
        case .notRecoverable(let message):
            return message
        case .recoveredEmptyTranscript:
            return "恢复转写没有产生可保存的逐字稿。"
        }
    }
}

protocol TranscriptRecoveryServicing {
    func canRecover(recordPath: URL, duration: TimeInterval) -> Bool
    func recoverTranscript(recordPath: URL, duration: TimeInterval) throws -> TranscriptRecoveryResult
}

final class TranscriptRecoveryService: TranscriptRecoveryServicing {
    private let action: TranscriptRecoveryActioning

    init(action: TranscriptRecoveryActioning) {
        self.action = action
    }

    convenience init(rpcClient: InsightRPCClientProtocol) {
        let adapter = InsightRuntimeActionRPCAdapter(rpcClient: rpcClient)
        self.init(action: TranscriptRecoveryAction(adapter: adapter))
    }

    func canRecover(recordPath: URL, duration: TimeInterval) -> Bool {
        MeetingAssetSnapshot.load(recordPath: recordPath, duration: duration).health.canRecoverTranscript
    }

    func recoverTranscript(recordPath: URL, duration: TimeInterval) throws -> TranscriptRecoveryResult {
        let before = MeetingAssetSnapshot.load(recordPath: recordPath, duration: duration)
        guard before.health.canRecoverTranscript, let mediaURL = before.mediaURL else {
            throw TranscriptRecoveryError.notRecoverable("当前记录没有可用于恢复逐字稿的已保存媒体。")
        }

        let recovered = try action.recoverTranscript(TranscriptRecoveryActionRequest(
            mediaPath: mediaURL.path,
            source: "media-recovery"
        )).get()
        guard !recovered.isEmpty else {
            throw TranscriptRecoveryError.recoveredEmptyTranscript
        }

        let segments = Self.preserveReliableSpeakerLabels(from: before.transcriptEntries, in: recovered)
        try MeetingAssetSnapshot.writeTranscriptSegments(segments, to: recordPath)

        let after = MeetingAssetSnapshot.load(recordPath: recordPath, duration: duration)
        return TranscriptRecoveryResult(
            recordPath: recordPath,
            mediaURL: mediaURL,
            segments: segments,
            health: after.health,
            smartMinutesMayNeedRegeneration: before.smartMinutes != nil
        )
    }

    private static func preserveReliableSpeakerLabels(
        from previousEntries: [TranscriptEntry],
        in recovered: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !previousEntries.isEmpty else { return recovered }
        return recovered.map { segment in
            guard let previous = previousEntries.first(where: { entry in
                abs(entry.timestamp - TimeInterval(segment.startMs) / 1000.0) <= 0.5
                    && normalizedText(entry.text) == normalizedText(segment.text)
            }),
            let speaker = previous.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
            !speaker.isEmpty
            else { return segment }
            return TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                speaker: speaker,
                source: segment.source,
                text: segment.text
            )
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}
