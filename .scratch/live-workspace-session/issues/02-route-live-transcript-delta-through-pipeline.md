# Route Live Transcript Delta through pipeline

Status: ready-for-human

## Parent

`.scratch/live-workspace-session/PRD.md`

## What to build

Route the successful Live Transcript Delta path through the new pipeline seam. The slice should preserve transcript segment ordering, first segment timing, latency, queue depth, and segment-ingested metrics while reducing duplicated ViewModel state mutation.

User stories covered: 3, 6, 8, 9, 11, 15.

## Acceptance criteria

- [x] Successful ASR chunk output still becomes ordered transcript segments in the Live Workspace.
- [x] Empty ASR output still updates Capture State and chunk index without adding transcript segments.
- [x] Metrics for queue depth, first segment time, latency, and ingested segment count remain correct.
- [x] Existing focused Swift tests pass, and new tests cover the routed success and empty-output paths.
- [x] No Python runtime or release-channel behavior changes are introduced.

## Blocked by

- `.scratch/live-workspace-session/issues/01-create-live-transcript-pipeline-seam.md`

## Comments

### 2026-06-21 - Codex

Implemented Live Transcript Delta routing through the Live Transcript Pipeline.

Changed:
- Added a `LiveTranscriptProcessing` seam so `LiveSessionViewModel` can depend on the transcript pipeline interface.
- Routed `LiveSessionViewModel.processChunk` through `LiveTranscriptPipeline` instead of duplicating ASR transcription, transcript-delta append, deduplication, refresh decisions, and metrics updates in the adapter.
- Kept the Live Session module as the app-facing adapter that applies pipeline outcomes to Capture State, Transcript Segment ordering, Live Workspace metrics, provider-degradation state, and optional Insight Refresh workbench updates.
- Added focused Live Session adapter tests for successful pipeline output and empty pipeline output.

Verification:
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testProcessChunkApplies` -> `2 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` -> `18 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests` -> `6 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp` -> `125 tests, 0 failures`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest tests/test_verify_project_normalization.py -q` -> `11 passed`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-21/project-normalization-20260621-092658/proof.json`
- `git diff --check` -> passed

Out of scope preserved:
- No Python runtime behavior changes were made for this slice.
- No release-channel, Record save, Export Document, Runtime Warmup, Smart Minutes, Time-Bound Note, or Media Seek behavior was intentionally changed.
