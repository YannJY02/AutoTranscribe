---
name: Agentic Issue Triage
description: Checks new issues against the repository task contract without authorizing execution
on:
  issues:
    types: [opened, reopened, edited]
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  copilot-requests: write
engine: copilot
strict: true
network: defaults
tools:
  github:
    mode: gh-proxy
    allowed-repos: [yannjy02/autotranscribe]
    toolsets: [issues]
    min-integrity: approved
safe-outputs:
  add-labels:
    max: 1
  remove-labels:
    max: 1
  add-comment:
    max: 1
  noop:
timeout-minutes: 10
---

# Issue contract triage

Inspect only the triggering issue and `docs/agents/issue-tracker.md`.

1. If this is a manual run without an issue, call `noop`.
2. Check for non-empty Goal, Context, Boundary, Acceptance, Verification, Resource class, Blockers, and Human gates sections.
3. If any section is missing, the resource class is not exactly `isolated` or `exclusive-macos`, or a human gate remains, add `needs-info`, remove `needs-triage` if present, and comment once with the exact missing items.
4. Otherwise add `needs-triage`, remove `needs-info` if present, and comment that the contract is complete but human authorization is still required.

Never add `ready-for-agent`, `ready-for-human`, or `wontfix`; never assign, close, or edit an issue.
