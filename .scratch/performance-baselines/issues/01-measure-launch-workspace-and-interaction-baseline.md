# Measure Launch, Workspace, and Interaction Baseline

Status: ready-for-agent

## Parent

`.scratch/performance-baselines/PRD.md`

## External Ticket

<https://github.com/YannJY02/AutoTranscribe/issues/4>

## What to measure

Under the canonical installed-app benchmark protocol, collect reproducible
baselines and root-cause traces for launch-to-usable Home Workspace, workspace
navigation and loading, input response, Record list and long transcript
scrolling, and window resizing.

## Acceptance Criteria

- [ ] The frozen fixture corpus verifies before measurement.
- [ ] The installed app, sidecar, Mac, tool, configuration, and scenario cohort is fully pinned.
- [ ] Cold launch and interaction scenarios have 3 runs; warm scenarios have 10 runs.
- [ ] Every run, including failures and outliers, is retained.
- [ ] Launch, navigation, input response, scroll hitch, and resize hitch metrics follow the canonical metric contract.
- [ ] Both 100- and 1,000-record collections are represented where the protocol requires them.
- [ ] Main-thread stalls, render churn, blocking I/O, and state-update amplification are traced where present.
- [ ] Raw artifacts, `manifest.json`, `runs.jsonl`, `quality.json`, and `summary.md` are linked from the issue resolution.
- [ ] Statistics include individual values, median, minimum, maximum, median absolute deviation, success rate, and failure count.
- [ ] Ranked hotspots are trace-backed; no optimization is implemented in this issue.

## Blocked by

`.scratch/performance-benchmark-fixtures/issues/01-materialize-canonical-performance-fixture-corpus.md` - completed and awaiting human review.

## Verification Plan

- Run the corpus verifier and record its result in the cohort manifest.
- Use the Canonical Installed App and protocol-defined native measurement tools.
- Validate raw-artifact inventory hashes and all required evidence files.
- Run independent Standards and Spec review before resolving the ticket.

## Comments

### 2026-08-01 - Codex

Promoted from GitHub issue #4 as the next dependency-clean ticket. No baseline
work has started in this task.
