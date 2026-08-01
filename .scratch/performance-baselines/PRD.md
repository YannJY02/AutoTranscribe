# Installed-App Performance Baselines PRD

Status: ready-for-agent

## Problem Statement

InsightKit has a canonical benchmark protocol and a frozen fixture corpus, but
it does not yet have installed-app baseline evidence for the critical user
journeys. Optimizations and budgets must wait for measured traces.

## Goal

Collect comparable cold and warm installed-app baselines one GitHub ticket at
a time, preserve every raw run, and rank only trace-backed bottlenecks. After
all baseline slices complete, use the evidence to set budgets and publish
separate implementation tickets.

## Constraints

- Verify the frozen corpus before every baseline cohort.
- Keep fixed cohort and scenario parameters unchanged within a ticket.
- Preserve failures and outliers.
- Keep quality checks beside speed and resource metrics.
- Do not implement speculative optimizations in a baseline issue.
- Use one local issue and one fresh task per external ticket.

## Published Issues

- `.scratch/performance-baselines/issues/01-measure-launch-workspace-and-interaction-baseline.md`

## Comments

### 2026-08-01 - Codex

Published the first baseline slice after the fixture prerequisite completed.
Later tasks should promote GitHub issues #5-#10 into this lane only when their
dependencies are ready.
