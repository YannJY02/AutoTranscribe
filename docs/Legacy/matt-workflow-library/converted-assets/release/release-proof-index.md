# Release Proof Index

Status: historical-reference

## Purpose

This file translates moved release evidence into a proof index. A proof index is a readable list of evidence: commands, proof JSON files, app paths, screenshots, and blockers.

Original release evidence sources:

- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-05-23-insightkit-goal-evidence.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-05-24-insightkit-release-verification.md`
- `docs/Legacy/matt-workflow-library/original-assets/docs/plans/2026-05-26-insightkit-release-readiness-status.md`

## Current Reading Rule

Use this file as history. For current release claims, run the current release scripts and read fresh proof JSON.

Current release vocabulary lives in:
- `docs/contexts/release-workflow/CONTEXT.md`

## Historical Local Readiness Evidence

The moved release ledgers record that the local personal-user loop had evidence for:

- real media import;
- transcript persistence;
- Smart Minutes generation;
- time-bound notes;
- search and record recovery;
- Markdown/PDF export;
- packaged-app URL import smoke;
- visual GUI proof;
- secret hygiene and UI hygiene checks;
- local release preflight with external blockers separated.

Important historical proof examples preserved in the moved ledgers:

- `logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/proof.json`
- `logs/diagnostics/2026-05-26/current-build-visual-gui-proof-20260526-113744.json`
- `logs/diagnostics/2026-05-26/release-readiness-status-20260526-120328/proof.json`
- `logs/diagnostics/2026-05-26/goal-evidence-status-20260526-121834/proof.json`
- `logs/diagnostics/2026-05-26/secret-hygiene-20260526-121300/proof.json`
- `logs/diagnostics/2026-05-26/ui-hygiene-20260526-121736/proof.json`

## Historical Blockers

The moved release ledgers separate local readiness from public distribution:

- Local/internal QA was supported by local app evidence.
- Developer ID distribution required owner-controlled Apple Developer Program access, Developer ID signing, hardened runtime, notarization, and stapling.
- Mac App Store distribution required App Store signing, sandboxed entitlement strategy, privacy policy URL, and App Store Connect answers.

## Current Use Rule

Do not copy a historical proof path into a current claim without checking whether a fresher proof exists. If release behavior changed, run the current release gate again.

## Current Gate Examples

- `python3 scripts/verify_release_readiness.py`
- `python3 scripts/verify_goal_evidence.py`
- `python3 scripts/verify_secret_hygiene.py`
- `python3 scripts/verify_ui_hygiene.py`
- `scripts/release_preflight.sh`
- `python3 scripts/run_packaged_app_url_import_smoke.py`

## Non-Claim

This index does not claim Distribution Ready. It preserves the historical separation between Local Release Ready and external distribution blockers.
