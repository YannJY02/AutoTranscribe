# Use GitHub Issues as the active engineering tracker

Status: accepted

## Context

Local PRD and issue files under `.scratch/` predated the repository's agent orchestration. Keeping live state in both local markdown and GitHub would let priority, blockers, assignment, and review status diverge. Symphony also requires a queryable tracker with stable labels and assignment state.

## Decision

GitHub Issues are the only active task and PRD source. Pull requests carry delivery and review evidence but are not intake. `.scratch/` and issue-like Legacy documents remain migration and provenance material; useful unfinished work is revalidated against current code before being promoted into a GitHub Issue.

This decision supersedes only the `.scratch/public-distribution-readiness/` tracking-location statements in ADR 0003. ADR 0003's separation between local readiness and public-distribution readiness remains accepted.

## Consequences

- Active priority, blockers, assignment, and triage state live on GitHub.
- Unattended work must pass the repository's Agent Task contract before receiving `ready-for-agent`.
- Successful agent work stops at `ready-for-human`; human acceptance and merge remain separate.
- Huly, Plane, and GitHub Projects may provide views or portfolio planning later, but they must not become competing task state stores.
