# Use Linear task truth with a GitHub execution mirror

Status: accepted

## Context

Humans need one project-management surface, while the installed Symphony adapter, repository automation, pull requests, and checks operate on GitHub. Maintaining independent Linear and GitHub task queues would let priority and status diverge.

On 2026-08-26, native two-way issue sync was reproduced for `YannJY02/AutoTranscribe` in both directions. Title, description, labels, coarse open/closed state, and comments inside the GitHub-synced Linear thread propagated. Linear project membership and detailed workflow state did not propagate because GitHub Projects are not part of issue sync.

## Decision

The Linear project `InsightKit / AutoTranscribe` is canonical for task contracts, project membership, priority, relations, assignment, and detailed status. Native two-way sync creates a GitHub Issue execution mirror. When synchronized task fields conflict, Linear wins.

GitHub remains canonical for repository delivery facts: issue number, branch, commits, pull request, review, checks, merge state, and stored proof. Symphony may continue polling the GitHub mirror and its shared `ready-for-agent` label.

GitHub-created issues are supported intake. They enter the Linear team Backlog and must be assigned to the canonical Linear project during triage. GitHub Projects are not an active planning surface.

## Consequences

- A task is created and planned once in Linear; its GitHub Issue is a synchronized execution projection.
- `Done` and `Canceled` close the GitHub mirror; other Linear states remain GitHub-open.
- Linear-to-GitHub comments must be replies in the GitHub-synced Linear thread. Other Linear comments are private by design.
- The repository task contract and deterministic preflight remain unchanged because the synchronized GitHub body is what Symphony reads.
- PRs and CI remain GitHub-native and link back to the Linear identifier.
- ADR 0007 is superseded.
