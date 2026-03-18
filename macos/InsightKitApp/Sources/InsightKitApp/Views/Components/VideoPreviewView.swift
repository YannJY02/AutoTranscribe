import AVFoundation
import SwiftUI

/// NSViewRepresentable wrapping AVCaptureVideoPreviewLayer for camera preview,
/// or displaying ScreenCaptureKit frames via a CALayer-backed view.
/// Uses Coordinator to hold the preview layer across SwiftUI view identity changes.
struct VideoPreviewView: NSViewRepresentable {
    let captureService: VideoCaptureService?
    let isRecording: Bool
    let recordingDuration: TimeInterval

    init(
        captureService: VideoCaptureService? = nil,
        isRecording: Bool = false,
        recordingDuration: TimeInterval = 0
    ) {
        self.captureService = captureService
        self.isRecording = isRecording
        self.recordingDuration = recordingDuration
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.containerView = container

        if let layer = captureService?.cameraPreviewLayer {
            context.coordinator.attachPreviewLayer(layer, to: container)
        }

        // REC indicator overlay
        let recView = makeRECOverlay()
        recView.isHidden = !isRecording
        container.addSubview(recView)
        context.coordinator.recOverlay = recView

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator

        // Update preview layer if service changed
        if let newLayer = captureService?.cameraPreviewLayer {
            if coordinator.currentPreviewLayer !== newLayer {
                coordinator.attachPreviewLayer(newLayer, to: nsView)
            }
        } else {
            coordinator.detachPreviewLayer()
        }

        // Resize preview layer to fill container
        if let layer = coordinator.currentPreviewLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = nsView.bounds
            CATransaction.commit()
        }

        // Update REC overlay
        if let recView = coordinator.recOverlay {
            recView.isHidden = !isRecording
            updateRECLabel(in: recView, duration: recordingDuration)
            // Position top-right
            let margin: CGFloat = 12
            let size = recView.fittingSize
            recView.frame = NSRect(
                x: nsView.bounds.width - size.width - margin,
                y: nsView.bounds.height - size.height - margin,
                width: size.width,
                height: size.height
            )
        }
    }

    // MARK: - Coordinator

    class Coordinator {
        var containerView: NSView?
        var currentPreviewLayer: AVCaptureVideoPreviewLayer?
        var recOverlay: NSView?

        func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer, to view: NSView) {
            detachPreviewLayer()
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer?.insertSublayer(layer, at: 0)
            currentPreviewLayer = layer
        }

        func detachPreviewLayer() {
            currentPreviewLayer?.removeFromSuperlayer()
            currentPreviewLayer = nil
        }
    }

    // MARK: - REC Overlay

    private func makeRECOverlay() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        container.layer?.cornerRadius = 6

        // Red dot
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.frame = NSRect(x: 8, y: 6, width: 10, height: 10)
        dot.identifier = NSUserInterfaceItemIdentifier("recDot")
        container.addSubview(dot)

        // Pulse animation
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        // Duration label
        let label = NSTextField(labelWithString: "00:00")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 24, y: 3, width: 60, height: 16)
        label.identifier = NSUserInterfaceItemIdentifier("recLabel")
        container.addSubview(label)

        container.frame = NSRect(x: 0, y: 0, width: 90, height: 22)
        return container
    }

    private func updateRECLabel(in overlay: NSView, duration: TimeInterval) {
        guard let label = overlay.subviews.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("recLabel")
        }) as? NSTextField else { return }

        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        label.stringValue = String(format: "%02d:%02d", mins, secs)
    }
}
