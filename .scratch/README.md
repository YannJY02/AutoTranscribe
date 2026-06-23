# Scratch Work Index

Status: current
Last reviewed: 2026-06-21

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

## Default Next Step

There is currently no `ready-for-agent` issue in this queue. If the owner asks for autonomous implementation, first create or promote a new bounded `.scratch/<feature>/issues/<NN>-<slug>.md` issue with `Status: ready-for-agent`, then run the Matt workflow loop from `docs/agents/loop-engineering.md`.
