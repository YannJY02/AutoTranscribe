import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCaptureService: NSObject {
    enum CaptureError: LocalizedError {
        case sourceNotFound
        case noDisplayAvailable
        case unsupportedSource

        var errorDescription: String? {
            switch self {
            case .sourceNotFound:
                return "未找到可用的系统音频源。"
            case .noDisplayAvailable:
                return "未找到可用显示器，无法开始系统音频采集。"
            case .unsupportedSource:
                return "当前选择的系统音频源暂不支持。"
            }
        }
    }

    var onBuffer: ((AVAudioPCMBuffer, TimeInterval?) -> Void)?

    private let outputQueue = DispatchQueue(label: "InsightKit.SystemAudioCapture.Output")
    private let lifecycleQueue = DispatchQueue(label: "InsightKit.SystemAudioCapture.Lifecycle")
    private var captureID: UUID?
    private var stream: SCStream?
    private var output: StreamOutput?

    private var displays: [SCDisplay] = []
    private var windows: [SCWindow] = []
    private var applications: [SCRunningApplication] = []

    func listSources() async throws -> [SystemAudioSourceItem] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        displays = content.displays
        windows = content.windows
        applications = content.applications

        var items: [SystemAudioSourceItem] = []
        for display in displays {
            items.append(
                SystemAudioSourceItem(
                    id: "display:\(display.displayID)",
                    kind: .display,
                    title: "显示器 \(display.displayID)",
                    subtitle: "\(Int(display.width)) x \(Int(display.height))"
                )
            )
        }

        for window in windows.prefix(30) {
            let rawTitle = window.title ?? ""
            let title = rawTitle.isEmpty ? "未命名窗口" : rawTitle
            let owner = window.owningApplication?.applicationName ?? "未知应用"
            items.append(
                SystemAudioSourceItem(
                    id: "window:\(window.windowID)",
                    kind: .window,
                    title: title,
                    subtitle: owner
                )
            )
        }

        for app in applications {
            let bundleID = app.bundleIdentifier
            let subtitle = bundleID.isEmpty ? "pid: \(app.processID)" : bundleID
            items.append(
                SystemAudioSourceItem(
                    id: "app:\(app.processID)",
                    kind: .application,
                    title: app.applicationName,
                    subtitle: subtitle
                )
            )
        }

        return items
    }

    func start(sourceID: String) async throws {
        let captureID = UUID()
        let canStart = lifecycleQueue.sync {
            guard self.captureID == nil else { return false }
            self.captureID = captureID
            return true
        }
        guard canStart else { return }

        do {
            try await startStream(sourceID: sourceID, captureID: captureID)
        } catch {
            lifecycleQueue.sync {
                if self.captureID == captureID {
                    self.captureID = nil
                    self.stream = nil
                    self.output = nil
                }
            }
            throw error
        }
    }

    private func startStream(sourceID: String, captureID: UUID) async throws {

        let filter = try buildFilter(sourceID: sourceID)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.queueDepth = 6
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.excludesCurrentProcessAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let deliverBuffer = onBuffer
        let output = StreamOutput { sampleBuffer in
            Self.handleSampleBuffer(sampleBuffer, deliverBuffer: deliverBuffer)
        }
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
        let isCurrent = lifecycleQueue.sync {
            guard self.captureID == captureID else { return false }
            self.stream = stream
            self.output = output
            return true
        }
        guard isCurrent else {
            try? stream.removeStreamOutput(output, type: .audio)
            throw CancellationError()
        }
        do {
            try await stream.startCapture()
            guard lifecycleQueue.sync(execute: { self.captureID == captureID }) else {
                throw CancellationError()
            }
        } catch {
            try? stream.removeStreamOutput(output, type: .audio)
            try? await stream.stopCapture()
            await drain(output: output)
            throw error
        }
    }

    func stop() async {
        await beginStop().value
    }

    /// Remove source admission synchronously at the user's Stop boundary.
    /// Previously queued callbacks are drained before the returned task completes.
    func beginStop() -> Task<Void, Never> {
        let (stream, output) = lifecycleQueue.sync {
            let captured = (self.stream, self.output)
            captureID = nil
            self.stream = nil
            self.output = nil
            return captured
        }
        if let stream {
            if let output {
                try? stream.removeStreamOutput(output, type: .audio)
            }
        }
        let callbacksDrained = DispatchGroup()
        callbacksDrained.enter()
        outputQueue.async {
            output?.stopDelivery()
            callbacksDrained.leave()
        }
        return Task {
            if let stream { try? await stream.stopCapture() }
            await withCheckedContinuation { continuation in
                callbacksDrained.notify(queue: .global()) { continuation.resume() }
            }
        }
    }

    private func drain(output: StreamOutput?) async {
        await withCheckedContinuation { continuation in
            outputQueue.async {
                output?.stopDelivery()
                continuation.resume()
            }
        }
    }

    private func buildFilter(sourceID: String) throws -> SCContentFilter {
        let comps = sourceID.split(separator: ":", maxSplits: 1).map(String.init)
        guard comps.count == 2 else {
            throw CaptureError.sourceNotFound
        }

        let prefix = comps[0]
        let raw = comps[1]

        switch prefix {
        case "display":
            guard let displayID = UInt32(raw), let display = displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.sourceNotFound
            }
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        case "window":
            guard let wid = Int(raw), let window = windows.first(where: { Int($0.windowID) == wid }) else {
                throw CaptureError.sourceNotFound
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case "app":
            guard let pid = Int32(raw), let app = applications.first(where: { $0.processID == pid }) else {
                throw CaptureError.sourceNotFound
            }

            if let window = windows.first(where: { $0.owningApplication?.processID == app.processID }) {
                return SCContentFilter(desktopIndependentWindow: window)
            }

            guard let display = displays.first else {
                throw CaptureError.noDisplayAvailable
            }
            let excludedApps = applications.filter { $0.processID != app.processID }
            return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        default:
            throw CaptureError.unsupportedSource
        }
    }

    static func handleSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        deliverBuffer: ((AVAudioPCMBuffer, TimeInterval?) -> Void)?
    ) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        if frameCount == 0 {
            return
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            return
        }

        // PTS describes the first sample, independent of callback delivery latency.
        let sourceStartSec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        deliverBuffer?(pcmBuffer, sourceStartSec.isFinite && sourceStartSec >= 0 ? sourceStartSec : nil)
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    private var deliverSampleBuffer: ((CMSampleBuffer) -> Void)?

    init(deliverSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.deliverSampleBuffer = deliverSampleBuffer
        super.init()
    }

    func stopDelivery() { deliverSampleBuffer = nil }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        deliverSampleBuffer?(sampleBuffer)
    }
}
