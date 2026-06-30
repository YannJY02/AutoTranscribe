# Simultaneous Visual Presentation PRD

Status: ready-for-agent

## Problem Statement

In the Live Workspace, camera and screen capture currently behave like competing visual sources. When both are enabled, the experience still resolves to one primary preview path instead of showing that the user is presenting both their screen and their camera presence.

The user wants a FaceTime-style presentation form: screen sharing and camera presence can coexist, with a clear combined visual presentation instead of forcing a choice between them.

## Solution

Live Workspace should support simultaneous visual presentation by preferring Apple's official Presenter Overlay path. Camera-only remains a camera preview. Screen-only remains a screen preview. When both camera and screen are enabled, InsightKit should use the system-provided combined screen-sharing stream where available, so the user can record and review a single coherent presentation.

The saved Record should preserve that combined presentation as one reviewable meeting asset when both visual sources were active.

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
- Prefer Apple's official Presenter Overlay behavior for simultaneous screen-plus-camera presentation.
- Accept system-controlled presenter layout before building a custom camera-tile compositor.
- Keep the existing camera and screen toggles. Do not add a separate presentation-mode button for the first implementation.
- When camera and screen are both enabled, show a clear Live Workspace state such as `屏幕录制 + Presenter Overlay`.
- InsightKit should guide the user toward Presenter Overlay when both visual toggles are enabled, but it should not promise to bypass macOS system confirmation or system UI.
- Do not raise InsightKit's minimum macOS version for this feature. Use system availability checks and fall back to screen-only recording when Presenter Overlay is not available.
- Preserve the existing camera-only and screen-only behavior as first-class cases.
- If Presenter Overlay is unavailable or not enabled, keep screen capture usable and clearly tell the user that camera presence will not be included in this Record.
- Do not block screen recording just because Presenter Overlay is unavailable; a future explicit "camera required" mode can add that stricter behavior if needed.
- The combined presentation should produce one user-visible review media asset for the Record, aligned to the Media Timeline.
- The saved Record should preserve a lightweight presentation status, such as `presenter overlay captured` or `screen-only fallback`, so later review can distinguish expected fallback from a recording bug.
- Record Review should not add persistent UI for successful Presenter Overlay captures. It should only surface presentation status when fallback or abnormal capture means camera presence is missing.
- Raw separate visual sources may remain implementation or diagnostic inputs, but normal Record Review should not ask the user to choose between them.
- If installed-app validation shows Presenter Overlay is visible in system sharing UI but not captured into InsightKit's saved media, record that as a feasibility blocker and make a separate decision before building an app-owned compositor.
- Keep audio input behavior separate from visual presentation; microphone, system audio, and mixed audio are not redesigned by this PRD.
- Keep this in the native macOS Live Workspace. The Python runtime and sidecar do not own visual source composition.
- Reuse the existing visual preview planning and Live Workspace preview selection seam before adding custom composition code.

## Testing Decisions

- Good tests should verify user-visible behavior through the highest existing seam: visual source selection should resolve camera-only, screen-only, and Presenter Overlay presentation plans without depending on real cameras or screen permissions.
- Add coverage that enabling both camera and screen chooses the official Presenter Overlay path when available.
- Add coverage that Presenter Overlay unavailable states degrade to screen-only recording with explicit user guidance instead of silent camera loss or blocked recording.
- Add coverage that the both-enabled state exposes user guidance when macOS requires system-level Presenter Overlay confirmation.
- Add coverage that unsupported macOS versions use screen-only fallback rather than disabling Live Workspace or raising the app minimum version.
- Add coverage that disabling one visual source keeps the other visual source active.
- Add coverage that permission or setup failure for one visual source does not tear down the other active source.
- Add coverage that combined visual presentation can be prepared as one review media asset for Record Review.
- Add coverage that saved Record metadata can represent Presenter Overlay capture versus screen-only fallback.
- Add coverage that Record Review surfaces fallback status without adding persistent status UI for successful Presenter Overlay records.
- Existing prior art includes the Live Workspace visual preview plan tests, Live Session ViewModel capture-preview behavior tests, and review-media composition tests.
- Automated tests should cover app-owned state, guidance, fallback, metadata, and Record Review presentation-status behavior.
- Installed-app owner validation is required before accepting Presenter Overlay capture because the actual system overlay is controlled by macOS.
- If installed-app validation cannot prove Presenter Overlay is included in the saved Record media, the issue should not be marked accepted only because app-owned state tests pass.

## Out of Scope

- Custom layout editing, draggable camera tiles, crop controls, multiple camera layouts, or app-owned presenter-tile composition.
- Live broadcasting, external call integration, or actual FaceTime integration.
- Redesigning microphone, system audio, mixed audio, ASR, Insight Refresh, Smart Minutes generation, or provider behavior.
- Replacing the native macOS capture stack.
- Changing historical Records that were already saved with only one visual source.

## Further Notes

This is a new enhancement lane, not a reopening of the previous black-preview QA issue. The earlier issue made camera-only and screen-only preview visible; this PRD defines the next product behavior where both sources can intentionally coexist.
