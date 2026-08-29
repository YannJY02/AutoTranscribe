# Issue tracker: Linear with a GitHub execution mirror

The [InsightKit / AutoTranscribe Linear project](https://linear.app/yannjy/project/insightkit-autotranscribe-a2f3a38cd145) is the canonical task and PRD source. Native two-way issue sync mirrors tasks to `YannJY02/AutoTranscribe`, where Symphony, branches, PRs, CI, and repository evidence operate. If synchronized task fields conflict, repair them in Linear and allow the integration to update GitHub.

GitHub Projects are migration history, not an active board. A GitHub-created issue is valid intake: it appears in the Linear team Backlog, then must be admitted to the canonical Linear project during triage because Linear projects themselves do not sync.

## Field ownership

| Field | Canonical surface | Mirror or delivery behavior |
| --- | --- | --- |
| Project, priority, detailed status, cycle, milestone | Linear | GitHub Project fields are ignored |
| Title, description, assignee, labels, sub-issues | Linear after triage | Native two-way sync updates GitHub |
| Open or closed | Linear `Done`/`Canceled` | GitHub has only the coarser open/closed state |
| Branch, commit, PR, review, checks, merge | GitHub | Linear displays linked delivery activity |
| Task discussion | Linear | Reply inside the GitHub-synced Linear thread to publish to GitHub; other Linear comments remain private |
| Build, test, app proof, release evidence | Repository and GitHub | Link the evidence back to the Linear task |

## Agent task contract

Create unattended tasks in Linear with the same sections as `.github/ISSUE_TEMPLATE/agent-task.yml`: Goal, Context, Boundary, Acceptance, Verification, Resource class, Blockers, and Human gates. The synchronized GitHub body must pass preflight before `ready-for-agent` is applied.

- `isolated`: documentation, analysis, unit tests, or code that does not launch or install the app or use shared runtime state.
- `exclusive-macos`: packaging, installed-app, XCUITest, capture, TCC, performance, canonical Records, or shared Unix socket work.
- Blockers must be `None` or explicit `#<issue>` references; every referenced issue must be closed.
- Human gates must be `None` before dispatch. Otherwise use `ready-for-human` or `needs-info`.

Validate before dispatch:

```bash
python3.11 scripts/agent_harness.py issue-preflight --issue <number>
```

## Operations and intake

- Preferred create/update: use the Linear connector in team `YannJY`, assign the canonical project, and set the shared labels there.
- GitHub ingress: `gh issue create --title "..." --body-file <file>`; then triage the synchronized Linear issue into the project.
- Execution read: `gh issue view <number> --comments`.
- Claim: assign the synchronized task and verify the assignment on both surfaces.
- Synced comments: on Linear, reply to the thread whose first message says it is synced to GitHub; a new top-level Linear comment is intentionally private.

Only claim open, unassigned, unblocked synchronized issues whose sole triage-state label is `ready-for-agent`. Assignment is the first execution write. Successful automation removes `ready-for-agent`, adds `ready-for-human`, and leaves the issue open. A linked PR may update detailed status through configured native PR automation; otherwise update it in Linear during human handoff. Do not claim a detailed Linear status change unless it is verified on Linear. Automation never merges the PR or marks the Linear task `Done`.

## Dependencies and frontier

Use Linear parent/sub-issues and relations as the planning model; confirm their synchronized GitHub mirrors before dispatch. The runnable frontier contains open children whose blockers are closed, which are unassigned, and which pass the agent task contract. Keep explicit blocker references in the body when Symphony preflight needs a GitHub issue number.

## Pull requests

PRs are delivery and review surfaces, not intake. Preflight reads the Linear identifier from the verified `linear-code` linkback comment; include it in the branch name and PR title so Linear attaches the PR. Each implementation PR links its synchronized GitHub issue and harness evidence. Required checks must pass before `ready-for-human`; human acceptance and merge remain separate.

## Existing local markdown

`.scratch/` and historical issue-style files under `docs/Legacy/matt-workflow-library/` are migration/reference material, not active tracker state. Re-check useful unfinished work against current code and selectively create a Linear issue. Do not bulk-convert or update historical status lines as if they were live labels.
