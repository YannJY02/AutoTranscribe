# Use GitHub Issues as the active engineering tracker

Status: superseded by ADR 0008

## Context

Local PRD and issue files under `.scratch/` predated the repository's agent orchestration. Keeping live state in both local markdown and GitHub would let priority, blockers, assignment, and review status diverge. Symphony also requires a queryable tracker with stable labels and assignment state.

## Decision

GitHub Issues are the only active task and PRD source. Pull requests carry delivery and review evidence but are not intake. `.scratch/` and issue-like Legacy documents remain migration and provenance material; useful unfinished work is revalidated against current code before being promoted into a GitHub Issue.

This decision supersedes only the `.scratch/public-distribution-readiness/` tracking-location statements in ADR 0003. ADR 0003's separation between local readiness and public-distribution readiness remains accepted.

## Consequences

- Active priority, blockers, assignment, and triage state live on GitHub.
- Unattended work must pass the repository's Agent Task contract before receiving `ready-for-agent`.
- Successful agent work stops at `ready-for-human`; human acceptance and merge remain separate.
- Linear is the human portfolio view for objectives, priority, and review attention. It links to GitHub execution records and must not become a competing task state store.
- A future migration to Symphony's native Linear tracker must replace this ADR and migrate open state once; a permanent two-way active queue is not allowed.

## Supersession

ADR 0008 replaces the active-tracker decision after native Linear/GitHub two-way synchronization was configured and reproduced in both directions. This file remains the historical record of the GitHub-only phase.
