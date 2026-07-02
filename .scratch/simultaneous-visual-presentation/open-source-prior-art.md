# Open-Source Prior Art For Simultaneous Visual Presentation

Status: current
Last reviewed: 2026-07-02

## Decision Summary

No reviewed open-source project currently provides a drop-in module for InsightKit's active product constraint:

- saved Record video must visibly contain both screen content and camera presence;
- one reviewable media surface in Record Review;
- no AGPL code copied into InsightKit;
- no layout editor or broad custom compositor in the first implementation.

The best technical prior art is QuickRecorder, because it saves a playable screen-plus-person video and its source shows both Presenter Overlay observation and a captured `Camera Overlayer` path. It is not a direct module candidate because it is AGPL-3.0. Use it as behavior reference only unless InsightKit intentionally accepts AGPL obligations or obtains a separate license.

The best permissively licensed module candidates are EasyDemo, OpenCapture, openscreen, and ariso-ai/presenter-overlay. They are MIT, but they solve broader overlay/composition problems than the first InsightKit slice needs. They remain useful references if the implementation needs camera device handling, overlay windows, or background processing later.

## Reviewed Projects

| Project | License | Relevant implementation | Fit for current decision |
| --- | --- | --- | --- |
| `lihaoyun6/QuickRecorder` | AGPL-3.0 | ScreenCaptureKit recording, Presenter Overlay callback handling, visible Camera Overlayer path, saved-frame/status handling. | Strong behavior reference, not direct code reuse. Black-box validation passed saved-output proof on 2026-07-02. |
| `danieloquelis/EasyDemo` | MIT | ScreenCaptureKit + AVFoundation + Core Image recording pipeline with webcam overlay, masks, position, size, and export. | Useful if InsightKit later needs richer camera-overlay rendering, but broader than the first saved-output slice. |
| `simarahitamtech/OpenCapture` | MIT | Native SwiftUI ScreenCaptureKit recorder, floating webcam PiP window, AVCaptureSession camera manager, Vision-based background blur, fragmented MP4 writer. | Useful reference for local camera overlay and direct-to-disk writer patterns. |
| `siddharthvaddem/openscreen` | MIT | Electron app with native macOS ScreenCaptureKit helper roadmap; webcam is sidecar today and planned as helper-owned picture-in-picture composition. | Useful architecture reference for helper-owned composition only. No strict Apple Presenter Overlay implementation found. |
| `ariso-ai/presenter-overlay` | MIT | Always-on-top camera window using AVFoundation, Vision person segmentation, Core Image compositing, SwiftUI/AppKit windowing. | Useful for a separate floating overlay or custom overlay reference. Not acceptable as the saved Record implementation under the current decision. |
| OBS-style scene composition | GPL ecosystem / mixed | Mature screen + camera scene compositor pattern. | Product mismatch for this feature because it is explicitly app-owned composition, not Apple Presenter Overlay. |

## QuickRecorder Findings

QuickRecorder is the closest known implementation to investigate further.

Observed from local source inspection:

- README claims macOS 14 Presenter Overlay support for real-time camera overlay in recordings.
- The recorder uses `SCStream` and `AVAssetWriter` for ScreenCaptureKit output.
- It implements `outputVideoEffectDidStart(for:)` and `outputVideoEffectDidStop(for:)` on the stream delegate.
- It checks `.presenterOverlayContentRect` in ScreenCaptureKit sample-buffer attachments to infer overlay mode changes.
- It temporarily withholds appending screen frames while Presenter Overlay is starting or changing mode, using a configurable delay.
- It also has a separate camera floating-window path for older macOS versions or non-Presenter Overlay behavior.

Constraints:

- License is AGPL-3.0. Do not copy implementation into InsightKit without a deliberate license decision.
- The inspected source shows how to observe Presenter Overlay.
- The source also shows a `Camera Overlayer` window that QuickRecorder deliberately does not exclude from screen capture. That is the likely mechanism behind the black-box saved-output success.
- Apple and third-party notes indicate Presenter Overlay is user-controlled through macOS system UI; apps can observe it but should not assume they can force-enable it.

Useful reference patterns if reimplementing from Apple docs:

- keep an active `AVCaptureSession` to feed the local camera overlay;
- let the camera overlay remain visible to the selected screen capture filter;
- use `SCStreamDelegate` callbacks as signals, not final proof;
- inspect `presenterOverlayContentRect` as diagnostic metadata;
- require saved-video frame inspection before marking success.

## EasyDemo Findings

EasyDemo is the best permissive reference if custom composition is ever approved.

Observed from local source inspection:

- MIT license.
- Native Swift/SwiftUI macOS screen recorder.
- Uses ScreenCaptureKit for window capture, AVFoundation for webcam capture, and Core Image for composition.
- Contains separable modules for webcam capture, overlay rendering, masks, background rendering, and final video composition.

Useful modules if the product decision changes:

- `WebcamCapture` for camera device selection and frames;
- `VideoComposer` for combining captured content with overlays;
- `WebcamOverlayRenderer` and `ShapeMaskGenerator` for overlay shape and styling;
- `RecordingEngine` for a ScreenCaptureKit-to-AVAssetWriter pipeline.

Why it is not the first implementation target:

- It composes the camera into the recording itself.
- That is a custom Screen Studio/Loom-style overlay, not Apple's FaceTime Presenter Overlay.
- It includes richer styling/export behavior than InsightKit needs for the first saved-output implementation.

## ariso-ai/presenter-overlay Findings

This project is a small MIT reference for a live floating camera overlay.

Observed from local source inspection:

- MIT license.
- Uses AVFoundation for camera capture.
- Uses Vision person segmentation and Core Image compositing to remove the background.
- Uses SwiftUI/AppKit to show a borderless always-on-top overlay window.

Useful modules if the product decision changes:

- camera selection and live preview windowing;
- person segmentation pipeline;
- simple menu-bar accessory control model.

Why it is not the current solution:

- It is a separate always-on-top window.
- Whether it appears in a recording depends on the recorder capturing that window.
- It is not Apple's native Presenter Overlay and does not prove saved Record media contains FaceTime-style system composition.

## OpenCapture Findings

OpenCapture is a useful Swift-native screen recorder reference, but it follows the same custom-overlay family as EasyDemo.

Observed from local source inspection:

- MIT license.
- Uses ScreenCaptureKit for screen capture and AVFoundation for file writing.
- Uses a floating circular webcam PiP window for camera presence.
- Uses AVFoundation camera capture and Vision/Core Image background blur for webcam processing.
- Uses a fragmented MP4 writer, which is interesting for crash-resilient direct-to-disk recording.
- No `Presenter Overlay`, `SCContentSharingPicker`, `outputVideoEffect`, or `presenterOverlayContentRect` usage was found.

Useful modules if the product decision changes:

- `WebcamManager` for camera discovery, preview, and sample-buffer capture;
- `WebcamOverlay` for a draggable floating PiP window;
- `BackgroundBlurProcessor` for Vision-based webcam processing;
- `VideoWriter` for direct-to-disk screen recording patterns.

Why it is not the first implementation target:

- Its webcam behavior is an app-owned floating PiP overlay.
- It does not use Apple's Presenter Overlay pipeline.
- It includes more product surface than InsightKit needs for the first saved-output implementation.

## openscreen Findings

openscreen is a strong product-scale reference for native-helper architecture, but it is not an Apple Presenter Overlay solution.

Observed from local source inspection:

- MIT license.
- macOS uses a native ScreenCaptureKit helper for screen/window capture.
- Current docs say webcam is attached as a sidecar recording today, with future native AVFoundation composition planned.
- The macOS roadmap explicitly describes composing webcam into the helper-owned MP4 as picture-in-picture.
- No `Presenter Overlay`, `SCContentSharingPicker`, `outputVideoEffect`, or `presenterOverlayContentRect` usage was found.

Useful modules or ideas if the product decision changes:

- process/helper boundary for capture ownership;
- JSON helper contract for source, audio, webcam, cursor, and output paths;
- separate manifest/session model for screen and webcam assets.

Why it is not the first implementation target:

- Its target architecture is helper-owned custom composition.
- It is not FaceTime/Presenter Overlay native behavior.
- It would be a major architecture import for InsightKit and is not justified for the current strict-native feature gate.

## Recommendation

Keep the current screen-only fallback as the default product behavior until InsightKit's own saved-output path passes installed-app validation.

The QuickRecorder black-box validation on 2026-07-02 passed the saved-output test: the latest saved MP4 is playable and extracted frames visibly contain both screen content and camera/person presence.

Use QuickRecorder only as feasibility evidence and behavior reference. Because the project is AGPL-3.0, reimplement any accepted path from Apple ScreenCaptureKit documentation and our existing `VideoCaptureService` seam instead of copying QuickRecorder code.

The mechanism question is now resolved enough for implementation planning: QuickRecorder's useful path appears to be a visible Camera Overlayer captured into the screen recording. Implement the same product shape with InsightKit-owned code and mechanism-accurate copy.

Do not borrow EasyDemo, OpenCapture, openscreen, or ariso-ai modules for the active feature unless the owner explicitly changes the product decision to allow custom composition.

## Sources

- Apple WWDC23, "What's new in ScreenCaptureKit": Presenter Overlay is applied by ScreenCaptureKit and surfaced through the macOS video menu.
- Apple ScreenCaptureKit docs: `SCStreamDelegate` has Presenter Overlay start/stop callbacks; `SCStreamFrameInfo.presenterOverlayContentRect` can appear in frame metadata.
- Nonstrict, "A look at ScreenCaptureKit on macOS Sonoma": notes that Presenter Overlay is user-enabled through system UI and apps should not assume direct enable/disable control.
- QuickRecorder: https://github.com/lihaoyun6/QuickRecorder
- EasyDemo: https://github.com/danieloquelis/EasyDemo
- OpenCapture: https://github.com/simarahitamtech/OpenCapture
- openscreen: https://github.com/siddharthvaddem/openscreen
- ariso-ai/presenter-overlay: https://github.com/ariso-ai/presenter-overlay
