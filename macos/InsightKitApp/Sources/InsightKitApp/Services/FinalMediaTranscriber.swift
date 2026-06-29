import Foundation

protocol FinalMediaTranscribing {
    func transcribeFinalMedia(mediaPath: String, source: String) throws -> [TranscriptSegment]
}

final class FinalMediaTranscriptionRouter: FinalMediaTranscribing {
    private let action: FinalMediaTranscriptionActioning

    init(
        rpcClient: InsightRPCClientProtocol,
        appleSpeechService: AppleSpeechTranscriptionService = AppleSpeechTranscriptionService(),
        appleSpeechPrototypeEnabled: @escaping () -> Bool = {
            guard !ProcessInfo.processInfo.isRunningInsightKitTests else {
                return false
            }
            return AppConfigStore.shared.config.asr.appleSpeechPrototypeEnabled
        },
        action: FinalMediaTranscriptionActioning? = nil
    ) {
        self.action = action ?? FinalMediaTranscriptionAction(
            adapter: InsightRuntimeActionRPCAdapter(rpcClient: rpcClient),
            appleSpeechService: appleSpeechService,
            appleSpeechPrototypeEnabled: appleSpeechPrototypeEnabled
        )
    }

    func transcribeFinalMedia(mediaPath: String, source: String) throws -> [TranscriptSegment] {
        try action.transcribeFinalMedia(
            FinalMediaTranscriptionActionRequest(mediaPath: mediaPath, source: source)
        ).get()
    }

    static func isAppleSpeechAudioCandidate(mediaPath: String) -> Bool {
        let audioExtensions: Set<String> = ["aac", "aif", "aiff", "caf", "m4a", "mp3", "wav"]
        let ext = URL(fileURLWithPath: mediaPath).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }

}

private extension ProcessInfo {
    var isRunningInsightKitTests: Bool {
        if environment.keys.contains(where: { $0.localizedCaseInsensitiveContains("xctest") }) {
            return true
        }

        let name = processName.lowercased()
        return name.contains("xctest") || name.contains("packagetests")
    }
}
