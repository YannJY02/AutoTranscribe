# Product Quality SQL Oracle TDD Evidence

## Source and journey

Source: the user-approved first Product Quality Oracle increment.

- A completed real-media import must prove its persisted meeting, job,
  transcript, FTS, and insight-package state through read-only SQLite queries.
- The temporary-sidecar and packaged-app import journeys must store the result
  under `proof.json.oracles.database` and fail when any assertion fails.

## RED and GREEN checkpoints

| Behavior | RED evidence | GREEN evidence |
| --- | --- | --- |
| Read-only database evaluation contract | `da48a53`; `uv run --no-project --with pytest python -m pytest tests/test_product_quality_sql_oracle.py -q` failed during collection because `evaluate_database_oracle` did not exist | `1a46bb3`; the same target passed 2/2 tests |
| Existing packaged-app smoke helpers remain compatible | Not a new logic branch | `uv run --no-project --with pytest python -m pytest tests/test_product_quality_sql_oracle.py tests/test_packaged_app_url_import_smoke.py -q` passed 4/4 tests |
| Missing real FTS index entries are detected | `016d577`; deleting one index entry still produced `passed=true` | `bc8eaf2`; the Oracle reads actual indexed document IDs through `fts5vocab` and the targeted suite passed 5/5 tests |

## Test specification

| Guarantee | Test or command | Type | Result |
| --- | --- | --- | --- |
| A completed import passes every database assertion | `test_database_oracle_passes_for_completed_import` | integration | PASS |
| Incomplete job state and invalid segment timing are named as failed assertions | `test_database_oracle_reports_invalid_job_and_timeline` | integration | PASS |
| A segment missing from the real FTS index fails `fts_index_complete` | `test_database_oracle_detects_segment_missing_from_fts_index` | integration | PASS |
| The full non-model Python suite remains green | `scripts/run_python_tests.sh --cov` through an isolated `uv` environment | regression | PASS: 284 passed, 2 skipped, 3 deselected; 80.86% coverage |
| A real 30-second media import produces a passing database Oracle and export proof | `python -m scripts.run_real_import_e2e` with isolated `/tmp` storage | product journey | PASS |

## Coverage and scope

The repository Python suite reported 80.86% coverage, above its 70% gate. The
real trial proof is `/private/tmp/insightkit-sql-oracle.32hi9S/proof.json`; all
13 database assertions passed and the temporary sidecar stopped cleanly.

This increment checks persisted consistency, not transcript semantic accuracy,
visual quality, or audio/video synchronization. Those require separate Oracles.
