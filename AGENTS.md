# InsightKit Agent Instructions

## Pull request worktrees

Start each new pull-request task in a dedicated Git worktree based on `main`, with a unique branch for that pull request.

## Agent workflow

### Issue tracker

GitHub Issues are the only active task and PRD source. Existing `.scratch/` files are historical migration material. See `docs/agents/issue-tracker.md`.

### Human planning

Linear is the human portfolio view for objectives, priority, and review attention. It links to GitHub execution records and must not duplicate their task state. See `docs/agents/tool-boundaries.md`.

### Triage labels

The tracker uses the default five-role triage vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

This repo uses a multi-context domain-doc layout with a root `CONTEXT-MAP.md`, context-specific `CONTEXT.md` files, and shared ADRs under `docs/adr/`. See `docs/agents/domain.md`.

### Loop engineering

Matt workflow work runs in sequential safe loops: define the goal, load the relevant context, bound the action, verify with the narrowest useful gate, feed failures into the next action, and record the proof. See `docs/agents/loop-engineering.md`.

### Harness

Run `python3.11 scripts/agent_harness.py doctor` before unattended work and `python3.11 scripts/agent_harness.py verify --mode full` before handoff. Installed-app, GUI, capture, and performance checks must use the shared resource lock described in `docs/agents/harness.md`.

Use the repository `native-app-proof` skill for visible macOS behavior and `promote-feedback` when a repeated review or bug lesson must become Docs, Skill, Lint, or a Structural Test.

### Legacy workflow library

Moved historical originals and converted Matt workflow views live under `docs/Legacy/matt-workflow-library/`. Start from its `manifest.md`; promote useful unfinished work into a current GitHub Issue, never back into the active queue as local markdown.
