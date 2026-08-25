# Issue tracker: GitHub

GitHub Issues are the only active task and PRD source. Use `gh`; infer the repository from the current checkout.

## Agent task contract

Create unattended tasks with `.github/ISSUE_TEMPLATE/agent-task.yml`. Before applying `ready-for-agent`, require non-empty Goal, Context, Boundary, Acceptance, Verification, Resource class, Blockers, and Human gates sections.

- `isolated`: documentation, analysis, unit tests, or code that does not launch or install the app or use shared runtime state.
- `exclusive-macos`: packaging, installed-app, XCUITest, capture, TCC, performance, canonical Records, or shared Unix socket work.
- Blockers must be `None` or explicit `#<issue>` references; every referenced issue must be closed.
- Human gates must be `None` before dispatch. Otherwise use `ready-for-human` or `needs-info`.

Validate before dispatch:

```bash
python3.11 scripts/agent_harness.py issue-preflight --issue <number>
```

## Operations

- Create: `gh issue create --title "..." --body-file <file>`
- Read: `gh issue view <number> --comments`
- Comment: `gh issue comment <number> --body-file <file>`
- Label: `gh issue edit <number> --add-label <label> --remove-label <label>`
- Claim: `gh issue edit <number> --add-assignee @me`

Only claim open, unassigned, unblocked issues whose sole triage-state label is `ready-for-agent`. Assignment is the first write. Successful automation removes `ready-for-agent`, adds `ready-for-human`, and leaves the issue open. It never merges the PR or closes the issue.

## Dependencies and frontier

Use GitHub sub-issues and native dependencies where available. The runnable frontier contains open children whose blockers are closed, which are unassigned, and which pass the agent task contract. If native dependencies are unavailable, keep `Blocked by: #<number>` references in the Blockers section.

## Pull requests

PRs are delivery and review surfaces, not intake. Each implementation PR links its issue and harness evidence. Required checks must pass before `ready-for-human`; human acceptance and merge remain separate.

## Existing local markdown

`.scratch/` and historical issue-style files under `docs/Legacy/matt-workflow-library/` are migration/reference material, not active tracker state. Re-check useful unfinished work against current code and selectively create a GitHub Issue. Do not bulk-convert or update historical status lines as if they were live labels.
