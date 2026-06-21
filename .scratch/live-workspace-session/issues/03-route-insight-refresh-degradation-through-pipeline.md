# Route Insight Refresh degradation through pipeline

Status: ready-for-human

## Parent

`.scratch/live-workspace-session/PRD.md`

## What to build

Route Insight Refresh decisions and provider-degradation behavior through the pipeline seam. The slice should preserve the rule that live transcription continues when provider auth or probe timeout pauses insight generation.

User stories covered: 4, 5, 6, 8, 9, 11, 12, 15.

## Acceptance criteria

- [x] Refresh cadence still follows the current Live Insight Coordinator behavior.
- [x] Provider auth failure pauses Insight Refresh while preserving transcript ingestion.
- [x] Provider probe timeout pauses Insight Refresh while preserving transcript ingestion.
- [x] Capture State, analysis runtime state, provider metric, and user-facing error message remain stable for degradation paths.
- [x] Focused Swift tests cover refresh-needed, refresh-success, auth-failure, and timeout paths.

## Blocked by

- `.scratch/live-workspace-session/issues/02-route-live-transcript-delta-through-pipeline.md`

## Comments

### 2026-06-21 - Codex

Implemented Insight Refresh degradation routing through the Live Transcript Pipeline seam.

Changed:
- Kept `LiveSessionViewModel.processChunk` crossing the `LiveTranscriptProcessing` seam for refresh decisions and provider-degradation outcomes.
- Applied successful pipeline refresh results back into the Live Workspace workbench while clearing the suspended-refresh state.
- Applied pipeline pause outcomes for provider auth failure and probe timeout by pausing Insight Refresh, preserving transcript ingestion, keeping Capture State stable, and surfacing the provider metric plus user-facing error message.
- Added focused Live Session adapter coverage for refresh success, auth failure, and provider timeout paths; retained pipeline coverage for refresh-needed and degradation decisions.

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
