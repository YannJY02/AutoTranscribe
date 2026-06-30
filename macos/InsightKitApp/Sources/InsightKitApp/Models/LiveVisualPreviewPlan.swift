import Foundation
import CoreGraphics

enum LiveVisualPreviewSource: Equatable {
    case none
    case camera
    case screen
    case presenterOverlay
}

enum LivePresentationCaptureStatus: String, Codable, Equatable {
    case none
    case cameraOnly
    case screenOnly
    case presenterOverlayCaptured
    case screenOnlyFallback

    static func resolve(
        cameraEnabled: Bool,
        screenEnabled: Bool,
        presenterOverlayObserved: Bool
    ) -> LivePresentationCaptureStatus {
        switch (cameraEnabled, screenEnabled, presenterOverlayObserved) {
        case (true, true, true):
            return .presenterOverlayCaptured
        case (true, true, false):
            return .screenOnlyFallback
        case (true, false, _):
            return .cameraOnly
        case (false, true, _):
            return .screenOnly
        case (false, false, _):
            return .none
        }
    }
}

struct LiveVisualPreviewPlan: Equatable {
    let source: LiveVisualPreviewSource
    let statusMessage: String?

    static func resolve(cameraEnabled: Bool, screenEnabled: Bool) -> LiveVisualPreviewPlan {
        if cameraEnabled && screenEnabled {
            return LiveVisualPreviewPlan(
                source: .presenterOverlay,
                statusMessage: "屏幕录制 + Presenter Overlay。请在 macOS 视频效果菜单中确认演示者叠加；如果未开启，本次 Record 将仅包含屏幕。"
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
