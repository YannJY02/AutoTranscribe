# Shrink Live Session adapter surface

Status: ready-for-human

## Parent

`.scratch/live-workspace-session/PRD.md`

## What to build

Reduce the Live Session module surface after transcript pipeline routing is complete. The slice should leave the Live Session module as the app-facing adapter for Capture State, Session Phase, Smart Minutes, Time-Bound Notes, Media Seek, and Record save, while keeping transcript pipeline rules behind their module seam.

User stories covered: 2, 7, 8, 9, 10, 11, 12, 13, 15.

## Acceptance criteria

- [x] Transcript pipeline rules no longer require reading the full Live Session module to understand.
- [x] Runtime Warmup backlog and retry behavior remain unchanged.
- [x] Record save, notes, Media Seek, Smart Minutes, and UI-test mode behavior remain unchanged.
- [x] Targeted Live Session and transcript pipeline Swift tests pass.
- [x] If local release readiness is claimed, the release Closure Gate is rerun and still reports local readiness or clearly bounded external blockers.

## Blocked by

- `.scratch/live-workspace-session/issues/03-route-insight-refresh-degradation-through-pipeline.md`

## Comments

### 2026-06-21 - Codex

Completed the Live Session adapter surface shrink as a verification-only closeout over issues 02 and 03.

Changed:
- No additional production code was changed for this issue.
- Verified transcript ingestion, deduplication, Live Transcript Delta, refresh cadence, provider-degradation classification, and transcript pipeline metrics now live behind `LiveTranscriptPipeline` / `LiveTranscriptProcessing`.
- Kept `LiveSessionViewModel` as the app-facing adapter for Capture State, Session Phase, Runtime Warmup queue state, Smart Minutes, Time-Bound Notes, Media Seek, and Record save.
- Left Runtime Warmup, Record save, notes, Media Seek, Smart Minutes, UI-test mode, Python runtime, and release-channel behavior out of this slice.

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
