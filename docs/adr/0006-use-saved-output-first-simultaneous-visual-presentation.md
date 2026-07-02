# Use saved-output-first simultaneous visual presentation

Status: accepted

InsightKit will ship simultaneous visual presentation when the saved Record video itself visibly contains both screen content and camera presence as one reviewable media surface.

Apple Presenter Overlay remains the preferred mechanism when it satisfies that saved-video standard. The accepted fallback mechanism is a simple local camera overlay that is visible to ScreenCaptureKit and captured into the same saved video, matching the successful QuickRecorder black-box result. This is not permission to build a layout editor, multi-track visual review, or broad custom compositor.

**Consequences**:
- Metadata, ScreenCaptureKit callbacks, or source availability are not enough to accept the feature unless the saved media visibly contains camera presence.
- If the mechanism is a captured local camera overlay, product copy and metadata must not claim strict Apple Presenter Overlay.
- Screen-only fallback may remain usable as screen recording, but it must not be described as successful simultaneous visual presentation.
- The default app path should not launch an unproven combined capture flow if it makes saved media worse than normal screen recording.
- QuickRecorder is AGPL-3.0 and may be used only as behavior evidence; InsightKit must implement its own path from Apple APIs and project-owned code.
- Future implementation work must pass installed-app saved-video proof before marking the feature accepted.
