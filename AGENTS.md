# InsightKit Agent Instructions

## Agent skills

### Issue tracker

Issues and PRDs are tracked as local markdown files under `.scratch/`; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The tracker uses the default five-role triage vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

This repo uses a multi-context domain-doc layout with a root `CONTEXT-MAP.md`, context-specific `CONTEXT.md` files, and shared ADRs under `docs/adr/`. See `docs/agents/domain.md`.

### Loop engineering

Matt workflow work runs in sequential safe loops: define the goal, load the relevant context, bound the action, verify with the narrowest useful gate, feed failures into the next action, and record the proof. See `docs/agents/loop-engineering.md`.

### Legacy workflow library

Moved historical originals and converted Matt workflow views live under `docs/Legacy/matt-workflow-library/`. Start from its `manifest.md`; do not treat historical issue-style files as active work unless they are promoted into `.scratch/` by a current PRD and issue.
