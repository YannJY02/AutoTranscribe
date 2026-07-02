# Simultaneous Visual Presentation PRD

Status: ready-for-human

## Problem Statement

In the Live Workspace, camera and screen capture currently behave like competing visual sources. When both are enabled, the experience still resolves to one primary preview path instead of showing that the user is presenting both their screen and their camera presence.

The user wants a FaceTime-style presentation form: screen sharing and camera presence can coexist in the saved Record video, with a clear combined visual presentation instead of forcing a choice between them.

## Solution

Live Workspace should support simultaneous visual presentation when the saved Record video visibly contains both screen content and camera presence as one reviewable media surface. Camera-only remains a camera preview. Screen-only remains a screen preview. When both camera and screen are enabled, InsightKit should prefer Apple's Presenter Overlay if it can satisfy the saved-video standard, but it may use a simple local camera overlay that is captured into the same screen recording if that is the reliable path.

The saved Record should preserve that combined presentation as one reviewable meeting asset when both visual sources were active. InsightKit should not create separate camera and screen media for normal Record Review, and should not add a layout editor in the first implementation.

## Current Validation State

InsightKit installed-app validation has now proven the saved-output camera overlay path for simultaneous visual presentation. On 2026-07-02, a real installed-app Live Workspace run saved a playable Record video where sampled media visibly contains both screen content and camera presence.

Accepted InsightKit-owned proof:
- Saved Record: `/Users/yann.jy/Documents/InsightKit/Records/20260702-1917-live-record-53301351`.
- Saved media: `recording.mp4`, 7,324,003 bytes.
- Metadata evidence: `presentationStatus` is `screenPlusCameraCaptured`, not `presenterOverlayCaptured`.
- Media probe: one AAC audio stream and one H.264 video stream, both 19.890s; video is 1728x1116.
- Sampled-frame evidence: `logs/diagnostics/2026-07-02/insightkit-saved-output-camera-overlay/record-53301351-frame-008s.png` visibly shows screen content with the local camera overlay.

The 2026-07-01 strict Apple Presenter Overlay validation still produced important failures:
- A previously accepted video Record was reclassified as screen-only after sampled saved-video frames showed no visible camera presence.
- A later installed-app run saved only `recording.wav` in the Record directory while `metadata.json` still said `presentationStatus: presenterOverlayCaptured`; the temporary `recording.mp4` was invalid (`moov atom not found`).
- A follow-up official Apple picker attempt kept the camera session active for macOS Presenter Overlay, but the saved Record was still audio-only; the temp `recording.mp4` again had no `moov` atom and was not playable.

On 2026-07-02, QuickRecorder black-box validation on the same Mac saved a playable MP4 whose extracted frame visibly contained both screen content and camera/person presence. Source inspection shows QuickRecorder intentionally leaves its `Camera Overlayer` visible to the ScreenCaptureKit capture filter, so the most likely working mechanism is a captured local camera overlay, not pure Apple Presenter Overlay. The owner accepted using this saved-output-first path as the implementation direction, while still forbidding AGPL code reuse.

Fallback hardening has been validated separately from simultaneous presentation acceptance:
- A real installed-app fallback run saved a playable screen-only `recording.mp4`.
- A short/unstable run that did not produce valid video correctly saved audio only with `presentationStatus: visualMediaUnavailable`.

The accepted product behavior is therefore saved-output camera overlay when camera and screen are both enabled, with screen-only fallback if overlay startup fails or final media cannot preserve valid video. The app must describe the accepted local-overlay path as camera overlay, not Apple Presenter Overlay.

On 2026-07-02, a follow-up QuickRecorder-style placement pass made the camera overlay draggable, resizable, and position-stable while keeping it as one captured local overlay. This is basic overlay placement, not a layout editor or multi-track visual workflow.

Later on 2026-07-02, a playback bug exposed that some camera-plus-screen runs could save only audio because the temporary MP4 existed but was not finalized into playable media. The video finalization path was hardened and revalidated with saved Record `/Users/yann.jy/Documents/InsightKit/Records/20260702-2109-live-record-74ee0db8`: metadata reports `mediaType: video` and `presentationStatus: screenPlusCameraCaptured`, `ffprobe` reads a playable 10.000s audio/video MP4, the extracted frame shows screen plus camera overlay, and the in-app Record Review playback surface displays video.

## User Stories

1. As a Live Workspace user, I want to enable camera and screen at the same time, so that I can present content while still appearing on camera.
2. As a Live Workspace user, I want screen sharing to stay visible when I turn on the camera, so that my shared content is not replaced by my face.
3. As a Live Workspace user, I want my camera to remain visible when I share my screen, so that the recording feels like a real presentation.
4. As a Live Workspace user, I want camera-only capture to keep working, so that simple camera sessions do not change.
5. As a Live Workspace user, I want screen-only capture to keep working, so that non-camera screen recordings do not change.
6. As a Live Workspace user, I want a clear status message when one visual source is unavailable, so that I know whether camera, screen, or both are active.
7. As a Live Workspace user, I want turning one source off to keep the other source running, so that I do not lose the whole visual preview by changing one toggle.
8. As a Live Workspace user, I want the recording indicator to apply to the combined presentation, so that I know the app is recording the same visual surface I am seeing.
9. As a Record Review user, I want the saved media to show the combined screen-plus-camera presentation, so that review matches what happened during capture.
10. As a Record Review user, I want playback, transcript rows, Smart Minutes, and Time-Bound Notes to keep using one Media Timeline, so that the combined presentation remains a normal Record.
11. As a future agent, I want visual source selection expressed as a presentation plan, so that camera-only, screen-only, and combined presentation can be tested without real macOS permissions.
12. As a future agent, I want the final review media to remain one playable asset, so that Record Review, Smart Minutes review, export, and transcript recovery do not need separate visual-source rules.

## Implementation Decisions

- Treat camera and screen as independently enabled visual inputs, not mutually exclusive visual modes.
- Use a saved-output-first acceptance standard: the saved Record video must visibly contain both screen content and camera presence.
- Prefer Apple's native Presenter Overlay behavior when it can satisfy the saved-video standard.
- If Presenter Overlay cannot reliably save camera presence, use a simple local camera overlay captured into the same screen recording, matching the QuickRecorder behavior evidence.
- Do not copy QuickRecorder code or other AGPL implementation details into InsightKit.
- Do not build a layout editor, multi-camera compositor, or separate visual-track review workflow for the first implementation.
- Keep the existing camera and screen toggles. Do not add a separate presentation-mode button for the first implementation.
- When camera and screen are both enabled, show a clear Live Workspace state such as `屏幕录制 + 摄像头叠加`.
- If the implementation is Presenter Overlay, InsightKit may guide the user toward macOS system confirmation. If the implementation is a local camera overlay, InsightKit should describe it as camera overlay, not Presenter Overlay.
- For the local camera overlay path, allow practical placement behavior: drag by background, resize with a stable aspect ratio, restore the last frame per display, and clamp restored frames into the visible display area.
- Do not raise InsightKit's minimum macOS version for this feature. Use system availability checks and fall back to screen-only recording when Presenter Overlay is not available.
- Preserve the existing camera-only and screen-only behavior as first-class cases.
- If the simultaneous presentation path is unavailable or not enabled, keep screen capture usable and clearly tell the user that camera presence will not be included in this Record.
- Do not describe screen-only fallback as successful simultaneous visual presentation. Screen recording may remain usable, but the combined feature is unavailable unless camera presence is visible in the saved Record video.
- The combined presentation should produce one user-visible review media asset for the Record, aligned to the Media Timeline.
- The saved Record may preserve a lightweight presentation status, such as `screen plus camera captured`, `presenter overlay captured`, `screen-only fallback`, or `visual media unavailable`, but metadata alone is not acceptance proof.
- Record Review should not add persistent UI for successful simultaneous visual presentation captures. It should only surface presentation status when fallback or abnormal capture means camera presence is missing.
- Raw separate visual sources may remain implementation or diagnostic inputs, but normal Record Review should not ask the user to choose between them.
- If installed-app validation shows the combined presentation is visible during capture but not present in InsightKit's saved media, record that as a feasibility blocker and keep the screen-only fallback.
- Keep audio input behavior separate from visual presentation; microphone, system audio, and mixed audio are not redesigned by this PRD.
- Keep this in the native macOS Live Workspace. The Python runtime and sidecar do not own visual source composition.
- Reuse the existing visual preview planning and Live Workspace preview selection seam before adding custom composition code.

## Testing Decisions

- Good tests should verify user-visible behavior through the highest existing seam: visual source selection should resolve camera-only, screen-only, and Presenter Overlay presentation plans without depending on real cameras or screen permissions.
- Add coverage that enabling both camera and screen chooses the saved-output simultaneous presentation path when available.
- Add coverage that unavailable states do not claim simultaneous presentation success; screen-only recording can continue only as screen-only recording.
- Add coverage that the both-enabled state exposes appropriate guidance for either Presenter Overlay confirmation or local camera overlay capture.
- Add coverage that unsupported macOS versions use screen-only fallback rather than disabling Live Workspace or raising the app minimum version.
- Add coverage that disabling one visual source keeps the other visual source active.
- Add coverage that permission or setup failure for one visual source does not tear down the other active source.
- Add coverage that combined visual presentation can be prepared as one review media asset for Record Review.
- Add coverage that saved Record metadata can represent screen plus camera capture, Presenter Overlay capture, screen-only fallback, and visual-media unavailable states.
- Add coverage that Record Review surfaces fallback status without adding persistent status UI for successful simultaneous presentation records.
- Add coverage for overlay placement behavior that does not require real camera or screen permissions: default frame, per-display persistence, and visible-frame clamping.
- Existing prior art includes the Live Workspace visual preview plan tests, Live Session ViewModel capture-preview behavior tests, and review-media composition tests.
- Automated tests should cover app-owned state, guidance, fallback, metadata, and Record Review presentation-status behavior.
- Installed-app owner validation is required before accepting simultaneous visual presentation because the final proof is saved media, not app-owned state.
- If installed-app validation cannot prove visible camera presence in the saved Record media, the issue should not be marked accepted only because app-owned state tests pass, metadata says the feature captured, or the saved media contains a video stream.

## Out of Scope

- Custom layout editing, crop controls, multiple camera layouts, or multi-track visual composition. Basic drag/resize placement for the one local overlay is allowed.
- Copying QuickRecorder code or depending on QuickRecorder as a runtime component.
- Live broadcasting, external call integration, or actual FaceTime integration.
- Redesigning microphone, system audio, mixed audio, ASR, Insight Refresh, Smart Minutes generation, or provider behavior.
- Replacing the native macOS capture stack.
- Changing historical Records that were already saved with only one visual source.

## Further Notes

This is a new enhancement lane, not a reopening of the previous black-preview QA issue. The earlier issue made camera-only and screen-only preview visible; this PRD defines the next product behavior where both sources can intentionally coexist.
