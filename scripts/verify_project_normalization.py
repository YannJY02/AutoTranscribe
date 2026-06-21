#!/usr/bin/env python3
"""Verify InsightKit project-normalization assets from the outside."""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_DIAGNOSTICS_ROOT = ROOT_DIR / "logs" / "diagnostics"
VALID_STATUSES = {"needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "wontfix"}
CONTEXT_LINK_RE = re.compile(r"\[[^\]]+\]\((?P<path>[^)]+/CONTEXT\.md)\)")
STATUS_RE = re.compile(r"^Status:\s*(?P<status>\S+)\s*$", re.MULTILINE)
BLOCKED_BY_RE = re.compile(r"`(?P<path>\.scratch/[^`]+/issues/[^`]+\.md)`")
CURRENT_NAMING_FILES = ["README.md", "AGENTS.md"]
LEGACY_LIBRARY_ROOT = Path("docs/Legacy/matt-workflow-library")
LEGACY_LIBRARY_MANIFEST = LEGACY_LIBRARY_ROOT / "manifest.md"
LEGACY_ORIGINAL_ASSETS = (
    "original-assets/docs/Legacy/overview.md",
    "original-assets/docs/Legacy/image.png",
    "original-assets/docs/Legacy/image-1.png",
    "original-assets/docs/Legacy/image-2.png",
    "original-assets/docs/Legacy/智能纪要：示例集重构-新手任务清单 2026年2月3日.pdf",
    "original-assets/docs/plans/2026-03-06-live-summary-lag-diagnosis.md",
    "original-assets/docs/plans/2026-03-14-phase1-sidecar-split.md",
    "original-assets/docs/plans/2026-03-14-progressive-refactor-design.md",
    "original-assets/docs/plans/2026-03-15-phase2-ipc-upgrade-design.md",
    "original-assets/docs/plans/2026-03-15-phase2-ipc-upgrade.md",
    "original-assets/docs/plans/2026-03-18-phase4-blueprint.md",
    "original-assets/docs/plans/2026-03-18-phase4-frontend-redesign.md",
    "original-assets/docs/plans/2026-03-18-phase5-backend-completion.md",
    "original-assets/docs/plans/2026-05-21-local-asr-model-upgrade.md",
    "original-assets/docs/plans/2026-05-23-insightkit-goal-evidence.md",
    "original-assets/docs/plans/2026-05-24-insightkit-release-verification.md",
    "original-assets/docs/plans/2026-05-26-insightkit-release-readiness-status.md",
    "original-assets/docs/release/release-privacy-sandbox.md",
    "original-assets/docs/release/release-privacy-policy-draft.md",
    "original-assets/docs/release/release-app-store-privacy-answers.md",
    "original-assets/docs/architecture/insightkit-architecture.md",
)
LEGACY_CONVERTED_ASSETS = (
    "converted-assets/product/historical-product-rationale.md",
    "converted-assets/product/reference-output-patterns.md",
    "converted-assets/planning/historical-implementation-prd.md",
    "converted-assets/planning/historical-implementation-issues.md",
    "converted-assets/planning/content-promotion-audit.md",
    "converted-assets/architecture/architecture-decision-map.md",
    "converted-assets/release/release-proof-index.md",
    "converted-assets/release/owner-input-checklist.md",
)
LEGACY_MOVED_SOURCE_PATHS = (
    "docs/Legacy/overview.md",
    "docs/Legacy/image.png",
    "docs/Legacy/image-1.png",
    "docs/Legacy/image-2.png",
    "docs/Legacy/智能纪要：示例集重构-新手任务清单 2026年2月3日.pdf",
    "docs/insightkit-architecture.md",
    "docs/release-privacy-sandbox.md",
    "docs/release-privacy-policy-draft.md",
    "docs/release-app-store-privacy-answers.md",
    "docs/plans/2026-03-06-live-summary-lag-diagnosis.md",
    "docs/plans/2026-03-14-phase1-sidecar-split.md",
    "docs/plans/2026-03-14-progressive-refactor-design.md",
    "docs/plans/2026-03-15-phase2-ipc-upgrade-design.md",
    "docs/plans/2026-03-15-phase2-ipc-upgrade.md",
    "docs/plans/2026-03-18-phase4-blueprint.md",
    "docs/plans/2026-03-18-phase4-frontend-redesign.md",
    "docs/plans/2026-03-18-phase5-backend-completion.md",
    "docs/plans/2026-05-21-local-asr-model-upgrade.md",
    "docs/plans/2026-05-23-insightkit-goal-evidence.md",
    "docs/plans/2026-05-24-insightkit-release-verification.md",
    "docs/plans/2026-05-26-insightkit-release-readiness-status.md",
)
LEGACY_MANIFEST_SECTIONS = (
    "How To Read This Library",
    "Current Assets Not Archived",
    "Original Assets",
    "Converted Assets",
    "Current Authority Rules",
    "Verification",
)
LEGACY_SOURCE_LEDGER_REQUIRED_REFS = (
    "docs/Legacy/matt-workflow-library/manifest.md",
    "docs/Legacy/matt-workflow-library/converted-assets/product/historical-product-rationale.md",
    "docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md",
    "docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-prd.md",
    "docs/Legacy/matt-workflow-library/converted-assets/planning/historical-implementation-issues.md",
    "docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md",
    "docs/Legacy/matt-workflow-library/converted-assets/architecture/architecture-decision-map.md",
    "docs/Legacy/matt-workflow-library/converted-assets/release/release-proof-index.md",
    "docs/Legacy/matt-workflow-library/converted-assets/release/owner-input-checklist.md",
)
PUBLIC_DISTRIBUTION_READINESS_ASSETS = (
    ".scratch/public-distribution-readiness/PRD.md",
    ".scratch/public-distribution-readiness/issues/01-confirm-release-channel-and-cloud-provider-boundary.md",
    ".scratch/public-distribution-readiness/issues/02-prepare-public-privacy-policy-url.md",
    ".scratch/public-distribution-readiness/issues/03-finalize-app-store-privacy-answers.md",
    ".scratch/public-distribution-readiness/issues/04-run-developer-id-distribution-preflight.md",
    ".scratch/public-distribution-readiness/issues/05-run-app-store-sandbox-distribution-preflight.md",
)
LEGACY_STANDARD_SETUP_REQUIREMENTS = {
    "AGENTS.md": (
        "Legacy workflow library",
        "docs/Legacy/matt-workflow-library/",
        "manifest.md",
    ),
    "docs/agents/issue-tracker.md": (
        "Legacy workflow assets",
        "not the active issue tracker",
        ".scratch/<feature>/PRD.md",
    ),
    "docs/agents/triage-labels.md": (
        "Legacy workflow assets",
        "Only use the five triage labels",
        ".scratch/<feature>/issues/",
    ),
    "docs/agents/domain.md": (
        "Legacy promotion rules",
        "Context term",
        "ADR candidate",
        "Current PRD or issue",
        "Owner input",
    ),
    "docs/agents/loop-engineering.md": (
        "Legacy Asset Promotion Route",
        "docs/Legacy/matt-workflow-library/manifest.md",
        "context term",
        "ADR candidate",
        "current PRD or issue",
    ),
}
LEGACY_PROMOTED_STANDARD_REQUIREMENTS = {
    "docs/contexts/product/CONTEXT.md": (
        "Record Folder",
        "Meeting Envelope",
        "AI Review Notice",
        "Related Links Section",
        "Smart Minutes Module",
        "Reference Output Pattern",
    ),
    "docs/contexts/python-runtime/CONTEXT.md": (
        "RPC Event",
        "ASR Model Catalog",
        "Runtime Snapshot",
        "Prewarm Watchdog",
        "Record Writer",
        "Record Save Action",
    ),
    "docs/contexts/macos-app/CONTEXT.md": (
        "Session Shell",
        "Session Phase",
        "Panel Data Source",
        "Record Index",
    ),
    "docs/contexts/release-workflow/CONTEXT.md": (
        "Local Preflight",
        "Developer ID Preflight",
        "App Store Preflight",
        "Secret Hygiene Gate",
        "UI Hygiene Gate",
        "Privacy Review Input",
        "Sandbox Verification",
        "Public Distribution Readiness",
    ),
    "docs/adr/0004-use-local-record-folders-with-runtime-record-writer.md": (
        "RecordWriter",
        "records.save",
        "metadata.json",
        "transcript.json",
        "SQLite/FTS",
    ),
    "docs/Legacy/matt-workflow-library/converted-assets/planning/content-promotion-audit.md": (
        "Per-Asset Decisions",
        "2026-03-06-live-summary-lag-diagnosis.md",
        "2026-03-18-phase5-backend-completion.md",
        "release-privacy-sandbox.md",
        ".scratch/public-distribution-readiness/",
        "reference-output-patterns.md",
        "Owner-Reviewed Legacy-Only Decisions",
        "Historical implementation plans remain Legacy-only",
        "Historical release proof/status ledgers remain Legacy release history",
        "Current release claims must come from fresh verifier output",
        "historical architecture reference remains Legacy architecture reference",
        "ADR 0001, ADR 0002, and ADR 0004",
        "Closure Summary",
        "No unclassified moved originals remain",
        "21 moved original assets have per-asset decisions",
        "8 converted assets are listed",
    ),
    "docs/Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md": (
        "Smart Minutes Module Set",
        "Meeting Envelope",
        "Evidence-First Sections",
        "Decision Shape",
        "Action Shape",
        "Navigation Shape",
        "What Not To Promote",
    ),
}
LOOP_REQUIRED_TERMS = (
    "Goal",
    "Context",
    "Boundary",
    "Action",
    "Verification",
    "Feedback",
    "Record",
    "review",
    "improve-codebase-architecture",
    "to-prd",
    "to-issues",
    "implement",
    "verify_project_normalization.py",
    "verify_release_closure.py",
    "External Blocker",
    "Owner-Controlled Input",
)
RELEASE_VOCAB_TERMS = (
    "Local Release Ready",
    "Distribution Ready",
    "External Blocker",
    "Owner-Controlled Input",
    "Proof JSON",
    "Closure Gate",
    "Packaged-App Smoke",
    "Visual GUI Proof",
)


def iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def today_output_root() -> Path:
    day = datetime.now().strftime("%Y-%m-%d")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_DIAGNOSTICS_ROOT / day / f"project-normalization-{stamp}"


def relpath(root: Path, path: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def finding(path: str, check: str, message: str) -> dict[str, str]:
    return {"path": path, "check": check, "message": message}


def context_paths(root: Path, context_map_text: str) -> list[Path]:
    paths: list[Path] = []
    for match in CONTEXT_LINK_RE.finditer(context_map_text):
        raw = match.group("path").strip()
        if raw.startswith("./"):
            raw = raw[2:]
        paths.append((root / raw).resolve())
    return paths


def section_text(text: str, heading: str) -> str:
    marker = f"## {heading}"
    start = text.find(marker)
    if start < 0:
        return ""
    next_start = text.find("\n## ", start + len(marker))
    return text[start:] if next_start < 0 else text[start:next_start]


def issue_status(path: Path) -> str | None:
    match = STATUS_RE.search(read_text(path))
    return match.group("status") if match else None


def blocked_by_refs(path: Path) -> list[str]:
    text = read_text(path)
    blocked = section_text(text, "Blocked by")
    return [match.group("path") for match in BLOCKED_BY_RE.finditer(blocked)]


def legacy_library_requested(root: Path) -> bool:
    return (
        (root / LEGACY_LIBRARY_MANIFEST).exists()
        or (root / ".scratch" / "legacy-matt-workflow-library" / "PRD.md").exists()
    )


def verify_legacy_library(root: Path, findings: list[dict[str, str]], counts: dict[str, int]) -> None:
    manifest = root / LEGACY_LIBRARY_MANIFEST
    if not manifest.exists():
        findings.append(
            finding(
                relpath(root, manifest),
                "missing_legacy_library_manifest",
                "Legacy Matt Workflow Library manifest is missing.",
            )
        )
        return

    counts["legacy_library_manifests"] = 1
    manifest_text = read_text(manifest)
    for section in LEGACY_MANIFEST_SECTIONS:
        if f"## {section}" not in manifest_text:
            findings.append(
                finding(
                    relpath(root, manifest),
                    "missing_legacy_manifest_section",
                    f"Legacy library manifest is missing section: {section}.",
                )
            )

    legacy_root = root / LEGACY_LIBRARY_ROOT
    for rel in LEGACY_ORIGINAL_ASSETS:
        path = legacy_root / rel
        if path.exists():
            counts["legacy_original_assets"] += 1
        else:
            findings.append(
                finding(
                    relpath(root, path),
                    "missing_legacy_original_asset",
                    "Legacy library manifest expects this moved original asset.",
                )
            )
        if rel not in manifest_text:
            findings.append(
                finding(
                    relpath(root, manifest),
                    "legacy_manifest_missing_original_ref",
                    f"Manifest does not reference moved original asset: {rel}.",
                )
            )

    for rel in LEGACY_CONVERTED_ASSETS:
        path = legacy_root / rel
        if path.exists():
            counts["legacy_converted_assets"] += 1
        else:
            findings.append(
                finding(
                    relpath(root, path),
                    "missing_legacy_converted_asset",
                    "Legacy library manifest expects this converted Matt workflow asset.",
                )
            )
        if rel not in manifest_text:
            findings.append(
                finding(
                    relpath(root, manifest),
                    "legacy_manifest_missing_converted_ref",
                    f"Manifest does not reference converted asset: {rel}.",
                )
            )

    for rel in LEGACY_MOVED_SOURCE_PATHS:
        if (root / rel).exists():
            findings.append(
                finding(
                    rel,
                    "legacy_moved_source_still_at_old_path",
                    "Historical source should live under docs/Legacy/matt-workflow-library/original-assets/.",
                )
            )

    for rel in PUBLIC_DISTRIBUTION_READINESS_ASSETS:
        path = root / rel
        if path.exists():
            counts["public_distribution_readiness_assets"] += 1
        else:
            findings.append(
                finding(
                    rel,
                    "missing_public_distribution_readiness_asset",
                    "Legacy release/privacy promotion expects this current public-distribution asset.",
                )
            )

    ledger = root / "docs" / "project-normalization-source-ledger.md"
    if ledger.exists():
        ledger_text = read_text(ledger)
        for ref in LEGACY_SOURCE_LEDGER_REQUIRED_REFS:
            if ref not in ledger_text:
                findings.append(
                    finding(
                        relpath(root, ledger),
                        "source_ledger_missing_legacy_library_ref",
                        f"Source ledger does not point to Legacy library asset: {ref}.",
                    )
                )

    for rel, required_terms in LEGACY_STANDARD_SETUP_REQUIREMENTS.items():
        path = root / rel
        if not path.exists():
            findings.append(
                finding(
                    rel,
                    "missing_legacy_standard_setup_doc",
                    "Legacy library integration expects this standard setup document.",
                )
            )
            continue
        counts["legacy_standard_setup_docs"] += 1
        text = read_text(path)
        for term in required_terms:
            if term not in text:
                findings.append(
                    finding(
                        rel,
                        "missing_legacy_standard_setup_term",
                        f"Standard setup document is missing Legacy library rule: {term}.",
                    )
                )

    for rel, required_terms in LEGACY_PROMOTED_STANDARD_REQUIREMENTS.items():
        path = root / rel
        if not path.exists():
            findings.append(
                finding(
                    rel,
                    "missing_legacy_promoted_standard_doc",
                    "Legacy content promotion expects this current standard document.",
                )
            )
            continue
        counts["legacy_promoted_standard_docs"] += 1
        text = read_text(path)
        for term in required_terms:
            if term not in text:
                findings.append(
                    finding(
                        rel,
                        "missing_legacy_promoted_standard_term",
                        f"Current standard document is missing promoted Legacy content: {term}.",
                    )
                )


def verify(root: Path) -> dict[str, Any]:
    root = root.expanduser().resolve()
    findings: list[dict[str, str]] = []
    counts: dict[str, int] = {
        "context_links": 0,
        "context_docs": 0,
        "adrs": 0,
        "local_prds": 0,
        "issues": 0,
        "blocked_by_refs": 0,
        "source_ledgers": 0,
        "current_naming_docs": 0,
        "loop_engineering_docs": 0,
        "loop_engineering_terms": 0,
        "release_vocab_terms": 0,
        "architecture_handoffs": 0,
        "legacy_library_manifests": 0,
        "legacy_original_assets": 0,
        "legacy_converted_assets": 0,
        "legacy_standard_setup_docs": 0,
        "legacy_promoted_standard_docs": 0,
        "public_distribution_readiness_assets": 0,
    }

    context_map = root / "CONTEXT-MAP.md"
    if not context_map.exists():
        findings.append(finding("CONTEXT-MAP.md", "missing_context_map", "Context Map is missing."))
        context_docs: list[Path] = []
    else:
        context_text = read_text(context_map)
        if "## Contexts" not in context_text:
            findings.append(finding("CONTEXT-MAP.md", "missing_contexts_section", "Context Map lacks a Contexts section."))
        context_docs = context_paths(root, context_text)
        counts["context_links"] = len(context_docs)
        if not context_docs:
            findings.append(finding("CONTEXT-MAP.md", "missing_context_links", "Context Map has no CONTEXT.md links."))

    for path in context_docs:
        rel = relpath(root, path)
        if not path.exists():
            findings.append(finding(rel, "missing_context_doc", "Context Map points to a missing context glossary."))
            continue
        counts["context_docs"] += 1
        text = read_text(path)
        if "## Language" not in text:
            findings.append(finding(rel, "missing_language_section", "Context glossary lacks a Language section."))

    ledger = root / "docs" / "project-normalization-source-ledger.md"
    if not ledger.exists():
        findings.append(finding(relpath(root, ledger), "missing_source_ledger", "Project normalization source ledger is missing."))
    else:
        counts["source_ledgers"] = 1
        text = read_text(ledger)
        for heading in ("Current Product Name", "Role Taxonomy", "Context Coverage", "High-Signal Assets By Role"):
            if f"## {heading}" not in text:
                findings.append(finding(relpath(root, ledger), "missing_ledger_section", f"Missing ledger section: {heading}."))
        for role in (
            "Current domain language",
            "Historical reference",
            "Architecture decision",
            "Release evidence",
            "Integration contract",
            "Future-work queue",
        ):
            if role not in text:
                findings.append(finding(relpath(root, ledger), "missing_ledger_role", f"Missing source role: {role}."))

    adr_dir = root / "docs" / "adr"
    adr_files = sorted(adr_dir.glob("*.md")) if adr_dir.exists() else []
    counts["adrs"] = len(adr_files)
    if not adr_files:
        findings.append(finding("docs/adr", "missing_adrs", "No ADR markdown files found."))
    for path in adr_files:
        text = read_text(path).strip()
        if not text.startswith("# "):
            findings.append(finding(relpath(root, path), "missing_adr_title", "ADR file lacks a top-level title."))

    for rel in CURRENT_NAMING_FILES:
        path = root / rel
        if not path.exists():
            continue
        counts["current_naming_docs"] += 1
        text = read_text(path)
        first_heading = next((line.strip() for line in text.splitlines() if line.startswith("# ")), "")
        if "InsightKit" not in first_heading:
            findings.append(finding(rel, "current_product_heading_drift", "Current-facing doc top heading should name InsightKit."))
        if "AutoTranscribe" in text and not re.search(r"\b(?:legacy|lineage|historical|compatibility)\b", text, re.IGNORECASE):
            findings.append(
                finding(
                    rel,
                    "autotranscribe_without_legacy_context",
                    "AutoTranscribe appears in a current-facing doc without legacy or lineage context.",
                )
            )

    loop_doc = root / "docs" / "agents" / "loop-engineering.md"
    if not loop_doc.exists():
        findings.append(finding(relpath(root, loop_doc), "missing_loop_engineering_doc", "Matt workflow loop engineering standard is missing."))
    else:
        counts["loop_engineering_docs"] = 1
        text = read_text(loop_doc)
        for heading in (
            "Purpose",
            "Preconditions",
            "Standard Loop Packet",
            "Matt Workflow Routes",
            "Verification Ladder",
            "Required Gates",
            "Feedback Packet",
            "Stop Rules",
            "Record Keeping",
        ):
            if f"## {heading}" not in text:
                findings.append(finding(relpath(root, loop_doc), "missing_loop_section", f"Missing loop engineering section: {heading}."))
        for term in LOOP_REQUIRED_TERMS:
            if term in text:
                counts["loop_engineering_terms"] += 1
            else:
                findings.append(finding(relpath(root, loop_doc), "missing_loop_term", f"Loop engineering standard is missing required term: {term}."))

        agents = root / "AGENTS.md"
        if agents.exists() and "docs/agents/loop-engineering.md" not in read_text(agents):
            findings.append(finding(relpath(root, agents), "missing_loop_doc_link", "AGENTS.md does not link to the loop engineering standard."))

    release_context = root / "docs" / "contexts" / "release-workflow" / "CONTEXT.md"
    if release_context.exists():
        text = read_text(release_context)
        for term in RELEASE_VOCAB_TERMS:
            if term in text:
                counts["release_vocab_terms"] += 1
            else:
                findings.append(
                    finding(
                        relpath(root, release_context),
                        "missing_release_vocab_term",
                        f"Release Workflow context is missing required term: {term}.",
                    )
                )

    handoff = root / "docs" / "architecture-review-handoff.md"
    if not handoff.exists():
        findings.append(finding(relpath(root, handoff), "missing_architecture_handoff", "Architecture review handoff is missing."))
    else:
        counts["architecture_handoffs"] = 1
        text = read_text(handoff)
        for heading in (
            "Read First",
            "Accepted ADRs",
            "Current Source Assets",
            "Preserve These Decisions",
            "Friction Areas To Explore",
            "Release Blockers Are Not Architecture Candidates",
            "Verification Before Calling A Candidate Done",
        ):
            if f"## {heading}" not in text:
                findings.append(finding(relpath(root, handoff), "missing_handoff_section", f"Missing handoff section: {heading}."))
        for required in ("0001-", "0002-", "0003-", "0004-", "ASR Runtime Profile", "Live Workspace Session"):
            if required not in text:
                findings.append(finding(relpath(root, handoff), "missing_handoff_marker", f"Missing handoff marker: {required}."))

    scratch_dir = root / ".scratch"
    prd_files = sorted(scratch_dir.glob("*/PRD.md")) if scratch_dir.exists() else []
    counts["local_prds"] = len(prd_files)
    project_normalization_prd = root / ".scratch" / "project-normalization" / "PRD.md"
    if not project_normalization_prd.exists():
        findings.append(finding(relpath(root, project_normalization_prd), "missing_prd", "Project-normalization PRD is missing."))
    if not prd_files:
        findings.append(finding(relpath(root, scratch_dir), "missing_local_prds", "No local markdown PRD files found under .scratch/."))
    for prd in prd_files:
        rel = relpath(root, prd)
        status = issue_status(prd)
        if status not in VALID_STATUSES:
            findings.append(finding(rel, "invalid_prd_status", "PRD is missing a valid Status line."))

    issue_dir = root / ".scratch" / "project-normalization" / "issues"
    issue_files = sorted(scratch_dir.glob("*/issues/*.md")) if scratch_dir.exists() else []
    counts["issues"] = len(issue_files)
    if not issue_dir.exists() or not sorted(issue_dir.glob("*.md")):
        findings.append(finding(relpath(root, issue_dir), "missing_issues", "No project-normalization issue files found."))
    if not issue_files:
        findings.append(finding(relpath(root, scratch_dir), "missing_local_issues", "No local markdown issue files found under .scratch/."))

    for path in issue_files:
        rel = relpath(root, path)
        status = issue_status(path)
        if status is None:
            findings.append(finding(rel, "missing_issue_status", "Local issue is missing a Status line."))
        elif status not in VALID_STATUSES:
            findings.append(finding(rel, "invalid_issue_status", f"Invalid Status label: {status}."))

        for ref in blocked_by_refs(path):
            counts["blocked_by_refs"] += 1
            if not (root / ref).exists():
                findings.append(finding(rel, "broken_blocked_by_ref", f"Blocked-by reference does not exist: {ref}."))

    if legacy_library_requested(root):
        verify_legacy_library(root, findings, counts)

    return {
        "status": "passed" if not findings else "failed",
        "workspace": str(root),
        "counts": counts,
        "findings": findings,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT_DIR, help=f"Repository root. Default: {ROOT_DIR}")
    parser.add_argument("--output-root", type=Path, default=today_output_root(), help="Directory for proof.json.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_root = args.output_root.expanduser().resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    proof_path = output_root / "proof.json"
    proof = {
        "generated_at": iso_now(),
        **verify(args.root),
    }
    proof_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote proof: {proof_path}")
    print(f"status: {proof['status']}")
    for key, value in proof["counts"].items():
        print(f"{key}: {value}")
    print(f"findings: {len(proof['findings'])}")
    return 0 if proof["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
