# Live Workspace Session Deepening PRD

Status: ready-for-human

## Problem Statement

The Live Workspace is user-visible and already works, but the current Live Session module is too shallow for the amount of behavior it owns. Understanding one live capture path requires reading the main Live Session module, capture extension, warmup extension, runtime extension, insight extension, records extension, panel adapters, RPC client protocol, and tests.

This makes future Matt workflow work slower and riskier. A future agent can see the Live Workspace state, but cannot make a narrow change to Live Transcript Delta, Insight Refresh, provider degradation, Runtime Warmup, or Record save without reasoning across a wide ViewModel interface.

## Solution

Deepen the Live Workspace Session around the Live Transcript Pipeline first. The initial target is not a UI redesign and not a replacement for the native macOS app or Python Sidecar. The target is one deep module that concentrates chunk ingestion, Live Transcript Delta, Insight Refresh decisions, provider degradation handling, and metrics update rules behind a smaller interface.

The Live Session module should remain the SwiftUI-facing adapter that applies user-visible Capture State, Session Phase, Transcript Segment, Smart Minutes, Time-Bound Note, and Media Seek state.

Architecture report:
- `/var/folders/qj/rpkv85p52_j3qx851dzbcvsr0000gn/T/architecture-review-20260620-094106-live-workspace.html`

## User Stories

1. As the project owner, I want Live Workspace architecture work to start from a single recommended deepening candidate, so that agents do not reopen every friction area at once.
2. As the project owner, I want the current native macOS shell and Python Sidecar architecture preserved, so that architecture cleanup does not become a rewrite.
3. As a future agent, I want Live Transcript Delta ingestion behind a focused module, so that I can test transcript behavior without constructing the full Live Session module.
4. As a future agent, I want Insight Refresh decisions separated from view state mutation, so that refresh cadence and provider degradation can be verified locally.
5. As a future agent, I want provider probe timeout and auth failure behavior preserved, so that live transcription can continue when insight generation pauses.
6. As a future agent, I want metrics updates concentrated with transcript ingestion outcomes, so that queue depth, first segment time, latency, and segment counts do not drift.
7. As a future agent, I want Runtime Warmup backlog behavior preserved while the transcript path is deepened, so that buffered chunks remain bounded.
8. As a future agent, I want the Live Session module to act as an adapter over a smaller interface, so that SwiftUI-facing state stays readable.
9. As a future agent, I want tests to cross the same seam as callers, so that implementation details can change without breaking useful coverage.
10. As a future agent, I want Record save behavior kept out of the first deepening slice, so that persistence changes do not hide transcript pipeline regressions.
11. As a user, I want live capture to keep producing transcript segments after the refactor, so that working software does not regress.
12. As a user, I want final Smart Minutes generation to remain available after a live session, so that the Live Workspace still produces a reviewable Record.
13. As a user, I want Time-Bound Notes and Media Seek behavior to remain stable, so that reviewing a live Record still works.
14. As a release maintainer, I want local release evidence to remain separate from Distribution Ready claims, so that Apple-controlled blockers are not confused with code regressions.
15. As a future agent, I want each deepening issue to name its verification gate, so that implementation can stop at evidence rather than keep broadening scope.

## Implementation Decisions

- Start with the Live Transcript Pipeline because it has the strongest depth and locality payoff.
- Preserve accepted ADRs: native SwiftUI app plus Python Sidecar, persistent Unix socket JSON-RPC, and separate Local Release Ready from Distribution Ready.
- Treat the Live Session module as the app-facing adapter. It should apply user-visible state and delegate transcript ingestion decisions.
- Keep Runtime Warmup as an input to the transcript pipeline, not as a first-slice rewrite target.
- Keep Record save and Export Document behavior out of the first implementation issue.
- Do not change product language: use Live Workspace, Capture State, Runtime Warmup, Live Transcript Delta, Final Insight Generation, Record, Smart Minutes, Time-Bound Note, and Media Seek.
- Prefer one new or deepened module seam for transcript ingestion over several narrow helper functions.
- Preserve provider degradation behavior: auth failures or probe timeouts pause insight generation while transcription continues.
- Keep UI-test mode behavior stable unless an issue explicitly covers it.
- Keep current local markdown issue tracking under this feature folder.

## Testing Decisions

- The first verification seam should be focused Swift tests that exercise Live Transcript Pipeline behavior without requiring real audio capture or a real Sidecar.
- Existing prior art includes `LiveInsightCoordinator`, `WarmupBacklogPolicy`, `WarmupRetryPolicy`, and `LiveCaptureStateMapper` tests.
- ViewModel tests should remain for adapter behavior, but they should not be the only way to test transcript ingestion rules.
- For any Swift/macOS behavior change, run targeted Swift tests before broader Python or release checks.
- For any change that claims local release readiness, run the release Closure Gate after targeted tests.
- Do not require Packaged-App Smoke or Visual GUI Proof for pure internal Live Transcript Pipeline prefactoring unless installed-app behavior changes.

## Out of Scope

- Replacing the native SwiftUI app with a web shell.
- Replacing the Python Sidecar or Unix socket JSON-RPC.
- Redesigning the Live Workspace UI.
- Changing Record Package schema or export format.
- Changing public release channel, signing, notarization, App Store Connect, or privacy URL decisions.
- Reworking AttentionOS integration.
- Refactoring Import Workspace or Record Review unless needed to preserve shared panel contracts.
- Changing ASR engine selection or Runtime Profile rules.

## Further Notes

Checkpoint review for the current worktree:
- Standards axis: no blocking standard violations found against `AGENTS.md`, `docs/agents/loop-engineering.md`, and the local markdown tracker conventions.
- Spec axis: the project-normalization PRD and loop standard are implemented and verified; the current worktree is still uncommitted, so implementation agents should avoid unrelated cleanup.
- Latest known gates before this PRD: `scripts/verify_project_normalization.py` passed, full Python pytest passed, and `scripts/verify_release_closure.py` returned `passed_local_with_external_blockers`.

Published local issues:
- `.scratch/live-workspace-session/issues/01-create-live-transcript-pipeline-seam.md`
- `.scratch/live-workspace-session/issues/02-route-live-transcript-delta-through-pipeline.md`
- `.scratch/live-workspace-session/issues/03-route-insight-refresh-degradation-through-pipeline.md`
- `.scratch/live-workspace-session/issues/04-shrink-live-session-adapter-surface.md`
- `.scratch/live-workspace-session/issues/05-separate-pause-and-stop-recording-controls.md`

Verification after publishing:
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `11 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-20/project-normalization-20260620-094509/proof.json`

Final gates for this planning loop:
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-20/project-normalization-20260620-094551/proof.json`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest -q --tb=short` -> `203 passed, 1 warning`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_release_closure.py` -> `status: passed_local_with_external_blockers`
- Release closure proof: `logs/diagnostics/2026-06-20/release-closure-20260620-094614/proof.json`

## Comments

### 2026-06-20 - Codex

Issue `01-create-live-transcript-pipeline-seam.md` completed to `ready-for-human`.

Changed:
- Added the Live Transcript Pipeline module seam and RPC runtime adapter.
- Added focused Swift tests for empty ASR output, successful ingestion without refresh, refresh success, already-paused refresh, provider auth degradation, and provider timeout degradation.
- Added `Live Transcript Pipeline` to `docs/contexts/macos-app/CONTEXT.md`.

Verification:
- `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests` -> `6 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` -> `16 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp` -> `123 tests, 0 failures`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-20/project-normalization-20260620-103420/proof.json`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest -q --tb=short` -> `203 passed, 1 warning`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_release_closure.py` -> `status: passed_local_with_external_blockers`
- Release closure proof: `logs/diagnostics/2026-06-20/release-closure-20260620-103148/proof.json`

### 2026-06-21 - Codex

Issue `02-route-live-transcript-delta-through-pipeline.md` completed to `ready-for-human`.

Changed:
- Routed `LiveSessionViewModel.processChunk` through the Live Transcript Pipeline seam.
- Added adapter tests that verify successful pipeline output becomes ordered Live Workspace transcript segments and metrics, and empty pipeline output advances Capture State/chunk index without adding transcript segments.

Verification:
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testProcessChunkApplies` -> `2 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` -> `18 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests` -> `6 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp` -> `125 tests, 0 failures`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `11 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-092658/proof.json`
- `git diff --check` -> passed

### 2026-06-21 - Codex

Issue `03-route-insight-refresh-degradation-through-pipeline.md` completed to `ready-for-human`.

Changed:
- Routed Insight Refresh success and provider-degradation outcomes through the Live Transcript Pipeline seam used by `LiveSessionViewModel.processChunk`.
- Preserved transcript ingestion when provider auth failure or probe timeout pauses Insight Refresh.
- Kept Capture State, analysis runtime state, provider metric, and user-facing error message stable for degradation paths.
- Added focused Live Session adapter tests for refresh success, auth failure, and provider timeout paths, with existing pipeline tests covering refresh-needed and degradation decisions.

Verification:
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` -> `21 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests` -> `6 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp` -> `128 tests, 0 failures`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `11 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-issue03` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-issue03/proof.json`
- `git diff --check` -> passed

Out of scope preserved:
- No Python runtime, release-channel, Record save, Export Document, Runtime Warmup, Smart Minutes, Time-Bound Note, or Media Seek behavior was intentionally changed.

### 2026-06-21 - Codex

Issue `04-shrink-live-session-adapter-surface.md` completed to `ready-for-human`.

Changed:
- Closed the adapter-surface shrink as a verification-only issue over the code changes from issues 02 and 03.
- Verified transcript ingestion, deduplication, Live Transcript Delta, refresh cadence, provider-degradation classification, and transcript pipeline metrics now live behind the Live Transcript Pipeline seam.
- Kept `LiveSessionViewModel` as the app-facing adapter for Capture State, Session Phase, Runtime Warmup queue state, Smart Minutes, Time-Bound Notes, Media Seek, and Record save.
- Preserved Runtime Warmup, Record save, notes, Media Seek, Smart Minutes, UI-test mode, Python runtime, and release-channel behavior.

Verification:
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` -> `21 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests` -> `6 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp` -> `128 tests, 0 failures`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `11 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py --output-root logs/diagnostics/2026-06-21/project-normalization-20260621-issue04` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-issue04/proof.json`
- `git diff --check` -> passed

Release boundary:
- Local release readiness was not claimed for this internal adapter-surface slice, so the release Closure Gate was not rerun.

### 2026-07-02 - Codex

Issue `05-separate-pause-and-stop-recording-controls.md` completed to `ready-for-human`.

Changed:
- Replaced the pause stub that stopped the live session with a real pause/resume state.
- Gated audio sample ingestion and video writer appends while paused.
- Adjusted video presentation timing so paused wall-clock time is not counted after resume.
- Disabled pause and stop controls while stop finalization is already saving.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveSessionViewModelTests/testPauseRecordingDoesNotStopLiveSession --filter LiveSessionViewModelTests/testPausedLiveSessionIgnoresMixedSamples --filter LiveSessionViewModelTests/testPausedLiveSessionSuppressesCaptureHealthWarnings --filter VideoRecordingTimelineTests/testPresentationTimeExcludesPausedDuration` -> `4 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --jobs 1` -> `260 tests, 0 failures`
- `python3 scripts/verify_project_normalization.py` -> `status: passed`
- Installed app build `20260702213020` verified `暂停 -> 继续 -> 停止录制`: pause kept the phase at `录制中`, the timer remained stable while paused, resume restored the pause control, finalizing disabled both controls, and stop saved Record `/Users/yann.jy/Documents/InsightKit/Records/20260702-2132-live-record-c0b1128d`.
- Final installed sync after the full test pass: `logs/workflow/latest_sync.json`, build `20260702213807`, installed at `/Users/yann.jy/Applications/InsightKit.app`.

### 2026-07-02 - Codex

Issue `06-preserve-av-sync-through-recording-pause.md` completed to `ready-for-human`.

Changed:
- Added pause intervals to the Live Workspace capture timeline.
- Changed audio/video composition offsets to use active recording time, excluding paused wall-clock time.
- Wired pause/resume/stop paths so the UI pause state, video writer pause state, and capture timeline pause state move together.
- Persisted pause metadata into `capture_timeline.json`.
- Updated the issue 24 media diagnostic so it reports pause intervals and checks the saved composition source window instead of treating source duration differences alone as failure.

Verification:
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveMediaCaptureTimelineTests --filter LiveSessionViewModelTests/testPauseRecordingDoesNotStopLiveSession --filter LiveSessionViewModelTests/testPausedLiveSessionIgnoresMixedSamples --filter LiveSessionViewModelTests/testPausedLiveSessionSuppressesCaptureHealthWarnings --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingPassesCaptureTimelineToReviewMediaComposer --filter LiveSessionViewModelTests/testPrepareTemporaryRecordingPassesPauseAdjustedTimelineToReviewMediaComposer --filter VideoRecordingTimelineTests/testPresentationTimeExcludesPausedDuration --filter ReviewMediaComposerTests/testComposeVideoWithAudioUsesTimelineOffsetToSelectMatchingSourceWindow` -> `8 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --jobs 1 --filter LiveMediaCaptureTimelineTests --filter LiveSessionViewModelTests --filter VideoRecordingTimelineTests --filter ReviewMediaComposerTests --filter LiveSessionFinalizationRecoveryTests --filter LiveReviewSourcePresentationTests --filter CameraOverlayPlacementTests` -> `81 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --jobs 1` -> `262 tests, 0 failures`
- Direct Python invocation of `tests/test_live_review_media_sync.py` test functions -> all five passed; `python3 -m pytest ...` remains blocked because this local Python environment has no `pytest`.
- `python3 scripts/diagnose_issue24_media_timeline.py /Users/yann.jy/Documents/InsightKit/Records/20260702-2109-live-record-74ee0db8` -> `failures: []`
- `python3 scripts/verify_project_normalization.py` -> `status: passed`; proof `logs/diagnostics/2026-07-02/project-normalization-20260702-215915/proof.json`
