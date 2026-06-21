# Create Live Transcript Pipeline seam

Status: ready-for-human

## Parent

`.scratch/live-workspace-session/PRD.md`

## What to build

Create the first deep module seam for Live Transcript Delta ingestion. The slice should let tests exercise the transcript pipeline decision path without requiring full Live Workspace UI state, real audio capture, or a real Sidecar. The Live Session module should remain the adapter that applies user-visible Capture State, transcript segment, metrics, and provider-degradation state.

User stories covered: 1, 3, 4, 5, 6, 8, 9, 11, 15.

## Acceptance criteria

- [x] A focused transcript pipeline seam exists and has a smaller interface than the current Live Session module path.
- [x] The seam can represent successful chunk ingestion, empty ASR output, refresh-needed, refresh-paused, and provider-degradation outcomes.
- [x] Focused Swift tests cover the pipeline outcome rules without constructing the full Live Workspace UI.
- [x] Existing Live Session adapter behavior remains covered by targeted tests.
- [x] The slice does not change Record save, Export Document, or public release-channel behavior.

## Blocked by

None - can start immediately.

## Comments

### 2026-06-20 - Codex

Implemented the first Live Transcript Pipeline seam.

Changed:
- Added `LiveTranscriptPipeline`, `LiveTranscriptPipelineRuntime`, `InsightRPCLiveTranscriptPipelineRuntime`, context, outcome, refresh, pause, and error-classifier types.
- Added focused `LiveTranscriptPipelineTests` that exercise empty ASR output, successful ingestion without refresh, refresh success, already-paused refresh, provider auth degradation, and provider timeout degradation without constructing the full Live Workspace UI.
- Added `Live Transcript Pipeline` to the macOS App context glossary.

Evidence so far:
- `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests` -> `6 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` -> `16 tests, 0 failures`
- `swift test --package-path macos/InsightKitApp` -> `123 tests, 0 failures`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_project_normalization.py` -> `status: passed`
- Proof: `logs/diagnostics/2026-06-20/project-normalization-20260620-103420/proof.json`
- `PYTHONPATH=. /Users/yann.jy/miniconda3/bin/python3.11 -m pytest -q --tb=short` -> `203 passed, 1 warning`
- `/Users/yann.jy/miniconda3/bin/python3.11 scripts/verify_release_closure.py` -> `status: passed_local_with_external_blockers`
- Release closure proof: `logs/diagnostics/2026-06-20/release-closure-20260620-103148/proof.json`
- `git diff --check` -> passed
