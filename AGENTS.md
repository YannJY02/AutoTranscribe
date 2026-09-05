# InsightKit Agent Instructions

## Pull request worktrees

Start each new pull-request task in a dedicated Git worktree based on `main`, with a unique branch for that pull request.

## Agent workflow

### Issue tracker

The [InsightKit / AutoTranscribe Linear project](https://linear.app/yannjy/project/insightkit-autotranscribe-a2f3a38cd145) is the canonical task, PRD, priority, and detailed-status source. Native two-way sync mirrors issues into `YannJY02/AutoTranscribe`; GitHub remains the repository-facing execution surface for Symphony, PRs, CI, and evidence. Resolve conflicting task fields in Linear. Existing `.scratch/` files are historical migration material. See `docs/agents/issue-tracker.md`.

### Proactive intake

Classify new user input as discussion, question, investigation, bug, or feature. Keep ordinary questions conversational. When discussion converges on repository work, use the Matt workflow to make the task contract explicit, show one concise Linear draft, and ask once whether to formalize and enter automated delivery. After approval, create the Linear task in the canonical project and let native sync create the GitHub mirror; do not ask again for routine in-scope execution. Preserve separate human gates for credentials, destructive actions, product judgment, and merge.

### Delivery surface

GitHub Issues mirror Linear tasks and carry repository-native links to branches, PRs, checks, and Symphony dispatch labels. Do not create an independent task state in GitHub Projects. See `docs/agents/tool-boundaries.md`.

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

Moved historical originals and converted Matt workflow views live under `docs/Legacy/matt-workflow-library/`. Start from its `manifest.md`; promote useful unfinished work into a current Linear issue and let native sync create the GitHub mirror, never back into the active queue as local markdown.
