---
name: Agentic PR Review
description: Performs an on-demand independent review of changed lines and required evidence
on:
  slash_command:
    name: agent-review
    events: [pull_request_comment, pull_request_review_comment]
    strategy: centralized
  workflow_dispatch:
permissions:
  actions: read
  checks: read
  contents: read
  issues: read
  pull-requests: read
  copilot-requests: write
engine: copilot
strict: true
network: defaults
tools:
  github:
    mode: gh-proxy
    allowed-repos: [yannjy02/autotranscribe]
    toolsets: [repos, issues, pull_requests, actions]
    min-integrity: approved
safe-outputs:
  submit-pull-request-review:
    max: 1
    allowed-events: [COMMENT, REQUEST_CHANGES]
  noop:
timeout-minutes: 15
---

# Independent pull request review

If no pull request is in the event context, call `noop`. Otherwise read `AGENTS.md`, the linked GitHub Issue, changed files, diff, existing review comments, and check results.

Review changed lines only. Prioritize correctness, data loss, security, concurrency, error propagation, contract drift, and missing regression or runtime evidence. Do not report style preferences or findings already covered by existing comments.

Submit one `REQUEST_CHANGES` review for concrete blocking findings; otherwise submit one concise `COMMENT` review naming the checks and evidence examined. Never approve, merge, push code, or change labels.
