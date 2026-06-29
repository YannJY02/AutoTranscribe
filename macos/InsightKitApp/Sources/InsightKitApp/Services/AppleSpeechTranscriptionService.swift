import AVFoundation
import CoreMedia
import Foundation

#if compiler(>=6.2)
import Speech
#endif

enum AppleSpeechAssetState: Equatable {
    case unsupported
    case supported
    case downloading
    case installed
}

enum AppleSpeechRuntimeState: String, Equatable {
    case unsupportedOS
    case unsupportedSDK
    case unsupportedLocale
    case assetMissing
    case assetDownloading
    case supported
    case installed
    case ready
    case failed
}

struct AppleSpeechRuntimeStatus: Equatable {
    let state: AppleSpeechRuntimeState
    let localeIdentifier: String
    let detail: String

    var isUsableForTranscription: Bool {
        switch state {
        case .supported, .installed, .ready:
            return true
        case .unsupportedOS, .unsupportedSDK, .unsupportedLocale, .assetMissing, .assetDownloading, .failed:
            return false
        }
    }

    var shouldExposeExperimentalEngineOption: Bool {
        isUsableForTranscription
    }

    var shouldExposeExperimentalFinalMediaOption: Bool {
        isUsableForTranscription
    }

    var shouldExposePeerLocalASREngineOption: Bool {
        AppleSpeechPeerEngineParityStatus.evaluate(runtimeStatus: self).canExposeAsPeerLocalASREngine
    }

    var userMessage: String {
        switch state {
        case .unsupportedOS:
            return "Apple Speech 实验转写需要 macOS 26 或更新系统。"
        case .unsupportedSDK:
            return "当前构建 SDK 不包含新的 Apple Speech 转写 API。"
        case .unsupportedLocale:
            return "Apple Speech 当前不支持 \(localeIdentifier) 转写。"
        case .assetMissing:
            return "Apple Speech \(localeIdentifier) 语音资源需要安装后才能用于本地转写。"
        case .assetDownloading:
            return "Apple Speech \(localeIdentifier) 语音资源正在下载。"
        case .supported:
            return "Apple Speech \(localeIdentifier) 资源受支持，可用于实验离线转写；系统仍可能提供资源安装请求。"
        case .installed:
            return "Apple Speech \(localeIdentifier) 语音资源已安装，可用于实验离线转写。"
        case .ready:
            return "Apple Speech \(localeIdentifier) 实验离线转写已就绪。"
        case .failed:
            return detail.isEmpty ? "Apple Speech 状态检查失败。" : "Apple Speech 状态检查失败：\(detail)"
        }
    }

    static func resolve(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        sdkSupportsAppleSpeech: Bool,
        localeIdentifier: String,
        localeSupported: Bool,
        assetState: AppleSpeechAssetState?,
        failureDetail: String = ""
    ) -> AppleSpeechRuntimeStatus {
        guard osVersion.majorVersion >= 26 else {
            return AppleSpeechRuntimeStatus(
                state: .unsupportedOS,
                localeIdentifier: localeIdentifier,
                detail: "requires macOS 26+"
            )
        }

        guard sdkSupportsAppleSpeech else {
            return AppleSpeechRuntimeStatus(
                state: .unsupportedSDK,
                localeIdentifier: localeIdentifier,
                detail: "missing SpeechAnalyzer/SpeechTranscriber SDK"
            )
        }

        guard localeSupported else {
            return AppleSpeechRuntimeStatus(
                state: .unsupportedLocale,
                localeIdentifier: localeIdentifier,
                detail: "locale is not supported by Apple Speech"
            )
        }

        switch assetState {
        case .unsupported:
            return AppleSpeechRuntimeStatus(
                state: .unsupportedLocale,
                localeIdentifier: localeIdentifier,
                detail: "speech assets are unsupported"
            )
        case .supported:
            return AppleSpeechRuntimeStatus(
                state: .supported,
                localeIdentifier: localeIdentifier,
                detail: "speech assets are supported"
            )
        case .downloading:
            return AppleSpeechRuntimeStatus(
                state: .assetDownloading,
                localeIdentifier: localeIdentifier,
                detail: "speech assets are downloading"
            )
        case .installed:
            return AppleSpeechRuntimeStatus(
                state: .ready,
                localeIdentifier: localeIdentifier,
                detail: "speech assets are installed"
            )
        case .none:
            return AppleSpeechRuntimeStatus(
                state: .failed,
                localeIdentifier: localeIdentifier,
                detail: failureDetail
            )
        }
    }
}

struct AppleSpeechPeerEngineParityStatus: Equatable {
    let canExposeAsPeerLocalASREngine: Bool
    let blockingReasons: [String]

    var userMessage: String {
        if canExposeAsPeerLocalASREngine {
            return "Apple Speech 已满足 Live Workspace、strict-local、Media-Timed Transcript、Diarization 与 Record/Smart Minutes parity，可作为同级本地 ASR Engine。"
        }

        return "Apple Speech 目前不是同级 ASR Engine；只能作为音频最终媒体的实验转写原型。"
    }

    static func evaluate(
        runtimeStatus: AppleSpeechRuntimeStatus,
        liveWorkspaceTranscriptionProven: Bool = false,
        mediaTimedTranscriptProven: Bool = true,
        diarizationIntegrationProven: Bool = false,
        recordAndSmartMinutesParityProven: Bool = false
    ) -> AppleSpeechPeerEngineParityStatus {
        var blockingReasons: [String] = []

        if !isStrictLocalRuntimeReady(runtimeStatus) {
            blockingReasons.append("strict-local runtime 未就绪：\(runtimeStatus.userMessage)")
        }

        if !mediaTimedTranscriptProven {
            blockingReasons.append("Media-Timed Transcript 输出尚未证明。")
        }

        if !liveWorkspaceTranscriptionProven {
            blockingReasons.append("Live Workspace realtime transcription 尚未接入 Apple Speech。")
        }

        if !diarizationIntegrationProven {
            blockingReasons.append("Diarization 尚未证明；当前 Apple Speech 转写接口没有会议说话人分离契约。")
        }

        if !recordAndSmartMinutesParityProven {
            blockingReasons.append("Record save 与 Smart Minutes 行为 parity 尚未完整证明。")
        }

        return AppleSpeechPeerEngineParityStatus(
            canExposeAsPeerLocalASREngine: blockingReasons.isEmpty,
            blockingReasons: blockingReasons
        )
    }

    private static func isStrictLocalRuntimeReady(_ status: AppleSpeechRuntimeStatus) -> Bool {
        switch status.state {
        case .installed, .ready:
            return true
        case .unsupportedOS, .unsupportedSDK, .unsupportedLocale, .assetMissing, .assetDownloading, .supported, .failed:
            return false
        }
    }
}

struct AppleSpeechRawTranscriptRow: Equatable {
    let text: String
    let range: CMTimeRange
    let confidence: Double?
}

enum AppleSpeechTranscriptNormalizer {
    static func transcriptSegments(
        from rows: [AppleSpeechRawTranscriptRow],
        mediaTimelineStart: CMTime = .zero
    ) -> [TranscriptSegment] {
        rows.compactMap { row in
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let normalizedStart = max(0, row.range.start.seconds - mediaTimelineStart.seconds)
            let normalizedEnd = max(
                normalizedStart,
                normalizedStart + max(0, row.range.duration.seconds)
            )
            return TranscriptSegment(
                startMs: Int((normalizedStart * 1000).rounded()),
                endMs: Int((normalizedEnd * 1000).rounded()),
                speaker: "Apple Speech",
                source: "apple-speech",
                text: text
            )
        }
        .sorted { lhs, rhs in
            if lhs.startMs == rhs.startMs {
                return lhs.endMs < rhs.endMs
            }
            return lhs.startMs < rhs.startMs
        }
    }
}

enum AppleSpeechTranscriptionError: LocalizedError, Equatable {
    case unsupportedRuntime(AppleSpeechRuntimeStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedRuntime(let status):
            return status.userMessage
        }
    }
}

enum AppleSpeechLocaleMatcher {
    static func bestSupportedLocaleIdentifier(
        for requestedIdentifier: String,
        supportedLocaleIdentifiers: [String]
    ) -> String? {
        guard let requested = AppleSpeechLocaleComponents(requestedIdentifier) else {
            return nil
        }

        if let exact = supportedLocaleIdentifiers.first(where: {
            AppleSpeechLocaleComponents($0)?.normalizedIdentifier == requested.normalizedIdentifier
        }) {
            return exact
        }

        if let preferredRegion = requested.preferredRegion {
            if let regionMatch = supportedLocaleIdentifiers.first(where: {
                guard let candidate = AppleSpeechLocaleComponents($0) else { return false }
                return candidate.language == requested.language && candidate.region == preferredRegion
            }) {
                return regionMatch
            }
        }

        if let requestedRegion = requested.region {
            if let regionMatch = supportedLocaleIdentifiers.first(where: {
                guard let candidate = AppleSpeechLocaleComponents($0) else { return false }
                return candidate.language == requested.language && candidate.region == requestedRegion
            }) {
                return regionMatch
            }
        }

        return supportedLocaleIdentifiers.first {
            AppleSpeechLocaleComponents($0)?.language == requested.language
        }
    }
}

private struct AppleSpeechLocaleComponents {
    let language: String
    let script: String?
    let region: String?
    let normalizedIdentifier: String

    init?(_ identifier: String) {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased(), !language.isEmpty else {
            return nil
        }

        var script: String?
        var region: String?
        for part in parts.dropFirst() {
            if part.count == 4 {
                script = part.lowercased()
            } else if region == nil {
                region = part.uppercased()
            }
        }

        self.language = language
        self.script = script
        self.region = region
        self.normalizedIdentifier = normalized.lowercased()
    }

    var preferredRegion: String? {
        guard language == "zh" else { return nil }

        switch script {
        case "hans":
            return "CN"
        case "hant":
            return "TW"
        default:
            return nil
        }
    }
}

final class AppleSpeechTranscriptionService: @unchecked Sendable {
    func runtimeStatus(locale: Locale = Locale(identifier: "zh-Hans")) async -> AppleSpeechRuntimeStatus {
        let localeIdentifier = locale.identifier

        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            return .resolve(
                sdkSupportsAppleSpeech: Self.sdkSupportsAppleSpeech,
                localeIdentifier: localeIdentifier,
                localeSupported: false,
                assetState: nil
            )
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let supportedLocales = await SpeechTranscriber.supportedLocales
            guard let resolvedLocale = Self.bestSupportedLocale(for: locale, in: supportedLocales) else {
                return .resolve(
                    sdkSupportsAppleSpeech: true,
                    localeIdentifier: localeIdentifier,
                    localeSupported: false,
                    assetState: nil
                )
            }

            let transcriber = Self.makeTranscriber(locale: resolvedLocale)
            let assetStatus = await AssetInventory.status(forModules: [transcriber])
            return .resolve(
                sdkSupportsAppleSpeech: true,
                localeIdentifier: resolvedLocale.identifier,
                localeSupported: true,
                assetState: AppleSpeechAssetState(assetStatus)
            )
        }
        #endif

        return .resolve(
            sdkSupportsAppleSpeech: Self.sdkSupportsAppleSpeech,
            localeIdentifier: localeIdentifier,
            localeSupported: false,
            assetState: nil
        )
    }

    func transcribeAudioFile(
        _ audioURL: URL,
        locale: Locale = Locale(identifier: "zh-Hans")
    ) async throws -> [TranscriptSegment] {
        let status = await runtimeStatus(locale: locale)
        guard status.isUsableForTranscription else {
            throw AppleSpeechTranscriptionError.unsupportedRuntime(status)
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let supportedLocales = await SpeechTranscriber.supportedLocales
            let resolvedLocale = Self.bestSupportedLocale(for: locale, in: supportedLocales) ?? locale
            let audioFile = try AVAudioFile(forReading: audioURL)
            let transcriber = Self.makeTranscriber(locale: resolvedLocale)
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            async let analysis: Void = analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            var rows: [AppleSpeechRawTranscriptRow] = []
            for try await result in transcriber.results {
                rows.append(
                    AppleSpeechRawTranscriptRow(
                        text: String(result.text.characters),
                        range: result.range,
                        confidence: nil
                    )
                )
            }
            try await analysis
            return AppleSpeechTranscriptNormalizer.transcriptSegments(from: rows)
        }
        #endif

        throw AppleSpeechTranscriptionError.unsupportedRuntime(status)
    }

    private static var sdkSupportsAppleSpeech: Bool {
        #if compiler(>=6.2)
        return true
        #else
        return false
        #endif
    }

    private static func bestSupportedLocale(for locale: Locale, in supportedLocales: [Locale]) -> Locale? {
        let supportedLocaleIdentifiers = supportedLocales.map(\.identifier)
        guard let supportedIdentifier = AppleSpeechLocaleMatcher.bestSupportedLocaleIdentifier(
            for: locale.identifier,
            supportedLocaleIdentifiers: supportedLocaleIdentifiers
        ) else {
            return nil
        }

        return supportedLocales.first { $0.identifier == supportedIdentifier }
            ?? Locale(identifier: supportedIdentifier)
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }
    #endif
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private extension AppleSpeechAssetState {
    init(_ status: AssetInventory.Status) {
        switch status {
        case .unsupported:
            self = .unsupported
        case .supported:
            self = .supported
        case .downloading:
            self = .downloading
        case .installed:
            self = .installed
        @unknown default:
            self = .unsupported
        }
    }
}
#endif
