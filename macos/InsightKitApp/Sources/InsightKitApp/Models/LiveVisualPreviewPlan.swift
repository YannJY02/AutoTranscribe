import Foundation
import CoreGraphics

enum LiveVisualPreviewSource: Equatable {
    case none
    case camera
    case screen
}

struct LiveVisualPreviewPlan: Equatable {
    let source: LiveVisualPreviewSource
    let statusMessage: String?

    static func resolve(cameraEnabled: Bool, screenEnabled: Bool) -> LiveVisualPreviewPlan {
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
