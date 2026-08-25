---
name: Agentic CI Doctor
description: Investigates a failed CI run and creates one deduplicated diagnostic issue
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main, "codex/**"]
  workflow_dispatch:
permissions:
  actions: read
  checks: read
  contents: read
  issues: read
  pull-requests: read
  copilot-requests: write
engine: copilot
model: gpt-4.1
strict: true
network: defaults
tools:
  github:
    mode: gh-proxy
    allowed-repos: [yannjy02/autotranscribe]
    toolsets: [repos, issues, pull_requests, actions]
    min-integrity: approved
safe-outputs:
  create-issue:
    max: 1
    expires: 3d
    title-prefix: "[CI doctor] "
    labels: [harness:maintenance, needs-triage]
  noop:
timeout-minutes: 15
---

# CI failure investigation

If this is a successful CI run or a manual run without a failed run identifier, call `noop`.

For the failed `CI` run, inspect failed jobs, failed steps, relevant log tails, commit, branch or pull request, and recent similar open issues. Identify the first actionable root cause and separate repository failures from transient runner or service failures.

Create at most one deduplicated issue containing the failing run URL, exact failed job and step, concise log evidence, likely root cause with confidence, owner, smallest next action, and recheck command. Do not rerun jobs, edit code, push, or merge.
