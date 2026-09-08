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
    var onRecordingFailure: ((String) -> Void)?

    // MARK: - Private State

    private let captureSessionQueue: DispatchQueue
    private let captureStateLock = NSLock()
    private var captureLifecycleID = UUID()
    private let videoOutputQueue = DispatchQueue(label: "InsightKit.VideoCapture.VideoOutput")
    private let writerQueue: DispatchQueue
    private let recordingAdmissionLock = NSLock()
    private var recordingAdmissionOpen = false
    private var recordingAdmissionEpoch: UInt64 = 0
    private var recordingAdmissionID: UUID?
    private var latestRecordingID: UUID?
    private var recordingFailureHandler: ((String) -> Void)?
    private var recordingFailureNotificationScheduled = false
    private var recordingAdmissionFailureMessage: String?
    private var retainedRecordingFrameCount = 0
    private var retainedRecordingBytes = 0
    private let recordingBufferLimits: RecordingBufferLimits
    private let writerIsReady: (AVAssetWriterInput) -> Bool

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
    private let screenPreviewPipeline: LatestFramePreviewPipeline<CMSampleBuffer, CGImage>

    // Recording
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var videoPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingOutputURL: URL?
    private var recordingFallbackSize: CGSize?
    private(set) var recordingFailureMessage: String?
    private var recordingPaused = false
    private var isWriting = false
    private var recordingHasAppendedFrame = false
    private var recordingTimeline: VideoRecordingTimeline?
    private var recordingID: UUID?
    private var pendingRecordingFrames: [PendingRecordingFrame] = []
    private var recordingReadinessObservation: NSKeyValueObservation?
    private var recordingFinishRequested = false
    private var recordingIsFinalizing = false
    private var recordingFinishCompletions: [(URL?) -> Void] = []
    private var activeRecordingSize: CGSize?

    private struct PendingRecordingFrame {
        let pixelBuffer: CVPixelBuffer
        let retainedBytes: Int
        let presentationTime: CMTime
        let captureStartTime: TimeInterval
    }

    struct RecordingBufferLimits {
        var maximumFrames = 120
        var maximumBytes = 256 * 1024 * 1024
    }

    var recordingBufferUsage: (frames: Int, bytes: Int) {
        recordingAdmissionLock.withLock { (retainedRecordingFrameCount, retainedRecordingBytes) }
    }

    private var activeMode: CaptureMode?
    private let cameraOverlayPlacementStore: CameraOverlayPlacementStore
    private var cameraOverlayDisplayID: UInt32?

    init(
        cameraOverlayPlacementStore: CameraOverlayPlacementStore = CameraOverlayPlacementStore(),
        writerQueue: DispatchQueue = DispatchQueue(label: "InsightKit.VideoCapture.Writer"),
        captureSessionQueue: DispatchQueue = DispatchQueue(label: "InsightKit.VideoCapture.Session"),
        recordingBufferLimits: RecordingBufferLimits = RecordingBufferLimits(),
        writerIsReady: @escaping (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData }
    ) {
        precondition(recordingBufferLimits.maximumFrames > 0 && recordingBufferLimits.maximumBytes > 0)
        self.cameraOverlayPlacementStore = cameraOverlayPlacementStore
        self.writerQueue = writerQueue
        self.captureSessionQueue = captureSessionQueue
        self.recordingBufferLimits = recordingBufferLimits
        self.writerIsReady = writerIsReady
        let previewRenderer = ScreenPreviewRenderer()
        self.screenPreviewPipeline = LatestFramePreviewPipeline(render: previewRenderer.render)
        super.init()
        screenPreviewPipeline.setImageHandler { [weak self] image in
            self?.screenPreviewImage = image
        }
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

    @MainActor
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

        startCameraSession(session, deviceID: deviceID, previewLayer: layer, output: output)
    }

    @MainActor
    func startCameraSession(
        _ session: AVCaptureSession,
        deviceID: String,
        previewLayer: AVCaptureVideoPreviewLayer? = nil,
        output: AVCaptureVideoDataOutput? = nil
    ) {
        let generation = beginCaptureGeneration()
        captureStateLock.withLock {
            captureSession = session
            cameraPreviewLayer = previewLayer
            videoDataOutput = output
            videoOutputDelegate = output?.sampleBufferDelegate as? VideoOutputDelegate
            activeMode = .camera(deviceID: deviceID)
            activeRecordingSize = nil
        }

        captureSessionQueue.async {
            guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
            session.startRunning()
            DispatchQueue.main.async {
                guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
                self.isCapturing = true
            }
        }
    }

    @MainActor
    func startScreenCapture(displayID: UInt32) async throws {
        let generation = beginCaptureGeneration()
        try await startScreenCapture(
            displayID: displayID, usesPresenterOverlayPicker: false, generation: generation
        )
    }

    @MainActor
    func startPresenterOverlayCapture(displayID: UInt32) async throws {
        let generation = beginCaptureGeneration()
        try await startScreenCapture(
            displayID: displayID, usesPresenterOverlayPicker: true, generation: generation
        )
        guard screenPreviewPipeline.isCurrentGeneration(generation), !Task.isCancelled else {
            throw CancellationError()
        }
        do {
            try startPresenterOverlayCameraSession(generation: generation)
        } catch {
            stopCapture(waitUntilStopped: true)
            throw error
        }
    }

    @MainActor
    func startScreenCaptureWithCameraOverlay(displayID: UInt32) async throws {
        let generation = beginCaptureGeneration()
        try startCameraOverlaySession(displayID: displayID, generation: generation)
        let ownedCameraSession = captureSession
        let ownedOverlayWindow = cameraOverlayWindow
        do {
            try await startScreenCapture(
                displayID: displayID,
                usesPresenterOverlayPicker: false,
                generation: generation,
                usesCameraOverlay: true
            )
        } catch {
            stopOwnedCameraSession(ownedCameraSession, overlayWindow: ownedOverlayWindow)
            throw error
        }
    }

    private func startScreenCapture(
        displayID: UInt32,
        usesPresenterOverlayPicker: Bool,
        generation: UInt64,
        usesCameraOverlay: Bool = false
    ) async throws {
        guard screenPreviewPipeline.isCurrentGeneration(generation), !Task.isCancelled else {
            throw CancellationError()
        }
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
        try await startScreenStream(
            stream,
            generation: generation,
            mode: usesCameraOverlay ? .screenWithCameraOverlay(displayID: displayID) : .screen(displayID: displayID),
            recordingSize: CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        )
        if usesPresenterOverlayPicker {
            configureContentSharingPicker(for: stream, generation: generation)
        }

        DispatchQueue.main.async {
            guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
            self.cameraPreviewLayer = nil
            self.isCapturing = true
        }
    }

    @MainActor
    func startWindowCapture(windowID: UInt32) async throws {
        let generation = beginCaptureGeneration()
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
        try await startScreenStream(
            stream,
            generation: generation,
            mode: .window(windowID: windowID),
            recordingSize: CGSize(width: CGFloat(config.width), height: CGFloat(config.height))
        )

        DispatchQueue.main.async {
            guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
            self.cameraPreviewLayer = nil
            self.isCapturing = true
        }
    }

    private func startScreenStream(
        _ stream: SCStream,
        generation: UInt64,
        mode: CaptureMode,
        recordingSize: CGSize
    ) async throws {
        let output = SCVideoStreamOutput(owner: self, previewGeneration: generation)
        do {
            guard screenPreviewPipeline.isCurrentGeneration(generation), !Task.isCancelled else {
                throw CancellationError()
            }
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoOutputQueue)
            try await stream.startCapture()
            guard !Task.isCancelled else { throw CancellationError() }
            let adopted = captureSessionQueue.sync {
                captureStateLock.withLock {
                    guard screenPreviewPipeline.isCurrentGeneration(generation) else { return false }
                    scStream = stream
                    scStreamOutput = output
                    activeMode = mode
                    activeRecordingSize = recordingSize
                    return true
                }
            }
            guard adopted else { throw CancellationError() }
        } catch {
            try? stream.removeStreamOutput(output, type: .screen)
            try? await stream.stopCapture()
            throw error
        }
    }

    @MainActor
    private func startPresenterOverlayCameraSession(generation: UInt64) throws {
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

        captureStateLock.withLock {
            captureSession = session
            cameraPreviewLayer = nil
            videoDataOutput = output
            videoOutputDelegate = delegate
        }

        captureSessionQueue.async {
            guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
            session.startRunning()
            DispatchQueue.main.async {
                guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
                self.isCapturing = true
            }
        }
    }

    @MainActor
    private func startCameraOverlaySession(displayID: UInt32, generation: UInt64) throws {
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

        captureStateLock.withLock {
            captureSession = session
            cameraPreviewLayer = nil
            cameraOverlayPreviewLayer = previewLayer
            videoDataOutput = nil
            videoOutputDelegate = nil
        }

        captureSessionQueue.async {
            guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
            session.startRunning()
            DispatchQueue.main.async {
                guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
                self.cameraOverlayVisible = true
                self.isCapturing = true
            }
        }
    }

    @MainActor
    private func stopOwnedCameraSession(_ session: AVCaptureSession?, overlayWindow: NSWindow?) {
        if let overlayWindow, cameraOverlayWindow === overlayWindow {
            closeCameraOverlayWindow()
        }
        captureSessionQueue.async { [weak self] in
            session?.stopRunning()
            self?.captureStateLock.withLock {
                if let session, self?.captureSession === session {
                    self?.captureSession = nil
                    self?.cameraPreviewLayer = nil
                    self?.videoDataOutput = nil
                    self?.videoOutputDelegate = nil
                }
            }
        }
    }

    private func beginCaptureGeneration() -> UInt64 {
        captureStateLock.withLock { captureLifecycleID = UUID() }
        return screenPreviewPipeline.beginGeneration()
    }

    func stopCapture(waitUntilStopped: Bool = false) {
        screenPreviewPipeline.invalidate()
        closeCameraOverlayWindow()
        // Detach this capture before returning. Delayed teardown must never look
        // up mutable service properties belonging to a later capture.
        let owned = captureStateLock.withLock {
            captureLifecycleID = UUID()
            let resources = (captureSession, scStream, scStreamOutput, contentSharingPickerObserver, captureLifecycleID)
            captureSession = nil
            cameraPreviewLayer = nil
            videoDataOutput = nil
            videoOutputDelegate = nil
            scStream = nil
            scStreamOutput = nil
            contentSharingPickerObserver = nil
            activeMode = nil
            activeRecordingSize = nil
            return resources
        }
        stopRecording()
        resetContentSharingPicker(ownedObserver: owned.3, lifecycleID: owned.4)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.captureStateLock.withLock({ self.captureLifecycleID == owned.4 }) else { return }
            self.presenterOverlayObserved = false
            self.cameraOverlayVisible = false
            self.isCapturing = false
        }
        let stopWork = {
            owned.0?.stopRunning()
            if let stream = owned.1 {
                if let output = owned.2 {
                    try? stream.removeStreamOutput(output, type: .screen)
                }
                Task { try? await stream.stopCapture() }
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
        let recordingID = UUID()
        let admissionEpoch = recordingAdmissionLock.withLock {
            recordingAdmissionEpoch &+= 1
            recordingAdmissionOpen = false
            recordingAdmissionID = recordingID
            latestRecordingID = recordingID
            recordingFailureHandler = onRecordingFailure
            recordingFailureNotificationScheduled = false
            recordingAdmissionFailureMessage = nil
            retainedRecordingFrameCount = 0
            retainedRecordingBytes = 0
            return recordingAdmissionEpoch
        }
        var startError: Error?
        writerQueue.sync {
            guard self.recordingAdmissionLock.withLock({ self.recordingAdmissionEpoch == admissionEpoch }) else {
                startError = CaptureError.sessionConfigFailed("视频录制启动已取消")
                return
            }
            do {
                if let previousID = self.recordingID {
                    self.failRecording(matching: previousID, message: "Video recording was replaced before finalization completed.")
                }
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
                self.recordingHasAppendedFrame = false
                self.recordingID = recordingID
                self.isWriting = true
            } catch {
                startError = error
                self.isWriting = false
                self.recordingFailureMessage = error.localizedDescription
            }
        }
        recordingAdmissionLock.withLock {
            if recordingAdmissionEpoch == admissionEpoch {
                recordingAdmissionOpen = startError == nil
            } else if startError == nil {
                startError = CaptureError.sessionConfigFailed("视频录制启动已取消")
            }
        }
        if let startError {
            throw startError
        }
    }

    func stopRecording() {
        beginFinishRecording(timeoutSec: 20, completion: { _ in })
    }

    /// Admission closes before this call returns. Only the already admitted writer
    /// work is drained; awaiting the result never blocks the caller's UI thread.
    func beginFinishRecording(timeoutSec: TimeInterval = 20) -> Task<URL?, Never> {
        let (results, continuation) = AsyncStream<URL?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        beginFinishRecording(timeoutSec: timeoutSec) { url in
            continuation.yield(url)
            continuation.finish()
        }
        return Task {
            var iterator = results.makeAsyncIterator()
            return await iterator.next() ?? nil
        }
    }

    /// Compatibility for synchronous callers. Live Session Finalization uses
    /// beginFinishRecording so encoding and file finalization stay off main.
    @discardableResult
    func finishRecording(timeoutSec: TimeInterval = 20) -> URL? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: URL?
        beginFinishRecording(timeoutSec: timeoutSec) { url in
            result = url
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + max(0, timeoutSec)) == .success else { return nil }
        return result
    }

    private func beginFinishRecording(timeoutSec: TimeInterval, completion: @escaping (URL?) -> Void) {
        let completionLock = NSLock()
        var completed = false
        let claimCompletion: () -> Bool = {
            completionLock.withLock {
                guard !completed else { return false }
                completed = true
                return true
            }
        }
        recordingAdmissionLock.withLock {
            let recordingID = recordingAdmissionID
            recordingAdmissionOpen = false
            recordingAdmissionEpoch &+= 1
            let timeout = DispatchWorkItem { [weak self] in
                guard claimCompletion() else { return }
                self?.writerQueue.async { [weak self] in
                    self?.failRecording(matching: recordingID, message: "Video recording finalization timed out.")
                }
                completion(nil)
            }
            // Admission and enqueue share a lock, so the finish barrier follows
            // every accepted frame and no post-Stop frame can get behind it.
            writerQueue.async { [self] in
                self.finishAdmittedRecording(matching: recordingID) { url in
                    timeout.cancel()
                    if claimCompletion() { completion(url) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeoutSec), execute: timeout)
        }
    }

    /// Runs on writerQueue, after the last admitted sample buffer.
    private func finishAdmittedRecording(matching recordingID: UUID?, completion: @escaping (URL?) -> Void) {
        guard let recordingID, self.recordingID == recordingID else {
            completion(nil)
            return
        }
        recordingFinishCompletions.append(completion)
        guard !recordingIsFinalizing else { return }
        recordingFinishRequested = true
        drainPendingRecordingFrames()
    }

    private func finishDrainedRecording(writer: AVAssetWriter) {
        guard recordingHasAppendedFrame else {
            writer.cancelWriting()
            completeRecording(result: nil)
            return
        }
        isWriting = false
        recordingIsFinalizing = true
        recordingReadinessObservation?.invalidate()
        recordingReadinessObservation = nil
        videoWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            let result: URL?
            if writer.status == .completed,
               let values = try? writer.outputURL.resourceValues(forKeys: [.fileSizeKey]),
               (values.fileSize ?? 0) > 0 {
                result = writer.outputURL
            } else {
                result = nil
            }
            self?.writerQueue.async { [weak self] in
                guard let self, self.assetWriter === writer else { return }
                self.completeRecording(
                    result: result,
                    failureMessage: result == nil
                        ? writer.error?.localizedDescription ?? "Video writer did not complete the recording."
                        : nil
                )
            }
        }
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

    private func failRecording(matching recordingID: UUID?, message: String) {
        guard let recordingID, self.recordingID == recordingID else { return }
        let failureMessage = recordingAdmissionLock.withLock {
            latestRecordingID == recordingID ? recordingAdmissionFailureMessage ?? message : message
        }
        recordingReadinessObservation?.invalidate()
        recordingReadinessObservation = nil
        if let writer = assetWriter, writer.status == .writing || writer.status == .unknown {
            writer.cancelWriting()
        }
        completeRecording(result: nil, failureMessage: failureMessage)
    }

    private func completeRecording(result: URL?, failureMessage: String? = nil) {
        let completions = recordingFinishCompletions
        let completedID = recordingID
        if let failureMessage { recordingFailureMessage = failureMessage }
        clearWriterState()
        if let failureMessage { notifyRecordingFailure(matching: completedID, message: failureMessage) }
        for completion in completions { completion(result) }
    }

    private func notifyRecordingFailure(matching recordingID: UUID?, message: String) {
        let handler: ((String) -> Void)? = recordingAdmissionLock.withLock {
            guard let recordingID, latestRecordingID == recordingID,
                  !recordingFailureNotificationScheduled else { return nil }
            recordingFailureNotificationScheduled = true
            return recordingFailureHandler
        }
        guard let handler else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingAdmissionLock.withLock({ self.latestRecordingID == recordingID }) else { return }
            handler(message)
        }
    }

    private func clearWriterState() {
        recordingAdmissionLock.withLock {
            if recordingAdmissionID == recordingID {
                recordingAdmissionOpen = false
                recordingAdmissionID = nil
                retainedRecordingFrameCount = 0
                retainedRecordingBytes = 0
            }
        }
        recordingReadinessObservation?.invalidate()
        recordingReadinessObservation = nil
        pendingRecordingFrames.removeAll()
        recordingFinishCompletions.removeAll()
        recordingID = nil
        recordingFinishRequested = false
        recordingIsFinalizing = false
        isWriting = false
        assetWriter = nil
        videoWriterInput = nil
        videoPixelBufferAdaptor = nil
        recordingOutputURL = nil
        recordingFallbackSize = nil
        recordingPaused = false
        recordingTimeline = nil
        recordingHasAppendedFrame = false
    }

    // MARK: - Frame Handling

    fileprivate func handleVideoSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        source: VideoSampleSource,
        previewGeneration: UInt64? = nil
    ) {
        let capturedAt = ProcessInfo.processInfo.systemUptime
        if source == .camera {
            guard case .camera = activeMode else { return }
        } else {
            guard let previewGeneration,
                  screenPreviewPipeline.isCurrentGeneration(previewGeneration) else { return }
        }

        // Recording retains the original sample and source PTS. Preview conversion
        // runs independently and can replace intermediate frames under UI pressure.
        enqueueRecordingSampleBuffer(sampleBuffer, capturedAt: capturedAt)

        if let previewGeneration {
            publishScreenPreviewIfNeeded(sampleBuffer, generation: previewGeneration)
        }
    }

    func enqueueRecordingSampleBuffer(_ sampleBuffer: CMSampleBuffer, capturedAt: TimeInterval) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let retainedBytes = max(1, CVPixelBufferGetDataSize(pixels))
        var rejectedRecordingID: UUID?
        let capacityFailure = "Video recording stopped because the encoder could not keep up within the recording buffer limit."
        recordingAdmissionLock.withLock {
            guard recordingAdmissionOpen, let recordingID = recordingAdmissionID else { return }
            // Reserve before enqueueing: queued closures retain full sample buffers
            // too, so limiting only pendingRecordingFrames would still be unbounded.
            guard retainedRecordingFrameCount < recordingBufferLimits.maximumFrames,
                  retainedBytes <= recordingBufferLimits.maximumBytes - retainedRecordingBytes else {
                recordingAdmissionOpen = false
                recordingAdmissionFailureMessage = capacityFailure
                rejectedRecordingID = recordingID
                writerQueue.async { [weak self] in
                    self?.failRecording(matching: recordingID, message: capacityFailure)
                }
                return
            }
            retainedRecordingFrameCount += 1
            self.retainedRecordingBytes += retainedBytes
            writerQueue.async { [weak self] in
                guard let self, self.recordingID == recordingID else { return }
                if !self.appendAdmittedRecordingSampleBuffer(
                    sampleBuffer, capturedAt: capturedAt, retainedBytes: retainedBytes
                ) {
                    self.releaseRecordingBuffer(frames: 1, bytes: retainedBytes, matching: recordingID)
                }
            }
        }
        // Notify without waiting for a stalled writer queue, and outside its locks.
        if let rejectedRecordingID {
            notifyRecordingFailure(matching: rejectedRecordingID, message: capacityFailure)
        }
    }

    private func releaseRecordingBuffer(frames: Int, bytes: Int, matching recordingID: UUID?) {
        recordingAdmissionLock.withLock {
            guard let recordingID, recordingAdmissionID == recordingID else { return }
            retainedRecordingFrameCount -= frames
            retainedRecordingBytes -= bytes
        }
    }

    private func appendAdmittedRecordingSampleBuffer(
        _ sampleBuffer: CMSampleBuffer, capturedAt: TimeInterval, retainedBytes: Int
    ) -> Bool {
        guard isWriting, !recordingPaused else { return false }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        guard ensureWriterStarted(for: sampleBuffer) != nil, let writer = assetWriter else {
            failRecording(matching: recordingID, message: recordingFailureMessage ?? "Video writer could not start.")
            return false
        }
        guard writer.status == .writing else {
            failRecording(matching: recordingID, message: writer.error?.localizedDescription ?? "Video writer is no longer writing.")
            return false
        }

        let sourceTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if recordingTimeline == nil {
            recordingTimeline = VideoRecordingTimeline()
            writer.startSession(atSourceTime: .zero)
        }
        guard var timeline = recordingTimeline else { return false }
        let presentationTime = timeline.presentationTime(
            sourcePresentationTime: sourceTimestamp,
            capturedAt: capturedAt
        )
        recordingTimeline = timeline
        // Prepare timing in admission order. A later pause must not invalidate
        // pre-pause frames that are waiting for encoder readiness.
        pendingRecordingFrames.append(PendingRecordingFrame(
            pixelBuffer: imageBuffer,
            retainedBytes: retainedBytes,
            presentationTime: presentationTime,
            captureStartTime: VideoRecordingTimeline.captureStartTime(
                sourcePresentationTime: sourceTimestamp,
                capturedAt: capturedAt
            )
        ))
        drainPendingRecordingFrames()
        return true
    }

    private func drainPendingRecordingFrames() {
        guard isWriting, !recordingIsFinalizing else { return }
        guard let writer = assetWriter, let input = videoWriterInput,
              let adaptor = videoPixelBufferAdaptor else {
            if recordingFinishRequested { completeRecording(result: nil) }
            return
        }
        guard writer.status == .writing else {
            failRecording(matching: recordingID, message: writer.error?.localizedDescription ?? "Video writer is no longer writing.")
            return
        }
        var appendedCount = 0
        var appendedBytes = 0
        while appendedCount < pendingRecordingFrames.count, writerIsReady(input) {
            let frame = pendingRecordingFrames[appendedCount]
            guard adaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime) else {
                failRecording(matching: recordingID, message: writer.error?.localizedDescription ?? "Video writer rejected an admitted frame.")
                return
            }
            appendedCount += 1
            appendedBytes += frame.retainedBytes
            if !recordingHasAppendedFrame {
                recordingHasAppendedFrame = true
                onRecordingFirstFrame?(frame.captureStartTime)
            }
        }
        if appendedCount > 0 {
            pendingRecordingFrames.removeFirst(appendedCount)
            releaseRecordingBuffer(frames: appendedCount, bytes: appendedBytes, matching: recordingID)
        }
        if recordingFinishRequested, pendingRecordingFrames.isEmpty {
            finishDrainedRecording(writer: writer)
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
            recordingReadinessObservation = input.observe(\.isReadyForMoreMediaData, options: [.new]) {
                [weak self, weak writer] observedInput, _ in
                self?.writerQueue.async { [weak self, weak writer, weak input = observedInput] in
                    guard let self, let writer, let input,
                          self.assetWriter === writer, self.videoWriterInput === input else { return }
                    self.drainPendingRecordingFrames()
                }
            }
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

    private func publishScreenPreviewIfNeeded(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        if Self.sampleBufferShowsPresenterOverlay(sampleBuffer) {
            markPresenterOverlayObserved()
        }
        screenPreviewPipeline.submit(sampleBuffer, generation: generation)
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

    private func configureContentSharingPicker(for stream: SCStream, generation: UInt64) {
        let observer = ContentSharingPickerCoordinator(owner: self)
        let adopted = captureSessionQueue.sync {
            captureStateLock.withLock {
                guard screenPreviewPipeline.isCurrentGeneration(generation) else { return false }
                contentSharingPickerObserver = observer
                return true
            }
        }
        guard adopted else { return }

        DispatchQueue.main.async {
            guard self.screenPreviewPipeline.isCurrentGeneration(generation) else { return }
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

    private func resetContentSharingPicker(
        ownedObserver observer: ContentSharingPickerCoordinator?, lifecycleID: UUID
    ) {
        guard let observer else { return }
        DispatchQueue.main.async {
            let picker = SCContentSharingPicker.shared
            picker.remove(observer)
            if self.captureStateLock.withLock({ self.captureLifecycleID == lifecycleID }) {
                picker.isActive = false
            }
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

    static func captureStartTime(
        sourcePresentationTime: CMTime,
        capturedAt: TimeInterval
    ) -> TimeInterval {
        let sourceTime = CMTimeGetSeconds(sourcePresentationTime)
        return sourceTime.isFinite && sourceTime >= 0 ? sourceTime : capturedAt
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

        let hostElapsed = max(0, capturedAt - (firstHostTimeSec ?? capturedAt))
        let sourceElapsed = firstSourcePresentationTime.map {
            CMTimeGetSeconds(sourcePresentationTime - $0)
        }
        let elapsed = sourceElapsed?.isFinite == true
            ? max(0, sourceElapsed ?? 0)
            : hostElapsed
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
    private let previewGeneration: UInt64

    init(owner: VideoCaptureService, previewGeneration: UInt64) {
        self.owner = owner
        self.previewGeneration = previewGeneration
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        owner?.handleVideoSampleBuffer(sampleBuffer, source: .screen, previewGeneration: previewGeneration)
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
