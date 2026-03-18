import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Video Device Model

struct VideoDeviceItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case camera
        case screen
        case window
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
}

// MARK: - Video Capture Service

final class VideoCaptureService: NSObject, ObservableObject {
    enum CaptureError: LocalizedError {
        case cameraPermissionDenied
        case screenPermissionDenied
        case deviceNotFound
        case sessionConfigFailed(String)
        case writerSetupFailed(String)

        var errorDescription: String? {
            switch self {
            case .cameraPermissionDenied:
                return "摄像头权限未授权。请在系统设置中开启。"
            case .screenPermissionDenied:
                return "屏幕录制权限未授权。请在系统设置中开启。"
            case .deviceNotFound:
                return "未找到指定的视频设备。"
            case .sessionConfigFailed(let msg):
                return "视频采集配置失败：\(msg)"
            case .writerSetupFailed(let msg):
                return "录制写入器配置失败：\(msg)"
            }
        }
    }

    enum CaptureMode: Equatable {
        case camera(deviceID: String)
        case screen(displayID: UInt32)
        case window(windowID: UInt32)
    }

    // MARK: - Published State

    @Published var isCapturing = false
    @Published var cameraPermission: PermissionState = .unknown
    @Published var screenPermission: PermissionState = .unknown
    @Published var availableCameras: [VideoDeviceItem] = []
    @Published var availableScreens: [VideoDeviceItem] = []

    // MARK: - Private State

    private let captureSessionQueue = DispatchQueue(label: "InsightKit.VideoCapture.Session")
    private let videoOutputQueue = DispatchQueue(label: "InsightKit.VideoCapture.VideoOutput")
    private let writerQueue = DispatchQueue(label: "InsightKit.VideoCapture.Writer")

    private var captureSession: AVCaptureSession?
    private(set) var cameraPreviewLayer: AVCaptureVideoPreviewLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var videoOutputDelegate: VideoOutputDelegate?

    // ScreenCaptureKit
    private var scStream: SCStream?
    private var scStreamOutput: SCVideoStreamOutput?
    private var scDisplays: [SCDisplay] = []
    private var scWindows: [SCWindow] = []

    // Recording
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var isWriting = false
    private var recordingStartTime: CMTime?

    private var activeMode: CaptureMode?

    // MARK: - Device Enumeration

    func enumerateCameras() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let items = discoverySession.devices.map { device in
            VideoDeviceItem(
                id: "camera:\(device.uniqueID)",
                kind: .camera,
                title: device.localizedName,
                subtitle: device.manufacturer
            )
        }
        DispatchQueue.main.async {
            self.availableCameras = items
        }
    }

    func enumerateScreens() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            scDisplays = content.displays
            scWindows = content.windows

            var items: [VideoDeviceItem] = []
            for display in content.displays {
                items.append(VideoDeviceItem(
                    id: "screen:\(display.displayID)",
                    kind: .screen,
                    title: "显示器 \(display.displayID)",
                    subtitle: "\(Int(display.width)) × \(Int(display.height))"
                ))
            }
            for window in content.windows.prefix(20) {
                let title = (window.title ?? "").isEmpty ? "未命名窗口" : window.title!
                let owner = window.owningApplication?.applicationName ?? "未知"
                items.append(VideoDeviceItem(
                    id: "window:\(window.windowID)",
                    kind: .window,
                    title: title,
                    subtitle: owner
                ))
            }
            DispatchQueue.main.async {
                self.availableScreens = items
                self.screenPermission = .granted
            }
        } catch {
            DispatchQueue.main.async {
                self.screenPermission = .denied
            }
        }
    }

    // MARK: - Permission Handling

    func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermission = .granted
        case .denied, .restricted:
            cameraPermission = .denied
        case .notDetermined:
            cameraPermission = .unknown
        @unknown default:
            cameraPermission = .unknown
        }
    }

    func requestCameraPermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        DispatchQueue.main.async {
            self.cameraPermission = granted ? .granted : .denied
        }
        return granted
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Start / Stop Capture

    func startCamera(deviceID: String) throws {
        guard cameraPermission == .granted else {
            throw CaptureError.cameraPermissionDenied
        }

        let realID = deviceID.hasPrefix("camera:") ? String(deviceID.dropFirst(7)) : deviceID
        guard let device = AVCaptureDevice(uniqueID: realID) else {
            throw CaptureError.deviceNotFound
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            throw CaptureError.sessionConfigFailed("无法添加摄像头输入")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let delegate = VideoOutputDelegate(owner: self)
        output.setSampleBufferDelegate(delegate, queue: videoOutputQueue)
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else {
            throw CaptureError.sessionConfigFailed("无法添加视频输出")
        }
        session.addOutput(output)
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill

        captureSession = session
        cameraPreviewLayer = layer
        videoDataOutput = output
        videoOutputDelegate = delegate
        activeMode = .camera(deviceID: deviceID)

        captureSessionQueue.async {
            session.startRunning()
            DispatchQueue.main.async {
                self.isCapturing = true
            }
        }
    }

    func startScreenCapture(displayID: UInt32) async throws {
        guard let display = scDisplays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.deviceNotFound
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = SCVideoStreamOutput(owner: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoOutputQueue)
        try await stream.startCapture()

        scStream = stream
        scStreamOutput = output
        activeMode = .screen(displayID: displayID)

        DispatchQueue.main.async {
            self.isCapturing = true
        }
    }

    func startWindowCapture(windowID: UInt32) async throws {
        guard let window = scWindows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.deviceNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = SCVideoStreamOutput(owner: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoOutputQueue)
        try await stream.startCapture()

        scStream = stream
        scStreamOutput = output
        activeMode = .window(windowID: windowID)

        DispatchQueue.main.async {
            self.isCapturing = true
        }
    }

    func stopCapture() {
        captureSessionQueue.async { [weak self] in
            guard let self else { return }

            // Stop camera
            if let session = self.captureSession {
                session.stopRunning()
            }
            self.captureSession = nil
            self.cameraPreviewLayer = nil
            self.videoDataOutput = nil
            self.videoOutputDelegate = nil

            // Stop screen capture
            if let stream = self.scStream {
                if let output = self.scStreamOutput {
                    try? stream.removeStreamOutput(output, type: .screen)
                }
                // SCStream.stopCapture is async, fire-and-forget here
                Task { try? await stream.stopCapture() }
            }
            self.scStream = nil
            self.scStreamOutput = nil

            self.stopRecording()
            self.activeMode = nil

            DispatchQueue.main.async {
                self.isCapturing = false
            }
        }
    }

    // MARK: - Recording (AVAssetWriter)

    func startRecording(to outputURL: URL, width: Int = 1920, height: Int = 1080) throws {
        writerQueue.sync {
            do {
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }

                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 5_000_000,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    ],
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                input.expectsMediaDataInRealTime = true

                guard writer.canAdd(input) else {
                    return
                }
                writer.add(input)
                writer.startWriting()

                self.assetWriter = writer
                self.videoWriterInput = input
                self.recordingStartTime = nil
                self.isWriting = true
            } catch {
                self.isWriting = false
            }
        }
    }

    func stopRecording() {
        writerQueue.sync {
            guard isWriting else { return }
            isWriting = false
            videoWriterInput?.markAsFinished()
            assetWriter?.finishWriting { [weak self] in
                self?.assetWriter = nil
                self?.videoWriterInput = nil
                self?.recordingStartTime = nil
            }
        }
    }

    // MARK: - Frame Handling

    fileprivate func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting else { return }
        writerQueue.async { [weak self] in
            guard let self, self.isWriting else { return }
            guard let input = self.videoWriterInput, input.isReadyForMoreMediaData else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if self.recordingStartTime == nil {
                self.recordingStartTime = timestamp
                self.assetWriter?.startSession(atSourceTime: timestamp)
            }
            input.append(sampleBuffer)
        }
    }
}

// MARK: - CapturePreviewProvider Conformance

extension VideoCaptureService: CapturePreviewProvider {
    var previewLayer: Any? {
        cameraPreviewLayer
    }
}

// MARK: - Camera Video Output Delegate

private final class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private weak var owner: VideoCaptureService?

    init(owner: VideoCaptureService) {
        self.owner = owner
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        owner?.handleVideoSampleBuffer(sampleBuffer)
    }
}

// MARK: - ScreenCaptureKit Video Output

private final class SCVideoStreamOutput: NSObject, SCStreamOutput {
    private weak var owner: VideoCaptureService?

    init(owner: VideoCaptureService) {
        self.owner = owner
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        owner?.handleVideoSampleBuffer(sampleBuffer)
    }
}
