import CoreML
import FluidAudio
import Foundation
import LiveDiarizationCore

final class LocalLSEENDEngine: DiarizationEngine {
    private var diarizer: LSEENDDiarizer?

    init(request: WorkerRequest) throws {
        let modelURL = try Self.modelURL(request: request)
        // Direct local loading is deliberate: the worker never downloads weights.
        let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
        guard model.metadata.frameDurationSeconds.isFinite,
            model.metadata.frameDurationSeconds > 0, model.metadata.frameDurationSeconds <= 1,
            model.metadata.maxSpeakers > 0, model.metadata.maxSpeakers <= 32
        else { throw WorkerFailure("invalid_model", "Unsupported LS-EEND model metadata") }
        var config = DiarizerTimelineConfig.default(
            numSpeakers: model.metadata.maxSpeakers,
            frameDurationSeconds: model.metadata.frameDurationSeconds
        )
        config.maxStoredFrames = 512
        config.storeSegments = true
        diarizer = try LSEENDDiarizer(model: model, timelineConfig: config)
    }

    func append(_ samples: [Float]) throws {
        guard let diarizer else { throw WorkerFailure("session_not_found", "The model session is closed") }
        try diarizer.addAudio(samples, sourceSampleRate: 16_000)
        _ = try diarizer.process()
    }

    func finish() throws {
        guard let diarizer else { throw WorkerFailure("session_not_found", "The model session is closed") }
        _ = try diarizer.finalizeSession()
    }

    func snapshot() throws -> DiarizationSnapshot {
        guard let diarizer else { throw WorkerFailure("session_not_found", "The model session is closed") }
        return Self.snapshot(timeline: diarizer.timeline)
    }

    static func snapshot(timeline: DiarizerTimeline) -> DiarizationSnapshot {
        let frameDurationMS = Double(timeline.config.frameDurationSeconds) * 1_000
        let finalizedFrame = timeline.numFinalizedFrames
        let spans = timeline.speakers.values.flatMap { speaker in
            // FluidAudio keeps an open speech segment in tentativeSegments even
            // when its frames are finalized. Include that stable prefix while
            // excluding any right-context frames beyond the finalized cursor.
            (speaker.finalizedSegments + speaker.tentativeSegments).compactMap { segment -> SpeakerSpan? in
                let endFrame = min(segment.endFrame, finalizedFrame)
                guard endFrame > segment.startFrame else { return nil }
                return SpeakerSpan(
                    startMS: Int((Double(segment.startFrame) * frameDurationMS).rounded()),
                    endMS: Int((Double(endFrame) * frameDurationMS).rounded()),
                    speaker: String(format: "SPEAKER_%02d", segment.speakerIndex)
                )
            }
        }
        return DiarizationSnapshot(
            spans: spans,
            finalizedUntilMS: Int((Double(finalizedFrame) * frameDurationMS).rounded())
        )
    }

    func cleanup() {
        diarizer?.cleanup()
        diarizer = nil
    }

    private static func modelURL(request: WorkerRequest) throws -> URL {
        let aliases = ["dihard3": "dih3", "dih3": "dih3", "dihard2": "dih2", "dih2": "dih2", "ami": "ami", "callhome": "ch", "ch": "ch"]
        let variant = (request.variant ?? "dihard3").lowercased()
        guard let directory = aliases[variant] else {
            throw WorkerFailure("invalid_variant", "Supported variants are dihard3, dihard2, ami and callhome")
        }
        let environmentPath = ProcessInfo.processInfo.environment["INSIGHTKIT_LSEEND_MODEL_PATH"]
        if let path = request.modelPath ?? environmentPath, !path.isEmpty {
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096 else {
                throw WorkerFailure("invalid_model_path", "model_path must be an absolute local .mlmodelc directory")
            }
            let url = URL(fileURLWithPath: path)
            guard isCompiledModel(url) else {
                throw WorkerFailure("model_not_found", "The configured local .mlmodelc directory does not exist")
            }
            return url
        }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let name = "ls_eend_\(directory)_500ms.mlmodelc"
        let candidates = [
            "FluidAudio/Models/ls-eend/\(directory)/optimized/\(directory)/500ms/\(name)",
            "FluidAudio/Models/ls-eend/optimized/\(directory)/500ms/\(name)",
            "FluidAudio/Models/ls-eend/\(directory)/500ms/\(name)",
            "InsightKit/models/ls-eend/\(directory)/500ms/\(name)",
        ].map { support.appendingPathComponent($0) }
        guard let url = candidates.first(where: isCompiledModel) else {
            throw WorkerFailure("model_not_found", "No cached LS-EEND \(variant) 500ms model; set INSIGHTKIT_LSEEND_MODEL_PATH to an existing .mlmodelc directory")
        }
        return url
    }

    private static func isCompiledModel(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return url.pathExtension.lowercased() == "mlmodelc"
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
