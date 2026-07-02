import AppKit
import Foundation

struct CameraOverlayPlacement: Codable, Equatable {
    static let aspectRatio: CGFloat = 4.0 / 3.0
    static let minSize = NSSize(width: 160, height: 120)
    static let defaultMargin: CGFloat = 32

    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(frame: NSRect) {
        x = frame.minX
        y = frame.minY
        width = frame.width
        height = frame.height
    }

    var frame: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }

    static func defaultFrame(in visibleFrame: NSRect) -> NSRect {
        let width = min(max(visibleFrame.width * 0.16, 240), 360)
        let height = width / aspectRatio
        return clamped(
            NSRect(
                x: visibleFrame.minX + defaultMargin,
                y: visibleFrame.minY + defaultMargin,
                width: width,
                height: height
            ),
            in: visibleFrame
        )
    }

    static func clamped(_ frame: NSRect, in visibleFrame: NSRect) -> NSRect {
        let maxWidth = max(minSize.width, visibleFrame.width)
        let maxHeight = max(minSize.height, visibleFrame.height)
        let width = min(max(frame.width, minSize.width), maxWidth)
        let height = min(max(frame.height, minSize.height), maxHeight)
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - height)
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

final class CameraOverlayPlacementStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "insightkit.cameraOverlay.frame"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func frame(for displayID: UInt32, visibleFrame: NSRect) -> NSRect {
        guard let data = defaults.data(forKey: key(for: displayID)),
              let placement = try? JSONDecoder().decode(CameraOverlayPlacement.self, from: data) else {
            return CameraOverlayPlacement.defaultFrame(in: visibleFrame)
        }
        return CameraOverlayPlacement.clamped(placement.frame, in: visibleFrame)
    }

    func save(frame: NSRect, displayID: UInt32, visibleFrame: NSRect) {
        let clampedFrame = CameraOverlayPlacement.clamped(frame, in: visibleFrame)
        let placement = CameraOverlayPlacement(frame: clampedFrame)
        guard let data = try? JSONEncoder().encode(placement) else { return }
        defaults.set(data, forKey: key(for: displayID))
    }

    private func key(for displayID: UInt32) -> String {
        "\(keyPrefix).\(displayID)"
    }
}
