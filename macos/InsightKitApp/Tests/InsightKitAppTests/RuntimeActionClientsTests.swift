import XCTest
@testable import InsightKitApp

final class RuntimeActionClientsTests: XCTestCase {
    func testCapabilityProviderAcceptsLegacyMethodAlias() {
        let rpcClient = RPCClientMock()
        rpcClient.sidecarVersionStub = [
            "version": "0.1.0",
            "build": "test",
            "capabilities": ["records.save", "asr.transcribe_media"],
        ]
        let provider = SidecarVersionRuntimeActionCapabilityProvider(rpcClient: rpcClient)

        XCTAssertEqual(provider.availability(for: .recordSave).state, .available)
        XCTAssertEqual(provider.availability(for: .finalMediaTranscription).state, .available)
        XCTAssertEqual(provider.availability(for: .smartMinutesGenerate).state, .unsupported)
    }

    func testCapabilityProviderPrefersProductActionRegistry() {
        let rpcClient = RPCClientMock()
        rpcClient.sidecarVersionStub = [
            "version": "0.1.0",
            "build": "test",
            "capabilities": ["asr.transcribe_media", "insight.build_final"],
            "action_registry": [
                "actions": [
                    ["name": "media.transcribe_final", "state": "degraded", "reason": "warming"],
                    ["name": "smart_minutes.generate", "state": "busy", "reason": "provider busy"],
                ],
            ],
        ]
        let provider = SidecarVersionRuntimeActionCapabilityProvider(rpcClient: rpcClient)

        let finalMedia = provider.availability(for: .finalMediaTranscription)
        XCTAssertEqual(finalMedia.state, .degraded)
        XCTAssertEqual(finalMedia.reason, "warming")
        let smartMinutes = provider.availability(for: .smartMinutesGenerate)
        XCTAssertEqual(smartMinutes.state, .busy)
        XCTAssertEqual(smartMinutes.reason, "provider busy")
        XCTAssertEqual(provider.availability(for: .recordSave).state, .unsupported)
    }

    func testRecordSaveActionValidatesProductInputBeforeRPC() {
        let rpcClient = RPCClientMock()
        let action = RecordSaveAction(adapter: availableAdapter(rpcClient))

        let outcome = action.saveRecord(RecordSaveActionRequest(
            meetingID: "",
            title: "Demo",
            sourcePath: "/tmp/demo.m4a",
            segments: [],
            insightPackage: nil,
            mediaType: "audio",
            recordSource: "live",
            durationSec: 12,
            analysisMeta: nil,
            notesMD: ""
        ))

        guard case .incompleteInput(let message) = outcome else {
            return XCTFail("Expected incomplete input")
        }
        XCTAssertTrue(message.contains("meeting ID"))
        XCTAssertTrue(rpcClient.recordsSaveCalls.isEmpty)
    }

    func testFinalMediaTranscriptionActionMapsSegmentsToProductResult() {
        let rpcClient = RPCClientMock()
        rpcClient.asrTranscribeMediaStub = [
            RPCSegmentDelta(startMs: 1000, endMs: 2500, speaker: "", text: "hello", confidence: 0.9, source: "media"),
        ]
        let action = FinalMediaTranscriptionAction(adapter: availableAdapter(rpcClient))

        let outcome = action.transcribeFinalMedia(FinalMediaTranscriptionActionRequest(
            mediaPath: "/tmp/demo.m4a",
            source: "media"
        ))

        guard case .success(let segments) = outcome else {
            return XCTFail("Expected successful transcription")
        }
        XCTAssertEqual(segments.map(\.text), ["hello"])
        XCTAssertEqual(segments.first?.speaker, "未标注")
        XCTAssertEqual(rpcClient.asrTranscribeMediaCalls.first?.mediaPath, "/tmp/demo.m4a")
    }

    func testRuntimeTranscriptReplacementReturnsUnavailableWhenCapabilityIsUnsupported() {
        let rpcClient = RPCClientMock()
        let provider = StaticRuntimeActionCapabilityProvider(
            availabilityByAction: [
                .runtimeTranscriptReplace: RuntimeActionAvailability(
                    action: .runtimeTranscriptReplace,
                    state: .unsupported,
                    reason: "transcript replacement unavailable"
                ),
            ]
        )
        let action = RuntimeTranscriptReplacementAction(
            adapter: InsightRuntimeActionRPCAdapter(rpcClient: rpcClient, capabilityProvider: provider)
        )

        let outcome = action.replaceRuntimeTranscript(RuntimeTranscriptReplacementActionRequest(
            meetingID: "m-1",
            segments: []
        ))

        guard case .unavailable(let availability) = outcome else {
            return XCTFail("Expected unavailable capability")
        }
        XCTAssertEqual(availability.action, .runtimeTranscriptReplace)
        XCTAssertTrue(rpcClient.transcriptReplaceCalls.isEmpty)
    }

    func testSmartMinutesGenerationMapsTimeoutToRetryableFailure() {
        let rpcClient = RPCClientMock()
        rpcClient.buildFinalError = InsightRPCClient.RPCError.timeout("insight.build_final")
        let action = SmartMinutesGenerationAction(adapter: availableAdapter(rpcClient))

        let outcome = action.generateSmartMinutes(SmartMinutesGenerationActionRequest(meetingID: "m-1"))

        guard case .retryableFailure(let message) = outcome else {
            return XCTFail("Expected retryable failure")
        }
        XCTAssertTrue(message.contains("insight.build_final"))
    }

    func testFinalMediaRouterCanUseFakeActionSeam() throws {
        let fake = FakeFinalMediaTranscriptionAction()
        fake.outcome = .success([
            TranscriptSegment(startMs: 0, endMs: 1000, speaker: "S1", source: "media", text: "from fake action"),
        ])
        let router = FinalMediaTranscriptionRouter(rpcClient: RPCClientMock(), action: fake)

        let segments = try router.transcribeFinalMedia(mediaPath: "/tmp/demo.m4a", source: "media")

        XCTAssertEqual(segments.map(\.text), ["from fake action"])
        XCTAssertEqual(fake.requests.map(\.mediaPath), ["/tmp/demo.m4a"])
    }

    private func availableAdapter(_ rpcClient: RPCClientMock) -> InsightRuntimeActionRPCAdapter {
        InsightRuntimeActionRPCAdapter(
            rpcClient: rpcClient,
            capabilityProvider: StaticRuntimeActionCapabilityProvider()
        )
    }
}

private final class FakeFinalMediaTranscriptionAction: FinalMediaTranscriptionActioning {
    var requests: [FinalMediaTranscriptionActionRequest] = []
    var outcome: RuntimeActionOutcome<[TranscriptSegment]> = .success([])

    func transcribeFinalMedia(_ request: FinalMediaTranscriptionActionRequest) -> RuntimeActionOutcome<[TranscriptSegment]> {
        requests.append(request)
        return outcome
    }
}
