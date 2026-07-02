import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import QuartzCore
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
        case screenWithCameraOverlay(displayID: UInt32)
    }

    // MARK: - Published State

    @Published var isCapturing = false
    @Published var cameraPermission: PermissionState = .unknown
    @Published var screenPermission: PermissionState = .unknown
    @Published var availableCameras: [VideoDeviceItem] = []
    @Published var availableScreens: [VideoDeviceItem] = []
    @Published var screenPreviewImage: CGImage?
    @Published private(set) var presenterOverlayObserved = false
    @Published private(set) var cameraOverlayVisible = false
    var onRecordingFirstFrame: ((TimeInterval) -> Void)?

    // MARK: - Private State

    private let captureSessionQueue = DispatchQueue(label: "InsightKit.VideoCapture.Session")
    private let videoOutputQueue = DispatchQueue(label: "InsightKit.VideoCapture.VideoOutput")
    private let writerQueue = DispatchQueue(label: "InsightKit.VideoCapture.Writer")

    private var captureSession: AVCaptureSession?
    private(set) var cameraPreviewLayer: AVCaptureVideoPreviewLayer?
    private var cameraOverlayWindow: NSWindow?
    private var cameraOverlayPreviewLayer: AVCaptureVideoPreviewLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var videoOutputDelegate: VideoOutputDelegate?

    // ScreenCaptureKit
    private var scStream: SCStream?
    private var scStreamOutput: SCVideoStreamOutput?
    private var contentSharingPickerObserver: ContentSharingPickerCoordinator?
    private var scDisplays: [SCDisplay] = []
    private var scWindows: [SCWindow] = []
    private let screenPreviewRenderContext = CIContext()
    private var lastScreenPreviewImageAt: CFTimeInterval = 0

    // Recording
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var videoPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingOutputURL: URL?
    private var recordingFallbackSize: CGSize?
    private var recordingFailureMessage: String?
    private var recordingPaused = false
    private var isWriting = false
    private var recordingTimeline: VideoRecordingTimeline?
    private var activeRecordingSize: CGSize?

    private var activeMode: CaptureMode?
    private let cameraOverlayPlacementStore: CameraOverlayPlacementStore
    private var cameraOverlayDisplayID: UInt32?

    init(cameraOverlayPlacementStore: CameraOverlayPlacementStore = CameraOverlayPlacementStore()) {
        self.cameraOverlayPlacementStore = cameraOverlayPlacementStore
        super.init()
    }

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
        layer.videoGravity = .resizeAspect

        captureSession = session
        cameraPreviewLayer = layer
        videoDataOutput = output
        videoOutputDelegate = delegate
        activeMode = .camera(deviceID: deviceID)
        activeRecordingSize = nil

        DispatchQueue.main.async {
            self.screenPreviewImage = nil
        }

        captureSessionQueue.async {
            session.startRunning()
            DispatchQueue.main.async {
                self.isCapturing = true
            }
        }
    }

    func startScreenCapture(displayID: UInt32) async throws {
        try await startScreenCapture(displayID: displayID, usesPresenterOverlayPicker: false)
    }

    func startPresenterOverlayCapture(displayID: UInt32) async throws {
        try await startScreenCapture(displayID: displayID, usesPresenterOverlayPicker: true)
        do {
            try startPresenterOverlayCameraSession()
        } catch {
            stopCapture(waitUntilStopped: true)
            throw error
        }
    }

    func startScreenCaptureWithCameraOverlay(displayID: UInt32) async throws {
        do {
            try startCameraOverlaySession(displayID: displayID)
            try await startScreenCapture(displayID: displayID, usesPresenterOverlayPicker: false)
            activeMode = .screenWithCameraOverlay(displayID: displayID)
        } catch {
            stopCapture(waitUntilStopped: true)
            throw error
        }
    }

    private func startScreenCapture(displayID: UInt32, usesPresenterOverlayPicker: Bool) async throws {
        guard let display = scDisplays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.deviceNotFound
        }
        resetPresenterOverlayObservation()

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        if usesPresenterOverlayPicker {
            config.presenterOverlayPrivacyAlertSetting = .always
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCVideoStreamOutput(owner: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoOutputQueue)
        try await stream.startCapture()

        scStream = stream
        scStreamOutput = output
        activeMode = .screen(displayID: displayID)
        activeRecordingSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        if usesPresenterOverlayPicker {
            configureContentSharingPicker(for: stream)
        }

        DispatchQueue.main.async {
            self.cameraPreviewLayer = nil
            self.screenPreviewImage = nil
            self.isCapturing = true
        }
    }

    func startWindowCapture(windowID: UInt32) async throws {
        guard let window = scWindows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.deviceNotFound
        }
        resetPresenterOverlayObservation()

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCVideoStreamOutput(owner: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoOutputQueue)
        try await stream.startCapture()

        scStream = stream
        scStreamOutput = output
        activeMode = .window(windowID: windowID)
        activeRecordingSize = CGSize(width: CGFloat(config.width), height: CGFloat(config.height))

        DispatchQueue.main.async {
            self.cameraPreviewLayer = nil
            self.screenPreviewImage = nil
            self.isCapturing = true
        }
    }

    private func startPresenterOverlayCameraSession() throws {
        guard cameraPermission == .granted else {
            throw CaptureError.cameraPermissionDenied
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discoverySession.devices.first else {
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

        captureSession = session
        cameraPreviewLayer = nil
        videoDataOutput = output
        videoOutputDelegate = delegate

        captureSessionQueue.async {
            session.startRunning()
            DispatchQueue.main.async {
                self.isCapturing = true
            }
        }
    }

    private func startCameraOverlaySession(displayID: UInt32) throws {
        guard cameraPermission == .granted else {
            throw CaptureError.cameraPermissionDenied
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discoverySession.devices.first else {
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
        session.commitConfiguration()

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))

        showCameraOverlayWindow(previewLayer: previewLayer, displayID: displayID)

        captureSession = session
        cameraPreviewLayer = nil
        cameraOverlayPreviewLayer = previewLayer
        videoDataOutput = nil
        videoOutputDelegate = nil

        captureSessionQueue.async {
            session.startRunning()
            DispatchQueue.main.async {
                self.cameraOverlayVisible = true
                self.isCapturing = true
            }
        }
    }

    func stopCapture(waitUntilStopped: Bool = false) {
        closeCameraOverlayWindow()

        let stopWork = { [weak self] in
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
            self.resetContentSharingPicker()

            self.stopRecording()
            self.activeMode = nil
            self.activeRecordingSize = nil

            DispatchQueue.main.async {
                self.presenterOverlayObserved = false
                self.cameraOverlayVisible = false
                self.screenPreviewImage = nil
                self.isCapturing = false
            }
        }

        if waitUntilStopped {
            captureSessionQueue.sync(execute: stopWork)
        } else {
            captureSessionQueue.async(execute: stopWork)
        }
    }

    // MARK: - Recording (AVAssetWriter)

    func startRecording(to outputURL: URL, width: Int = 1920, height: Int = 1080) throws {
        var startError: Error?
        writerQueue.sync {
            do {
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try FileManager.default.removeItem(at: outputURL)
                }

                self.assetWriter = nil
                self.videoWriterInput = nil
                self.recordingOutputURL = outputURL
                self.recordingFallbackSize = self.activeRecordingSize ?? CGSize(
                    width: CGFloat(width),
                    height: CGFloat(height)
                )
                self.recordingFailureMessage = nil
                self.recordingPaused = false
                self.recordingTimeline = nil
                self.isWriting = true
            } catch {
                startError = error
                self.isWriting = false
                self.recordingFailureMessage = error.localizedDescription
            }
        }
        if let startError {
            throw startError
        }
    }

    func stopRecording() {
        var writerToFinish: AVAssetWriter?
        writerQueue.sync {
            guard isWriting else { return }
            isWriting = false
            recordingPaused = false
            guard let writer = assetWriter else {
                clearWriterState()
                return
            }
            videoWriterInput?.markAsFinished()
            writerToFinish = writer
        }

        guard let writerToFinish else { return }
        writerToFinish.finishWriting { [weak self] in
            self?.writerQueue.async {
                self?.clearWriterState(matching: writerToFinish)
            }
        }
    }

    @discardableResult
    func finishRecording(timeoutSec: TimeInterval = 20) -> URL? {
        var writerToFinish: AVAssetWriter?
        var outputURL: URL?
        var hasVideoFrames = false

        writerQueue.sync {
            guard isWriting else { return }
            isWriting = false
            recordingPaused = false
            outputURL = recordingOutputURL
            guard let writer = assetWriter else {
                clearWriterState()
                return
            }
            hasVideoFrames = recordingTimeline != nil
            writerToFinish = writer
            outputURL = writer.outputURL
            if hasVideoFrames {
                videoWriterInput?.markAsFinished()
            }
        }

        guard let writerToFinish, let outputURL else {
            return nil
        }

        guard hasVideoFrames else {
            writerToFinish.cancelWriting()
            writerQueue.async { [weak self] in
                self?.clearWriterState(matching: writerToFinish)
            }
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        writerToFinish.finishWriting { [weak self] in
            self?.writerQueue.async {
                self?.clearWriterState(matching: writerToFinish)
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeoutSec) == .success else {
            return nil
        }
        guard writerToFinish.status == .completed else {
            recordingFailureMessage = writerToFinish.error?.localizedDescription
            return nil
        }
        guard let values = try? outputURL.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            return nil
        }
        return outputURL
    }

    func pauseRecording(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        writerQueue.sync {
            guard isWriting, !recordingPaused else { return }
            recordingPaused = true
            recordingTimeline?.pause(at: time)
        }
    }

    func resumeRecording(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        writerQueue.sync {
            guard isWriting, recordingPaused else { return }
            recordingTimeline?.resume(at: time)
            recordingPaused = false
        }
    }

    private func clearWriterState(matching writer: AVAssetWriter) {
        guard assetWriter === writer else { return }
        clearWriterState()
    }

    private func clearWriterState() {
        assetWriter = nil
        videoWriterInput = nil
        videoPixelBufferAdaptor = nil
        recordingOutputURL = nil
        recordingFallbackSize = nil
        recordingPaused = false
        recordingTimeline = nil
    }

    // MARK: - Frame Handling

    fileprivate func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, source: VideoSampleSource) {
        if source == .camera {
            guard case .camera = activeMode else { return }
        }
        publishScreenPreviewIfNeeded(sampleBuffer)

        let capturedAt = ProcessInfo.processInfo.systemUptime
        writerQueue.async { [weak self] in
            guard let self, self.isWriting, !self.recordingPaused else { return }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            guard let input = self.ensureWriterStarted(for: sampleBuffer),
                  input.isReadyForMoreMediaData else { return }

            let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if self.recordingTimeline == nil {
                self.recordingTimeline = VideoRecordingTimeline()
                self.assetWriter?.startSession(atSourceTime: .zero)
                self.onRecordingFirstFrame?(capturedAt)
            }
            guard var timeline = self.recordingTimeline else { return }
            let presentationTime = timeline.presentationTime(
                sourcePresentationTime: sourceTimestamp,
                capturedAt: capturedAt
            )
            self.recordingTimeline = timeline

            let didAppend = self.videoPixelBufferAdaptor?.append(
                imageBuffer,
                withPresentationTime: presentationTime
            ) ?? false
            if !didAppend, let error = self.assetWriter?.error {
                self.recordingFailureMessage = error.localizedDescription
            }
        }
    }

    private func ensureWriterStarted(for sampleBuffer: CMSampleBuffer) -> AVAssetWriterInput? {
        if let input = videoWriterInput {
            return input
        }
        guard let outputURL = recordingOutputURL else {
            return nil
        }
        let fallback = recordingFallbackSize ?? CGSize(width: 1920, height: 1080)
        let size = Self.recordingDimensions(for: sampleBuffer, fallback: fallback)
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 5_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: attributes
            )
            guard writer.canAdd(input) else {
                recordingFailureMessage = "Video writer could not add input."
                isWriting = false
                return nil
            }
            writer.add(input)
            guard writer.startWriting() else {
                recordingFailureMessage = writer.error?.localizedDescription
                isWriting = false
                return nil
            }
            assetWriter = writer
            videoWriterInput = input
            videoPixelBufferAdaptor = adaptor
            return input
        } catch {
            recordingFailureMessage = error.localizedDescription
            isWriting = false
            return nil
        }
    }

    static func recordingDimensions(for sampleBuffer: CMSampleBuffer, fallback: CGSize) -> CGSize {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return sanitizedRecordingSize(fallback)
        }
        return sanitizedRecordingSize(CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        ))
    }

    private static func sanitizedRecordingSize(_ size: CGSize) -> CGSize {
        let width = max(2, Int(size.width))
        let height = max(2, Int(size.height))
        return CGSize(
            width: width.isMultiple(of: 2) ? width : width - 1,
            height: height.isMultiple(of: 2) ? height : height - 1
        )
    }

    private func publishScreenPreviewIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        if Self.sampleBufferShowsPresenterOverlay(sampleBuffer) {
            markPresenterOverlayObserved()
        }

        switch activeMode {
        case .screen, .window, .screenWithCameraOverlay:
            break
        case .camera, .none:
            return
        }

        let now = CACurrentMediaTime()
        guard now - lastScreenPreviewImageAt >= 0.12 else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let previewImage = screenPreviewRenderContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }
        lastScreenPreviewImageAt = now

        DispatchQueue.main.async { [weak self] in
            self?.screenPreviewImage = previewImage
        }
    }

    private func markPresenterOverlayObserved() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.presenterOverlayObserved else { return }
            self.presenterOverlayObserved = true
        }
    }

    fileprivate func resetPresenterOverlayObservation() {
        if Thread.isMainThread {
            presenterOverlayObserved = false
        } else {
            DispatchQueue.main.sync {
                presenterOverlayObserved = false
            }
        }
    }

    private func configureContentSharingPicker(for stream: SCStream) {
        let observer = ContentSharingPickerCoordinator(owner: self)
        contentSharingPickerObserver = observer

        DispatchQueue.main.async {
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = [.singleDisplay]
            configuration.allowsChangingSelectedContent = true

            let picker = SCContentSharingPicker.shared
            picker.add(observer)
            picker.defaultConfiguration = configuration
            picker.setConfiguration(configuration, for: stream)
            picker.isActive = true
            picker.present(for: stream)
        }
    }

    private func resetContentSharingPicker() {
        guard let observer = contentSharingPickerObserver else { return }
        contentSharingPickerObserver = nil

        DispatchQueue.main.async {
            let picker = SCContentSharingPicker.shared
            picker.remove(observer)
            picker.isActive = false
        }
    }

    private func showCameraOverlayWindow(previewLayer: AVCaptureVideoPreviewLayer, displayID: UInt32) {
        let work = { [weak self] in
            guard let self else { return }
            self.closeCameraOverlayWindow()

            let visibleFrame = Self.cameraOverlayVisibleFrame(displayID: displayID)
            let frame = self.cameraOverlayPlacementStore.frame(
                for: displayID,
                visibleFrame: visibleFrame
            )
            let contentView = CameraOverlayContainerView(
                frame: NSRect(origin: .zero, size: frame.size),
                previewLayer: previewLayer
            )

            let window = NSPanel(
                contentRect: frame,
                styleMask: [.fullSizeContentView, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.title = "InsightKit Camera Overlay"
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.contentView = contentView
            window.isMovableByWindowBackground = true
            window.minSize = CameraOverlayPlacement.minSize
            window.contentAspectRatio = NSSize(
                width: CameraOverlayPlacement.aspectRatio,
                height: 1
            )
            window.delegate = self
            window.orderFrontRegardless()

            self.cameraOverlayWindow = window
            self.cameraOverlayDisplayID = displayID
            self.cameraOverlayVisible = true
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func closeCameraOverlayWindow() {
        let work = { [weak self] in
            guard let self else { return }
            self.cameraOverlayPreviewLayer?.removeFromSuperlayer()
            self.cameraOverlayPreviewLayer = nil
            self.cameraOverlayWindow?.delegate = nil
            self.cameraOverlayWindow?.close()
            self.cameraOverlayWindow = nil
            self.cameraOverlayDisplayID = nil
            self.cameraOverlayVisible = false
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private static func cameraOverlayVisibleFrame(displayID: UInt32) -> NSRect {
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        } ?? NSScreen.main

        return screen?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1440, height: 900)
    }

    static func sampleBufferShowsPresenterOverlay(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[AnyHashable: Any]] else {
            return false
        }
        let key = AnyHashable(SCStreamFrameInfo.presenterOverlayContentRect)
        return attachments.contains { attachment in
            guard let value = attachment[key] else { return false }
            if let rect = value as? CGRect {
                return !rect.isNull && !rect.isEmpty && rect.width > 0 && rect.height > 0
            }
            if let value = value as? NSValue {
                let rect = value.rectValue
                return !rect.isNull && !rect.isEmpty && rect.width > 0 && rect.height > 0
            }
            return true
        }
    }
}

extension VideoCaptureService: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        persistCameraOverlayFrame(from: notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistCameraOverlayFrame(from: notification)
    }

    private func persistCameraOverlayFrame(from notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === cameraOverlayWindow,
              let displayID = cameraOverlayDisplayID else {
            return
        }
        let visibleFrame = Self.cameraOverlayVisibleFrame(displayID: displayID)
        cameraOverlayPlacementStore.save(
            frame: window.frame,
            displayID: displayID,
            visibleFrame: visibleFrame
        )
    }
}

private final class CameraOverlayContainerView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(frame frameRect: NSRect, previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        previewLayer.frame = bounds
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

struct VideoRecordingTimeline: Equatable {
    private let timescale: CMTimeScale
    private let minimumFrameStep: CMTime
    private(set) var firstHostTimeSec: TimeInterval?
    private(set) var firstSourcePresentationTime: CMTime?
    private(set) var lastSourcePresentationTime: CMTime?
    private(set) var lastPresentationTime: CMTime?
    private(set) var pausedAtSec: TimeInterval?
    private(set) var accumulatedPausedSec: TimeInterval = 0

    init(timescale: CMTimeScale = 600) {
        self.timescale = timescale
        self.minimumFrameStep = CMTime(value: 1, timescale: timescale)
    }

    mutating func presentationTime(
        sourcePresentationTime: CMTime,
        capturedAt: TimeInterval
    ) -> CMTime {
        if firstHostTimeSec == nil {
            firstHostTimeSec = capturedAt
            firstSourcePresentationTime = sourcePresentationTime
        }
        lastSourcePresentationTime = sourcePresentationTime

        let elapsed = max(0, capturedAt - (firstHostTimeSec ?? capturedAt))
        var presentationTime = CMTime(seconds: elapsed, preferredTimescale: timescale)
        if let lastPresentationTime,
           CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            presentationTime = lastPresentationTime + minimumFrameStep
        }
        lastPresentationTime = presentationTime
        return presentationTime
    }

    mutating func pause(at time: TimeInterval) {
        guard firstHostTimeSec != nil, pausedAtSec == nil else { return }
        pausedAtSec = time
    }

    mutating func resume(at time: TimeInterval) {
        guard let pausedAtSec else { return }
        accumulatedPausedSec += max(0, time - pausedAtSec)
        self.pausedAtSec = nil
    }
}

fileprivate enum VideoSampleSource {
    case camera
    case screen
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
        owner?.handleVideoSampleBuffer(sampleBuffer, source: .camera)
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
        owner?.handleVideoSampleBuffer(sampleBuffer, source: .screen)
    }
}

private final class ContentSharingPickerCoordinator: NSObject, SCContentSharingPickerObserver {
    private weak var owner: VideoCaptureService?

    init(owner: VideoCaptureService) {
        self.owner = owner
        super.init()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        owner?.resetPresenterOverlayObservation()
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        guard let stream else { return }
        Task {
            try? await stream.updateContentFilter(filter)
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        owner?.resetPresenterOverlayObservation()
    }
}

extension VideoCaptureService: SCStreamDelegate {
    func outputVideoEffectDidStart(for stream: SCStream) {
        markPresenterOverlayObserved()
    }
}
