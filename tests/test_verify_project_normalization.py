from pathlib import Path

from scripts.verify_project_normalization import (
    LEGACY_CONVERTED_ASSETS,
    LEGACY_ORIGINAL_ASSETS,
    LEGACY_PROMOTED_STANDARD_REQUIREMENTS,
    LEGACY_STANDARD_SETUP_REQUIREMENTS,
    PUBLIC_DISTRIBUTION_READINESS_ASSETS,
    RELEASE_VOCAB_TERMS,
    SCRATCH_INDEX_REQUIRED_TERMS,
    verify,
)


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_minimal_normalized_repo(root: Path) -> None:
    write(root / "README.md", "# InsightKit\n\nLegacy AutoTranscribe lineage.\n")
    write(root / "AGENTS.md", "# InsightKit Agent Instructions\n\nSee `docs/agents/loop-engineering.md`.\n")
    write(
        root / "docs/agents/loop-engineering.md",
        """# Matt Workflow Loop Engineering

## Purpose

Use this for Matt workflow loops.

## Preconditions

Read repo instructions.

## Standard Loop Packet

Goal Context Boundary Action Verification Feedback Record.

## Matt Workflow Routes

Use review, improve-codebase-architecture, to-prd, to-issues, and implement.

## Verification Ladder

Check progressively.

## Required Gates

Run verify_project_normalization.py and verify_release_closure.py.

## Feedback Packet

Use feedback.

## Stop Rules

External Blocker and Owner-Controlled Input stay owner-controlled.

## Record Keeping

Record proof paths.
""",
    )
    write(
        root / "docs/architecture-review-handoff.md",
        """# Architecture Review Handoff

## Read First

Read contexts.

## Accepted ADRs

- 0001-native
- 0002-rpc
- 0003-release
- 0004-record-folder

## Current Source Assets

Assets.

## Preserve These Decisions

Preserve decisions.

## Friction Areas To Explore

- ASR Runtime Profile
- Live Workspace Session

## Release Blockers Are Not Architecture Candidates

Separate blockers.

## Verification Before Calling A Candidate Done

Run checks.
""",
    )
    write(
        root / "CONTEXT-MAP.md",
        """# Context Map

## Contexts

- [Product Model](./docs/contexts/product/CONTEXT.md) - product language.
""",
    )
    write(
        root / "docs/contexts/product/CONTEXT.md",
        """# Product Model

## Language

**InsightKit**:
Current product name.
""",
    )
    write(
        root / "docs/project-normalization-source-ledger.md",
        """# Project Normalization Source Ledger

## Current Product Name

InsightKit is current.

## Role Taxonomy

- Current domain language
- Historical reference
- Architecture decision
- Release evidence
- Integration contract
- Future-work queue

## Context Coverage

| Context | Current source entries | Notes |
|---|---|---|
| Product | `docs/contexts/product/CONTEXT.md` | Current language |

## High-Signal Assets By Role

### Current Domain Language
""",
    )
    write(root / "docs/adr/0001-example.md", "# Example decision\n")
    write(
        root / ".scratch/README.md",
        """# Scratch Work Index

Status: current

Use ready-for-agent and ready-for-human status labels.

owner-controlled work needs the owner.

- project-normalization/
- legacy-matt-workflow-library/
- live-workspace-session/
- public-distribution-readiness/
""",
    )
    write(
        root / ".scratch/project-normalization/PRD.md",
        """# Project Normalization PRD

Status: ready-for-agent
""",
    )
    write(
        root / ".scratch/project-normalization/issues/01-source-ledger.md",
        """# Source ledger

Status: ready-for-human

## Blocked by

None - can start immediately.
""",
    )
    write(
        root / ".scratch/project-normalization/issues/02-verifier.md",
        """# Verifier

Status: ready-for-agent

## Blocked by

- `.scratch/project-normalization/issues/01-source-ledger.md`
""",
    )


def write_minimal_legacy_library(root: Path) -> None:
    legacy_root = root / "docs/Legacy/matt-workflow-library"
    write(
        legacy_root / "manifest.md",
        """# Legacy Matt Workflow Library Manifest

Status: current

## How To Read This Library

Original asset and converted asset rules.

## Current Assets Not Archived

Current `.scratch/`, contexts, ADRs, and agent docs stay active.

## Original Assets

""" + "\n".join(f"- `{item}`" for item in LEGACY_ORIGINAL_ASSETS) + """

## Converted Assets

""" + "\n".join(f"- `{item}`" for item in LEGACY_CONVERTED_ASSETS) + """

## Current Authority Rules

Prefer current context docs and ADRs.

## Verification

Run the project-normalization verifier.
""",
    )
    for rel in LEGACY_ORIGINAL_ASSETS:
        write(legacy_root / rel, "# Original asset\n")
    for rel in LEGACY_CONVERTED_ASSETS:
        write(legacy_root / rel, "# Converted asset\n")
    for rel in PUBLIC_DISTRIBUTION_READINESS_ASSETS:
        write(
            root / rel,
            """# Public distribution asset

Status: ready-for-human

## Blocked by

Owner decision required.
""",
        )

    ledger = root / "docs/project-normalization-source-ledger.md"
    ledger.write_text(
        ledger.read_text(encoding="utf-8")
        + "\n"
        + "\n".join(
            [
                "- `docs/Legacy/matt-workflow-library/manifest.md`",
                "- `docs/Legacy/matt-workflow-library/converted-assets/product/historical-product-rationale.md`",
                "- `docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md`",
                "- `docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-prd.md`",
                "- `docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-issues.md`",
                "- `docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md`",
                "- `docs/Legacy/matt-workflow-library/converted-assets/architecture/architecture-decision-map.md`",
                "- `docs/Legacy/matt-workflow-library/converted-assets/release/release-proof-index.md`",
                "- `docs/Legacy/matt-workflow-library/converted-assets/release/owner-input-checklist.md`",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    for rel, required_terms in LEGACY_STANDARD_SETUP_REQUIREMENTS.items():
        path = root / rel
        if not path.exists():
            write(path, "# Standard setup doc\n")
        path.write_text(
            path.read_text(encoding="utf-8")
            + "\n## Legacy setup integration\n"
            + "\n".join(required_terms)
            + "\n",
            encoding="utf-8",
        )

    for rel, required_terms in LEGACY_PROMOTED_STANDARD_REQUIREMENTS.items():
        path = root / rel
        if not path.exists():
            write(path, "# Promoted standard doc\n")
        extra_terms: tuple[str, ...] = ()
        if rel == "docs/contexts/release-workflow/CONTEXT.md":
            extra_terms = RELEASE_VOCAB_TERMS
        path.write_text(
            path.read_text(encoding="utf-8")
            + "\n## Promoted historical content\n"
            + "\n".join(required_terms + extra_terms)
            + "\n",
            encoding="utf-8",
        )


def test_verify_project_normalization_passes_minimal_repo(tmp_path):
    write_minimal_normalized_repo(tmp_path)

    result = verify(tmp_path)

    assert result["status"] == "passed"
    assert result["counts"]["context_docs"] == 1
    assert result["counts"]["issues"] == 2
    assert result["counts"]["blocked_by_refs"] == 1
    assert result["counts"]["scratch_index_terms"] == len(SCRATCH_INDEX_REQUIRED_TERMS)


def test_verify_project_normalization_fails_on_missing_context_doc(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    (tmp_path / "docs/contexts/product/CONTEXT.md").unlink()

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_context_doc" for item in result["findings"])


def test_verify_project_normalization_fails_on_missing_issue_status(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    issue = tmp_path / ".scratch/project-normalization/issues/02-verifier.md"
    issue.write_text(issue.read_text(encoding="utf-8").replace("Status: ready-for-agent\n\n", ""), encoding="utf-8")

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_issue_status" for item in result["findings"])


def test_verify_project_normalization_fails_on_broken_blocked_by_ref(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    issue = tmp_path / ".scratch/project-normalization/issues/02-verifier.md"
    issue.write_text(
        issue.read_text(encoding="utf-8").replace("01-source-ledger.md", "99-missing.md"),
        encoding="utf-8",
    )

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "broken_blocked_by_ref" for item in result["findings"])


def test_verify_project_normalization_fails_on_current_product_heading_drift(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write(tmp_path / "README.md", "# AutoTranscribe\n\nCurrent product docs.\n")

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "current_product_heading_drift" for item in result["findings"])


def test_verify_project_normalization_fails_on_missing_release_vocab_term(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write(
        tmp_path / "docs/contexts/release-workflow/CONTEXT.md",
        """# Release Workflow

## Language

**Local Release Ready**:
Ready locally.
""",
    )

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_release_vocab_term" for item in result["findings"])


def test_verify_project_normalization_fails_on_missing_architecture_handoff(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    (tmp_path / "docs/architecture-review-handoff.md").unlink()

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_architecture_handoff" for item in result["findings"])


def test_verify_project_normalization_fails_on_missing_loop_engineering_doc(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    (tmp_path / "docs/agents/loop-engineering.md").unlink()

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_loop_engineering_doc" for item in result["findings"])


def test_verify_project_normalization_fails_on_missing_scratch_index(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    (tmp_path / ".scratch/README.md").unlink()

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_scratch_index" for item in result["findings"])


def test_verify_project_normalization_fails_when_agents_does_not_link_loop_standard(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write(tmp_path / "AGENTS.md", "# InsightKit Agent Instructions\n")

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_loop_doc_link" for item in result["findings"])


def test_verify_project_normalization_checks_all_local_markdown_features(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write(
        tmp_path / ".scratch/live-workspace-session/PRD.md",
        """# Live Workspace Session PRD

Status: ready-for-agent
""",
    )
    write(
        tmp_path / ".scratch/live-workspace-session/issues/01-first.md",
        """# First live workspace issue

Status: ready-for-agent

## Blocked by

None - can start immediately.
""",
    )
    write(
        tmp_path / ".scratch/live-workspace-session/issues/02-second.md",
        """# Second live workspace issue

Status: ready-for-agent

## Blocked by

- `.scratch/live-workspace-session/issues/01-first.md`
""",
    )

    result = verify(tmp_path)

    assert result["status"] == "passed"
    assert result["counts"]["local_prds"] == 2
    assert result["counts"]["issues"] == 4
    assert result["counts"]["blocked_by_refs"] == 2


def test_verify_project_normalization_fails_on_broken_cross_feature_blocker(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write(
        tmp_path / ".scratch/live-workspace-session/PRD.md",
        """# Live Workspace Session PRD

Status: ready-for-agent
""",
    )
    write(
        tmp_path / ".scratch/live-workspace-session/issues/01-first.md",
        """# First live workspace issue

Status: ready-for-agent

## Blocked by

- `.scratch/live-workspace-session/issues/99-missing.md`
""",
    )

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "broken_blocked_by_ref" for item in result["findings"])


def test_verify_project_normalization_checks_legacy_matt_workflow_library(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write_minimal_legacy_library(tmp_path)

    result = verify(tmp_path)

    assert result["status"] == "passed"
    assert result["counts"]["legacy_library_manifests"] == 1
    assert result["counts"]["legacy_original_assets"] == len(LEGACY_ORIGINAL_ASSETS)
    assert result["counts"]["legacy_converted_assets"] == len(LEGACY_CONVERTED_ASSETS)
    assert result["counts"]["legacy_standard_setup_docs"] == len(LEGACY_STANDARD_SETUP_REQUIREMENTS)
    assert result["counts"]["legacy_promoted_standard_docs"] == len(LEGACY_PROMOTED_STANDARD_REQUIREMENTS)
    assert result["counts"]["public_distribution_readiness_assets"] == len(PUBLIC_DISTRIBUTION_READINESS_ASSETS)


def test_verify_project_normalization_fails_on_missing_legacy_converted_asset(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write_minimal_legacy_library(tmp_path)
    (tmp_path / "docs/Legacy/matt-workflow-library" / LEGACY_CONVERTED_ASSETS[0]).unlink()

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_legacy_converted_asset" for item in result["findings"])


def test_verify_project_normalization_fails_when_legacy_library_is_not_in_standard_setup(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write_minimal_legacy_library(tmp_path)
    issue_tracker = tmp_path / "docs/agents/issue-tracker.md"
    issue_tracker.write_text("# Issue tracker\n\nNo Legacy rules.\n", encoding="utf-8")

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_legacy_standard_setup_term" for item in result["findings"])


def test_verify_project_normalization_fails_when_promoted_legacy_content_is_missing(tmp_path):
    write_minimal_normalized_repo(tmp_path)
    write_minimal_legacy_library(tmp_path)
    product_context = tmp_path / "docs/contexts/product/CONTEXT.md"
    product_context.write_text(
        """# Product Model

## Language

**InsightKit**:
Current product name.
""",
        encoding="utf-8",
    )

    result = verify(tmp_path)

    assert result["status"] == "failed"
    assert any(item["check"] == "missing_legacy_promoted_standard_term" for item in result["findings"])
