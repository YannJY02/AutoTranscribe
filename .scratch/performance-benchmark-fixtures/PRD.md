# Performance Benchmark Fixture Corpus PRD

Status: ready-for-human

## Problem Statement

The canonical installed-app benchmark protocol cannot produce comparable
baselines until its media, Record Folder collections, and replay inputs exist
as sanitized, frozen, locally verifiable assets.

## Goal

Materialize one versioned corpus that later performance tickets can verify and
reuse without reading private Record Folders or committing large media.

## Requirements

- Four synthetic M4A fixtures: 5-minute Chinese, English, and mixed, plus a
  60-minute mixed fixture.
- MP4 companions for both mixed fixtures using the same audio packet stream.
- Safe reference transcripts and Smart Minutes expectations.
- Deterministic, complete Record Folder collections of 100 and 1,000 records.
- Frozen generator revision/version, seed, scenario inputs, inventories,
  formats, durations, byte sizes, and SHA-256 pins.
- A verifier and reproduction/acquisition instructions.

## Out of Scope

- Collecting installed-app baselines.
- Choosing performance budgets.
- Implementing optimizations.

## Published Issue

- `.scratch/performance-benchmark-fixtures/issues/01-materialize-canonical-performance-fixture-corpus.md`

## Comments

### 2026-08-01 - Codex

Created as the local Matt workflow ledger for GitHub issue #11. The one
published issue is implemented and awaiting human review.
