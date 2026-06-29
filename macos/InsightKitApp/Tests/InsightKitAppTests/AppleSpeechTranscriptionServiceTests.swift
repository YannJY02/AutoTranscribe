import CoreMedia
import XCTest
@testable import InsightKitApp

final class AppleSpeechTranscriptionServiceTests: XCTestCase {
    func testReportsUnsupportedOnMacOSBefore26() {
        let status = AppleSpeechRuntimeStatus.resolve(
            osVersion: OperatingSystemVersion(majorVersion: 25, minorVersion: 6, patchVersion: 0),
            sdkSupportsAppleSpeech: true,
            localeIdentifier: "en-US",
            localeSupported: true,
            assetState: .installed
        )

        XCTAssertEqual(status.state, .unsupportedOS)
        XCTAssertFalse(status.isUsableForTranscription)
        XCTAssertFalse(status.shouldExposeExperimentalEngineOption)
        XCTAssertTrue(status.userMessage.contains("macOS 26"))
    }

    func testMapsAssetStatesToActionableRuntimeStatus() {
        let supported = AppleSpeechRuntimeStatus.resolve(
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            sdkSupportsAppleSpeech: true,
            localeIdentifier: "zh-Hans",
            localeSupported: true,
            assetState: .supported
        )
        XCTAssertEqual(supported.state, .supported)
        XCTAssertTrue(supported.isUsableForTranscription)
        XCTAssertTrue(supported.shouldExposeExperimentalEngineOption)
        XCTAssertTrue(supported.userMessage.contains("受支持"))

        let downloading = AppleSpeechRuntimeStatus.resolve(
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            sdkSupportsAppleSpeech: true,
            localeIdentifier: "zh-Hans",
            localeSupported: true,
            assetState: .downloading
        )
        XCTAssertEqual(downloading.state, .assetDownloading)

        let installed = AppleSpeechRuntimeStatus.resolve(
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            sdkSupportsAppleSpeech: true,
            localeIdentifier: "zh-Hans",
            localeSupported: true,
            assetState: .installed
        )
        XCTAssertEqual(installed.state, .ready)
        XCTAssertTrue(installed.isUsableForTranscription)
        XCTAssertTrue(installed.shouldExposeExperimentalEngineOption)
    }

    func testReadyRuntimeDoesNotExposeAppleSpeechAsPeerLocalEngineWithoutLiveAndDiarizationProof() {
        let status = AppleSpeechRuntimeStatus.resolve(
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            sdkSupportsAppleSpeech: true,
            localeIdentifier: "zh-Hans",
            localeSupported: true,
            assetState: .installed
        )

        let parity = AppleSpeechPeerEngineParityStatus.evaluate(runtimeStatus: status)

        XCTAssertFalse(status.shouldExposePeerLocalASREngineOption)
        XCTAssertFalse(parity.canExposeAsPeerLocalASREngine)
        XCTAssertTrue(parity.userMessage.contains("不是同级 ASR Engine"))
        XCTAssertTrue(parity.blockingReasons.contains { $0.contains("Live Workspace") })
        XCTAssertTrue(parity.blockingReasons.contains { $0.contains("Diarization") })
    }

    func testPeerLocalEngineParityRequiresInstalledStrictLocalRuntime() {
        let status = AppleSpeechRuntimeStatus.resolve(
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            sdkSupportsAppleSpeech: true,
            localeIdentifier: "zh-Hans",
            localeSupported: true,
            assetState: .supported
        )

        let parity = AppleSpeechPeerEngineParityStatus.evaluate(
            runtimeStatus: status,
            liveWorkspaceTranscriptionProven: true,
            diarizationIntegrationProven: true,
            recordAndSmartMinutesParityProven: true
        )

        XCTAssertFalse(parity.canExposeAsPeerLocalASREngine)
        XCTAssertTrue(parity.blockingReasons.contains { $0.contains("strict-local") })
    }

    func testUnsupportedLocaleIsNotASelectableEngineOption() {
        let status = AppleSpeechRuntimeStatus.resolve(
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            sdkSupportsAppleSpeech: true,
            localeIdentifier: "zz-ZZ",
            localeSupported: false,
            assetState: .installed
        )

        XCTAssertEqual(status.state, .unsupportedLocale)
        XCTAssertFalse(status.shouldExposeExperimentalEngineOption)
        XCTAssertTrue(status.userMessage.contains("不支持"))
    }

    func testLocaleMatcherHandlesAppleSpeechLocaleIdentifierVariants() {
        let supported = ["en_US", "zh_CN", "zh_TW", "ja_JP"]

        XCTAssertEqual(
            AppleSpeechLocaleMatcher.bestSupportedLocaleIdentifier(
                for: "en-US",
                supportedLocaleIdentifiers: supported
            ),
            "en_US"
        )
        XCTAssertEqual(
            AppleSpeechLocaleMatcher.bestSupportedLocaleIdentifier(
                for: "zh-Hans",
                supportedLocaleIdentifiers: supported
            ),
            "zh_CN"
        )
        XCTAssertEqual(
            AppleSpeechLocaleMatcher.bestSupportedLocaleIdentifier(
                for: "zh-Hant",
                supportedLocaleIdentifiers: supported
            ),
            "zh_TW"
        )
        XCTAssertNil(
            AppleSpeechLocaleMatcher.bestSupportedLocaleIdentifier(
                for: "fr-FR",
                supportedLocaleIdentifiers: supported
            )
        )
    }

    func testNormalizesAppleSpeechResultsToSavedMediaTimeline() {
        let rows = [
            AppleSpeechRawTranscriptRow(
                text: " First topic ",
                range: CMTimeRange(
                    start: CMTime(seconds: 12.25, preferredTimescale: 1_000),
                    duration: CMTime(seconds: 1.5, preferredTimescale: 1_000)
                ),
                confidence: 0.92
            ),
            AppleSpeechRawTranscriptRow(
                text: "Second topic",
                range: CMTimeRange(
                    start: CMTime(seconds: 14.0, preferredTimescale: 1_000),
                    duration: CMTime(seconds: 2.25, preferredTimescale: 1_000)
                ),
                confidence: nil
            ),
        ]

        let segments = AppleSpeechTranscriptNormalizer.transcriptSegments(
            from: rows,
            mediaTimelineStart: CMTime(seconds: 10.0, preferredTimescale: 1_000)
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].startMs, 2_250)
        XCTAssertEqual(segments[0].endMs, 3_750)
        XCTAssertEqual(segments[0].speaker, "Apple Speech")
        XCTAssertEqual(segments[0].source, "apple-speech")
        XCTAssertEqual(segments[0].text, "First topic")
        XCTAssertEqual(segments[1].startMs, 4_000)
        XCTAssertEqual(segments[1].endMs, 6_250)
    }

    func testDropsEmptyRowsAndClampsNegativeTimelineOffsets() {
        let rows = [
            AppleSpeechRawTranscriptRow(
                text: "   ",
                range: CMTimeRange(
                    start: CMTime(seconds: 2.0, preferredTimescale: 1_000),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 1_000)
                ),
                confidence: nil
            ),
            AppleSpeechRawTranscriptRow(
                text: "Starts before media",
                range: CMTimeRange(
                    start: CMTime(seconds: 8.5, preferredTimescale: 1_000),
                    duration: CMTime(seconds: 0.25, preferredTimescale: 1_000)
                ),
                confidence: nil
            ),
        ]

        let segments = AppleSpeechTranscriptNormalizer.transcriptSegments(
            from: rows,
            mediaTimelineStart: CMTime(seconds: 10.0, preferredTimescale: 1_000)
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startMs, 0)
        XCTAssertEqual(segments[0].endMs, 250)
    }

    func testPackagedInfoPlistDeclaresSpeechRecognitionUsage() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("InsightKitApp-Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        let message = try XCTUnwrap(plist["NSSpeechRecognitionUsageDescription"] as? String)
        XCTAssertTrue(message.contains("Apple Speech"))
        XCTAssertTrue(message.contains("转写"))
    }
}
