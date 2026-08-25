---
name: Agentic Documentation Gardener
description: Finds one bounded repository-knowledge drift and records it for human triage
on:
  schedule: weekly on monday
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  copilot-requests: write
engine: copilot
model: gpt-4.1
strict: true
network: defaults
tools:
  github:
    mode: gh-proxy
    allowed-repos: [yannjy02/autotranscribe]
    toolsets: [repos, issues]
    min-integrity: approved
safe-outputs:
  create-issue:
    max: 1
    expires: 7d
    title-prefix: "[Harness docs] "
    labels: [harness:maintenance, needs-triage]
  noop:
timeout-minutes: 15
---

# Repository knowledge gardening

Read `AGENTS.md`, `CONTEXT-MAP.md`, `docs/agents/`, context documents, ADRs, and recent merged changes. Search open issues before reporting anything.

Find at most one concrete contradiction, stale path, duplicated rule, or missing durable fact that would mislead a coding agent. Create one deduplicated issue with evidence, affected paths, the smallest repair, and a verification command. If no material drift exists or an open issue already covers it, call `noop`.

Do not edit files, create pull requests, or turn speculative cleanup into work.
