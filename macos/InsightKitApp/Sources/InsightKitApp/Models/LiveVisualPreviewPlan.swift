import Foundation
import CoreGraphics

enum LiveVisualPreviewSource: Equatable {
    case none
    case camera
    case screen
    case presenterOverlay
    case screenWithCameraOverlay
}

enum LivePresentationCaptureStatus: String, Codable, Equatable {
    case none
    case cameraOnly
    case screenOnly
    case presenterOverlayCaptured
    case screenPlusCameraCaptured
    case screenOnlyFallback
    case visualMediaUnavailable

    static func resolve(
        cameraEnabled: Bool,
        screenEnabled: Bool,
        presenterOverlayObserved: Bool,
        cameraOverlayCaptured: Bool = false
    ) -> LivePresentationCaptureStatus {
        switch (cameraEnabled, screenEnabled, presenterOverlayObserved, cameraOverlayCaptured) {
        case (true, true, true, _):
            return .presenterOverlayCaptured
        case (true, true, false, true):
            return .screenPlusCameraCaptured
        case (true, true, false, false):
            return .screenOnlyFallback
        case (true, false, _, _):
            return .cameraOnly
        case (false, true, _, _):
            return .screenOnly
        case (false, false, _, _):
            return .none
        }
    }

    func finalized(for recordingURL: URL?) -> LivePresentationCaptureStatus? {
        switch self {
        case .none:
            return nil
        case .cameraOnly, .screenOnly:
            guard recordingURL?.isVideoRecordingURL == true else { return nil }
            return self
        case .presenterOverlayCaptured, .screenPlusCameraCaptured:
            guard recordingURL?.isVideoRecordingURL == true else { return .visualMediaUnavailable }
            return self
        case .screenOnlyFallback:
            guard recordingURL?.isVideoRecordingURL == true else { return .visualMediaUnavailable }
            return self
        case .visualMediaUnavailable:
            return self
        }
    }
}

private extension URL {
    var isVideoRecordingURL: Bool {
        ["mp4", "mov", "mkv", "avi", "webm"].contains(pathExtension.lowercased())
    }
}

struct LiveVisualPreviewPlan: Equatable {
    let source: LiveVisualPreviewSource
    let statusMessage: String?

    static func resolve(cameraEnabled: Bool, screenEnabled: Bool) -> LiveVisualPreviewPlan {
        if cameraEnabled && screenEnabled {
            return LiveVisualPreviewPlan(
                source: .screenWithCameraOverlay,
                statusMessage: "屏幕录制 + 摄像头叠加。保存的 Record 应包含屏幕与摄像头画面。"
            )
        }

        if cameraEnabled {
            return LiveVisualPreviewPlan(
                source: .camera,
                statusMessage: "正在准备摄像头预览..."
            )
        }

        if screenEnabled {
            return LiveVisualPreviewPlan(
                source: .screen,
                statusMessage: "正在准备屏幕预览；若一直没有画面，请确认系统设置已允许 InsightKit 录制屏幕。"
            )
        }

        return LiveVisualPreviewPlan(source: .none, statusMessage: nil)
    }
}

enum LiveVisualPreviewLayout {
    static let aspectRatio: CGFloat = 16.0 / 9.0

    static func previewSize(availableWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard availableWidth > 0, maxHeight > 0 else {
            return .zero
        }
        let width = min(availableWidth, maxHeight * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }
}
