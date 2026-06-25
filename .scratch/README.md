# Scratch Work Index

Status: current
Last reviewed: 2026-06-25

This folder is the current local PRD and issue queue for InsightKit. It is not an archive, and it is not the Legacy workflow library.

## How To Read Status

- `ready-for-agent` means a future agent may pick up the issue without new owner input.
- `ready-for-human` means the issue needs human attention before more autonomous agent work. Read the acceptance criteria and latest comments to distinguish:
  - completed work awaiting human review, when criteria are checked and proof is recorded;
  - owner-controlled work, when criteria are unchecked and the issue asks for release-channel, privacy, Apple account, certificate, or public-distribution decisions.
- Do not redo completed `ready-for-human` issues just because their status is not `ready-for-agent`.
- Do not start owner-controlled public-distribution issues without the project owner choosing the needed release or privacy input.

## Current Work Lanes

| Lane | Role | Current state | Next action |
| --- | --- | --- | --- |
| `project-normalization/` | Normalizes current docs, source roles, ADRs, release vocabulary, integration language, and architecture handoff. | Completed and awaiting human review; acceptance criteria are checked and verifier proof exists. | Use its docs as current authority. Do not reopen unless a new normalization gap appears. |
| `legacy-matt-workflow-library/` | Converts moved historical assets into Matt workflow library assets and records promotion decisions. | Completed and awaiting human review; original assets are in Legacy and converted assets are indexed by the manifest. | Start from `docs/Legacy/matt-workflow-library/manifest.md` only when historical material is relevant. |
| `live-workspace-session/` | Deepens the Live Workspace Session architecture through the Live Transcript Pipeline work. | Completed and awaiting human review; issue comments record Swift/Python verification. | Treat this as the latest completed implementation pass unless the owner asks for the next architecture slice. |
| `public-distribution-readiness/` | Tracks public release channel, privacy policy, App Store answers, Developer ID, and sandbox distribution readiness. | Owner-controlled; acceptance criteria are intentionally unchecked until the owner supplies decisions or credentials. | Ask the owner before acting on these issues. |
| `manual-qa-2026-06-25/` | Records owner-led manual QA against the installed InsightKit app and turns reports into durable local issues. | QA intake active; twenty-three issues filed. Batch dependency triage is recorded in `manual-qa-2026-06-25/triage-dependency-map.md`. Issues 01, 02, 04, 05, 08, 13, 14, and 17 have passed owner retest after their installed fixes. Issue 12 has conditionally passed owner retest when issue 13 does not occur. Issues 03 and 06 have Qwen MLX worker regression coverage and build `20260625094746` installed, and remain `ready-for-human` for guarded owner retest. Issue 07 has a Final Insight Generation timeout fix installed in build `20260625103254` and remains `ready-for-human` for owner retest. Issues 09, 10, and 11 remain `ready-for-human` for owner retest after their installed fixes. Issues 20-23 now have Smart Minutes review-source fixes and are `ready-for-human`. Issues 16, 18, and 19 are `ready-for-agent`; issue 15 is `needs-info` for a concrete diarization sample. | Retest the Smart Minutes review bundle: issue 20 audio, issue 21 video, issue 22 click-to-seek-and-play, and issue 23 single standard media player. After that, the next autonomous targets are issues 18 and 19 for Record naming, or issue 16 for speaker-label editing. Retest issues 03 and 06 cautiously before long live-recording stress tests. |

## Default Next Step

For the manual QA lane, batch triage is current through issue 23 in `.scratch/manual-qa-2026-06-25/triage-dependency-map.md`. Issue 17 has passed owner retest. Issues 20, 21, 22, and 23 are now `ready-for-human` as one Smart Minutes review retest bundle: audio playback, video visibility, click-to-seek-and-play, and one standard audio/video media player. Issues 16, 18, and 19 are `ready-for-agent`; issue 15 is `needs-info` until a concrete failing diarization sample is available. The recommended next implementation target after the Smart Minutes bundle retest is issue 18 or 19 for Records naming, unless speaker-label editing in issue 16 is more urgent. Issues 09, 10, 11, 20, 21, 22, and 23 still need owner retest after their installed fixes. Issues 03 and 06 should be retested cautiously before further long live-recording stress tests because they share the Qwen MLX live-runtime path and issue 06 involves system stability.
