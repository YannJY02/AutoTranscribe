#!/usr/bin/env python3
"""Deterministic, privacy-bounded evidence normalization and handoff rendering."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import tempfile
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any, Iterable
from urllib.parse import urlsplit


SCHEMA_VERSION = 1
PROMOTION_CATEGORIES = frozenset({
    "scope", "acceptance", "dependency", "priority", "status", "gate",
    "milestone", "owner-action", "continue-or-stop",
})
CLAIM_CLASSES = frozenset({"observed", "accepted-decision", "inference", "unknown"})
RESULTS = frozenset({"passed", "failed", "blocked", "unobserved", "superseded"})
SOURCE_RESULTS = RESULTS - {"superseded"}
PRIVACY_CLASSES = frozenset({"public-metadata", "repository-metadata", "approved-aggregate"})
SOURCES = frozenset({"linear", "github", "ci", "repository", "analytics", "diagnostics", "pilot"})
SEVERE_EVENTS = frozenset({"security", "privacy", "data-loss"})
FEEDBACK_EVENTS = SEVERE_EVENTS | {"review", "bug"}
SOURCE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
HASH_SHAPED_ID = re.compile(r"^[0-9a-fA-F]{32,128}$")
REVISION = re.compile(r"^(?:(?:sha256:[0-9a-f]{6,64})|(?:[A-Za-z0-9][A-Za-z0-9._/-]{0,127})|unavailable)$")
METADATA_CODE = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,127}$")
EVIDENCE_ID = re.compile(r"^ev_v1_[0-9a-f]{24}$")
ARTIFACT_SHA = re.compile(r"^sha256:[0-9a-f]{64}$")
LINEAR_ISSUE = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]+$")
GITHUB_ISSUE = re.compile(r"^(?:GH-|PR-|#)?[0-9]+$")
ISSUE_ID = re.compile(r"^(?:GH-|PR-|[A-Z][A-Z0-9]*-|#)?[0-9]+$")
FRIDAY_PERIOD = re.compile(r"^[0-9]{4}-W(?:0[1-9]|[1-4][0-9]|5[0-3])$")
FORBIDDEN_FIELDS = frozenset({
    "transcript", "raw_transcript", "meeting_content", "prompt", "prompts",
    "provider_payload", "payload", "credential", "credentials", "secret", "token",
})
PRIVATE_PATH = re.compile(r"(?:/Users/[^/\s]+|/home/[^/\s]+|[A-Za-z]:\\Users\\[^\\\s]+)(?:[/\\][^\s]*)?")
SECRET = re.compile(
    r"(?i)(?:bearer\s+[a-z0-9._-]+|(?:api[_-]?key|token|secret)\s*[:=]\s*\S+|"
    r"(?:gh[pousr]_|github_pat_|sk-)[a-z0-9_-]{20,})"
)
CREDENTIAL_FIELD = re.compile(
    r"(?i)(?:^|_)(?:(?:token|secret|password|credential|authorization|pat)s?|"
    r"(?:api|private|access|secret)_key(?:_id)?)$"
)
RFC3339 = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$")
POSTHOG_HOSTS = frozenset({"app.posthog.com", "eu.posthog.com", "us.posthog.com"})
REQUIRED = (
    "linear_issue_id", "github_issue_or_pr_id", "lifecycle_stage", "lifecycle_transition",
    "source_type", "source_id", "source_ref", "revision", "artifact_sha256", "observed_at",
    "environment", "result", "claim_class", "promotion_category", "privacy_class", "fact",
    "gap_or_decision", "owner_action", "recheck_source", "human_gate", "unknowns",
)
RECORD_FIELDS = frozenset(REQUIRED) | {"schema_version", "evidence_id", "supersedes"}


class ValidationError(ValueError):
    """Input is outside the evidence ledger privacy or schema boundary."""


def _canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def _reject_duplicate_fields(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError("duplicate JSON field")
        result[key] = value
    return result


def _load_json(value: str | bytes) -> Any:
    return json.loads(value, object_pairs_hook=_reject_duplicate_fields)


def _identifier(prefix: str, *parts: str) -> str:
    digest = hashlib.sha256("\x1f".join(parts).encode()).hexdigest()[:24]
    return f"{prefix}_v{SCHEMA_VERSION}_{digest}"


def _walk(value: Any, path: str = "input", *, redact_private_paths: bool = False) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key)
            if PRIVATE_PATH.search(key_text) or SECRET.search(key_text):
                raise ValidationError(f"forbidden field at {path}")
            normalized_key = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", key_text)
            normalized_key = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", normalized_key).replace("-", "_")
            if normalized_key.casefold() in FORBIDDEN_FIELDS or CREDENTIAL_FIELD.search(normalized_key):
                raise ValidationError(f"forbidden field at {path}")
            _walk(child, f"{path}.*", redact_private_paths=redact_private_paths)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _walk(child, f"{path}[{index}]", redact_private_paths=redact_private_paths)
    elif isinstance(value, str):
        if PRIVATE_PATH.search(value) and not redact_private_paths:
            raise ValidationError(f"private path rejected at {path}")
        if SECRET.search(value):
            raise ValidationError(f"secret-like value rejected at {path}")


def _has_unsafe_ref_chars(value: str) -> bool:
    return any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in value)


def _is_repo_ref(value: str) -> bool:
    if not isinstance(value, str) or _has_unsafe_ref_chars(value):
        return False
    try:
        parsed = urlsplit(value)
    except ValueError:
        return False
    path = PurePosixPath(value)
    return bool(
        value and len(value) <= 500 and not parsed.scheme and not parsed.netloc
        and not value.startswith(("/", "\\")) and "\\" not in value
        and "/" in value and all(part not in {"", ".", ".."} for part in path.parts)
    )


def _https_ref(value: str, hosts: set[str] | frozenset[str] | None = None) -> bool:
    if not isinstance(value, str) or _has_unsafe_ref_chars(value):
        return False
    try:
        parsed = urlsplit(value)
        parsed.port
    except ValueError:
        return False
    return bool(
        len(value) <= 500 and parsed.scheme == "https" and parsed.netloc
        and not parsed.username and not parsed.password
        and (hosts is None or parsed.hostname in hosts)
    )


def _approved_external_ref(source_type: str, value: str) -> bool:
    if _is_repo_ref(value):
        return True
    if source_type == "analytics":
        return _https_ref(value, POSTHOG_HOSTS)
    if source_type == "diagnostics":
        if not _https_ref(value):
            return False
        hostname = urlsplit(value).hostname or ""
        return hostname == "sentry.io" or hostname.endswith(".sentry.io")
    return False


def _valid_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or len(value) > 64 or not RFC3339.fullmatch(value):
        return False
    if not value.endswith("Z") and (int(value[-5:-3]) > 23 or int(value[-2:]) > 59):
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def _timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _is_degraded(item: dict[str, Any]) -> bool:
    codes = [str(item.get("revision", "")), str(item.get("lifecycle_transition", ""))]
    codes.extend(str(value) for value in item.get("unknowns", []))
    return any(
        marker in value
        for value in (code.casefold() for code in codes)
        for marker in ("unavailable", "degraded", "unobserved", "blocked", "missing", "partial")
    )


def _validate(item: dict[str, Any], *, persisted: bool = False) -> None:
    _walk(item)
    unknown = sorted(set(item) - set(REQUIRED))
    if unknown:
        raise ValidationError(f"unsupported fields: {', '.join(unknown)}")
    missing = [field for field in REQUIRED if field not in item]
    if missing:
        raise ValidationError(f"missing fields: {', '.join(missing)}")
    if not isinstance(item["source_type"], str) or item["source_type"] not in SOURCES:
        raise ValidationError("unsupported source_type")
    if not isinstance(item["claim_class"], str) or item["claim_class"] not in CLAIM_CLASSES:
        raise ValidationError("unsupported claim_class")
    if not isinstance(item["result"], str) or item["result"] not in (RESULTS if persisted else SOURCE_RESULTS):
        raise ValidationError("unsupported result")
    if item["promotion_category"] is not None and (
        not isinstance(item["promotion_category"], str) or item["promotion_category"] not in PROMOTION_CATEGORIES
    ):
        raise ValidationError("unsupported promotion_category")
    if not isinstance(item["privacy_class"], str) or item["privacy_class"] not in PRIVACY_CLASSES:
        raise ValidationError("unsupported privacy_class")
    if (
        not isinstance(item["source_id"], str)
        or not SOURCE_ID.fullmatch(item["source_id"])
        or HASH_SHAPED_ID.fullmatch(item["source_id"])
    ):
        raise ValidationError("source_id must be a stable metadata identifier")
    if not isinstance(item["revision"], str) or not REVISION.fullmatch(item["revision"]):
        raise ValidationError("revision must be a stable metadata revision")
    if item["linear_issue_id"] is not None and (
        not isinstance(item["linear_issue_id"], str) or not LINEAR_ISSUE.fullmatch(item["linear_issue_id"])
    ):
        raise ValidationError("linear_issue_id must be a stable issue identifier")
    if item["github_issue_or_pr_id"] is not None and (
        not isinstance(item["github_issue_or_pr_id"], str)
        or not GITHUB_ISSUE.fullmatch(item["github_issue_or_pr_id"])
    ):
        raise ValidationError("github_issue_or_pr_id must be a stable issue or PR identifier")
    if item["promotion_category"] is not None and not (item["linear_issue_id"] or item["github_issue_or_pr_id"]):
        raise ValidationError("promoted evidence requires an issue linkage")
    if item["artifact_sha256"] is not None and (
        not isinstance(item["artifact_sha256"], str) or not ARTIFACT_SHA.fullmatch(item["artifact_sha256"])
    ):
        raise ValidationError("artifact_sha256 must be a full SHA-256")
    if item["source_type"] == "repository" and item["artifact_sha256"] is None and item["revision"] != "unavailable":
        raise ValidationError("repository evidence requires artifact_sha256")
    if not _valid_timestamp(item["observed_at"]):
        raise ValidationError("observed_at must be an RFC 3339 timestamp")
    for field in ("lifecycle_stage", "lifecycle_transition", "environment"):
        if not isinstance(item[field], str) or not METADATA_CODE.fullmatch(item[field]):
            raise ValidationError(f"{field} must be bounded metadata")

    source_ref = item["source_ref"]
    if not isinstance(source_ref, str):
        raise ValidationError("source_ref is not an inspectable approved reference")
    if item["source_type"] == "linear":
        inspectable = _https_ref(source_ref, {"linear.app"})
    elif item["source_type"] in {"github", "ci"}:
        inspectable = _https_ref(source_ref, {"github.com"})
    elif item["source_type"] == "repository":
        inspectable = _is_repo_ref(source_ref)
    else:
        inspectable = _approved_external_ref(item["source_type"], source_ref)
    if not inspectable:
        raise ValidationError("source_ref is not an inspectable approved reference")

    for field in ("fact", "gap_or_decision", "owner_action", "recheck_source", "human_gate"):
        value = item[field]
        if not isinstance(value, str) or not value.strip() or len(value) > 500 or "\n" in value:
            raise ValidationError(f"{field} must be bounded non-empty metadata")
    if not isinstance(item["unknowns"], list) or not all(isinstance(value, str) for value in item["unknowns"]):
        raise ValidationError("unknowns must be a list of strings")
    if any(not METADATA_CODE.fullmatch(value) for value in item["unknowns"]):
        raise ValidationError("unknowns must contain bounded metadata codes")
    if item["result"] == "passed" and _is_degraded(item):
        raise ValidationError("unavailable or degraded evidence cannot pass")


class EvidenceLedger:
    def __init__(self, path: Path | str):
        self.path = Path(path)
        self.lock_path = self.path.with_name(self.path.name + ".lock")

    @staticmethod
    def _validate_ledger(loaded: Any) -> dict[str, Any]:
        if (
            not isinstance(loaded, dict)
            or type(loaded.get("schema_version")) is not int
            or loaded.get("schema_version") != SCHEMA_VERSION
            or not isinstance(loaded.get("records"), list)
        ):
            raise ValidationError("unsupported or malformed ledger")
        _walk(loaded)
        by_id: dict[str, dict[str, Any]] = {}
        for record in loaded["records"]:
            try:
                if not isinstance(record, dict) or set(record) != RECORD_FIELDS:
                    raise ValidationError("record fields do not match the schema")
                if type(record["schema_version"]) is not int or record["schema_version"] != SCHEMA_VERSION:
                    raise ValidationError("record schema_version is invalid")
                claim = {field: record[field] for field in REQUIRED}
                _validate(claim, persisted=True)
                expected = _identifier(
                    "ev", claim["source_type"], claim["source_id"],
                    claim["lifecycle_transition"], claim["revision"],
                )
                if record["evidence_id"] != expected or expected in by_id:
                    raise ValidationError("record identifier is invalid or duplicated")
                if record["supersedes"] is not None and not EVIDENCE_ID.fullmatch(str(record["supersedes"])):
                    raise ValidationError("supersedes is invalid")
                by_id[expected] = record
            except (KeyError, TypeError, ValidationError) as error:
                raise ValidationError(f"malformed ledger record: {error}") from error

        superseded_targets: set[str] = set()
        active_streams: set[tuple[str, str, str]] = set()
        for record in loaded["records"]:
            stream = (record["source_type"], record["source_id"], record["lifecycle_transition"])
            if record["result"] != "superseded":
                if stream in active_streams:
                    raise ValidationError("malformed ledger record: multiple active revisions")
                active_streams.add(stream)
            target = record["supersedes"]
            if target is not None:
                if target not in by_id:
                    raise ValidationError("malformed ledger record: dangling supersedes")
                prior = by_id[target]
                if stream != (prior["source_type"], prior["source_id"], prior["lifecycle_transition"]):
                    raise ValidationError("malformed ledger record: cross-stream supersession")
                if prior["result"] != "superseded":
                    raise ValidationError("malformed ledger record: active supersession target")
                superseded_targets.add(target)
            seen = {record["evidence_id"]}
            cursor = record
            while cursor["supersedes"] is not None:
                target = cursor["supersedes"]
                if target in seen:
                    raise ValidationError("malformed ledger record: supersession cycle")
                seen.add(target)
                cursor = by_id[target]
        orphaned = {record["evidence_id"] for record in loaded["records"] if record["result"] == "superseded"} - superseded_targets
        if orphaned:
            raise ValidationError("malformed ledger record: orphaned superseded revision")
        return loaded

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            return {"schema_version": SCHEMA_VERSION, "records": []}
        try:
            loaded = _load_json(self.path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ValidationError(f"unsupported or malformed ledger: {error}") from error
        return self._validate_ledger(loaded)

    def _atomic_write(self, encoded: bytes) -> None:
        temporary: str | None = None
        try:
            with tempfile.NamedTemporaryFile("wb", dir=self.path.parent, prefix=self.path.name + ".", delete=False) as handle:
                temporary = handle.name
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.path)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)

    def _collect_normalized(self, inputs: Iterable[dict[str, Any]]) -> dict[str, Any]:
        """Validate one batch, then atomically merge it under the ledger lock."""
        candidates = [dict(item) for item in inputs]
        for item in candidates:
            _validate(item)
        candidates.sort(key=lambda item: (
            item["source_type"], item["source_id"], item["lifecycle_transition"],
            _timestamp(item["observed_at"]), item["revision"],
        ))
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("a+b") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            ledger = self._load()
            records = {record["evidence_id"]: dict(record) for record in ledger["records"]}
            for item in candidates:
                evidence_id = _identifier(
                    "ev", item["source_type"], item["source_id"],
                    item["lifecycle_transition"], item["revision"],
                )
                normalized = {field: item[field] for field in REQUIRED}
                normalized.update({"schema_version": SCHEMA_VERSION, "evidence_id": evidence_id, "supersedes": None})
                if evidence_id in records:
                    existing = records[evidence_id]
                    expected = {field: normalized[field] for field in REQUIRED}
                    actual = {field: existing[field] for field in REQUIRED}
                    if existing["result"] == "superseded":
                        actual["result"] = expected["result"]
                    if actual != expected:
                        raise ValidationError("stable source revision changed content")
                    continue

                stream = (item["source_type"], item["source_id"], item["lifecycle_transition"])
                active = next((
                    record for record in records.values()
                    if (record["source_type"], record["source_id"], record["lifecycle_transition"]) == stream
                    and record["result"] != "superseded"
                ), None)
                if active is not None:
                    if (_timestamp(item["observed_at"]), item["revision"]) <= (
                        _timestamp(active["observed_at"]), active["revision"],
                    ):
                        raise ValidationError("stale source observation cannot supersede the active revision")
                    active["result"] = "superseded"
                    normalized["supersedes"] = active["evidence_id"]
                records[evidence_id] = normalized

            output = {"schema_version": SCHEMA_VERSION, "records": sorted(records.values(), key=lambda record: record["evidence_id"])}
            self._validate_ledger(output)
            encoded = _canonical(output)
            if not self.path.exists() or self.path.read_bytes() != encoded:
                self._atomic_write(encoded)
            return output

    def collect_unavailable(self, source_type: str, source_id: str, reason: str, *, observed_at: str,
                            environment: str, lifecycle_stage: str, linear_issue_id: str | None = None,
                            github_issue_or_pr_id: str | None = None) -> dict[str, Any]:
        if source_type == "linear":
            source_ref = f"https://linear.app/yannjy/issue/{source_id}"
        elif source_type in {"github", "ci"}:
            source_ref = f"https://github.com/YannJY02/AutoTranscribe/issues/{source_id.split('-')[-1]}"
        else:
            source_ref = f"logs/evidence/unavailable/{source_type}-{source_id}.json"
        return self._collect_normalized([{
            "linear_issue_id": linear_issue_id, "github_issue_or_pr_id": github_issue_or_pr_id,
            "lifecycle_stage": lifecycle_stage, "lifecycle_transition": "source-unavailable",
            "source_type": source_type, "source_id": source_id, "source_ref": source_ref,
            "revision": "unavailable", "artifact_sha256": None, "observed_at": observed_at,
            "environment": environment, "result": "unobserved", "claim_class": "observed",
            "promotion_category": "status", "privacy_class": "public-metadata",
            "fact": f"{source_type} evidence was unavailable.",
            "gap_or_decision": "No result is inferred from the unavailable source.",
            "owner_action": f"Recheck {source_type} when its approved integration is available.",
            "recheck_source": source_ref, "human_gate": "None.", "unknowns": [reason],
        }])

    def collect_repository_manifest(self, manifest: Path | str, *, repository_ref: str, source_id: str,
                                    lifecycle_stage: str, lifecycle_transition: str, environment: str,
                                    linear_issue_id: str | None, github_issue_or_pr_id: str | None,
                                    promotion_category: str | None) -> dict[str, Any]:
        path = Path(manifest)
        if not _is_repo_ref(repository_ref):
            raise ValidationError("repository_ref must be a safe repository-relative path")
        repository_root = Path(__file__).resolve().parent.parent
        resolved_path = path.resolve()
        if not resolved_path.is_relative_to(repository_root):
            raise ValidationError("manifest path must resolve inside the repository")
        if resolved_path != (repository_root / repository_ref).resolve():
            raise ValidationError("manifest path must match repository_ref")
        try:
            manifest_bytes = path.read_bytes()
            payload = _load_json(manifest_bytes)
        except (OSError, json.JSONDecodeError) as error:
            raise ValidationError(f"manifest is unreadable or malformed: {error}") from error
        if not isinstance(payload, dict):
            raise ValidationError("manifest must be a JSON object")
        # Harness manifests include a local workspace field; it is deliberately omitted below.
        _walk(payload, "manifest", redact_private_paths=True)
        result = str(payload.get("status", "unobserved"))
        if result not in SOURCE_RESULTS:
            result = "unobserved"
        revision = str(payload.get("commit") or payload.get("source_revision") or payload.get("revision") or "unavailable")
        observed_at = payload.get("finished_at") or payload.get("observed_at") or payload.get("captured_at")
        artifact_sha = "sha256:" + hashlib.sha256(manifest_bytes).hexdigest()
        unknowns = []
        if result == "unobserved":
            unknowns.append("manifest-status-unrecognized")
        if revision == "unavailable":
            unknowns.append("manifest-revision-unavailable")
        return self._collect_normalized([{
            "linear_issue_id": linear_issue_id, "github_issue_or_pr_id": github_issue_or_pr_id,
            "lifecycle_stage": lifecycle_stage, "lifecycle_transition": lifecycle_transition,
            "source_type": "repository", "source_id": source_id, "source_ref": repository_ref,
            "revision": revision, "artifact_sha256": artifact_sha, "observed_at": observed_at,
            "environment": environment, "result": result, "claim_class": "observed",
            "promotion_category": promotion_category, "privacy_class": "repository-metadata",
            "fact": f"Repository proof manifest reports {result}.",
            "gap_or_decision": "The ledger records bounded status metadata and the artifact hash.",
            "owner_action": "Inspect the linked manifest before accepting the claim.",
            "recheck_source": repository_ref, "human_gate": "Repository review remains required.",
            "unknowns": unknowns,
        }])

    @staticmethod
    def _external_record(**metadata: Any) -> dict[str, Any]:
        source_type = metadata.get("source_type")
        if source_type not in SOURCES - {"repository"}:
            raise ValidationError("external adapter requires an approved external source type")
        privacy = "approved-aggregate" if source_type in {"analytics", "diagnostics", "pilot"} else "public-metadata"
        label = source_type.upper() if source_type == "ci" else source_type.title()
        item = dict(metadata)
        source_ref = item.get("source_ref")
        if source_type in {"analytics", "diagnostics", "pilot"} and isinstance(source_ref, str) and _is_repo_ref(source_ref):
            repository_root = Path(__file__).resolve().parent.parent
            path = (repository_root / source_ref).resolve()
            if not path.is_relative_to(repository_root):
                raise ValidationError("repository evidence path must resolve inside the repository")
            try:
                artifact = path.read_bytes()
                payload = _load_json(artifact)
            except (OSError, json.JSONDecodeError) as error:
                raise ValidationError(f"repository evidence is unreadable or malformed: {error}") from error
            if not isinstance(payload, dict):
                raise ValidationError("repository evidence must be a JSON object")
            _walk(payload, "repository evidence", redact_private_paths=True)
            manifest_result = payload.get("status", payload.get("result"))
            manifest_revision = payload.get("commit") or payload.get("source_revision") or payload.get("revision")
            manifest_observed_at = payload.get("finished_at") or payload.get("observed_at") or payload.get("captured_at")
            if not all(isinstance(value, str) for value in (manifest_result, manifest_revision, manifest_observed_at)):
                raise ValidationError("repository evidence must bind status, revision, and observed_at")
            item["result"] = manifest_result
            item["revision"] = manifest_revision
            item["observed_at"] = manifest_observed_at
            artifact_sha256 = "sha256:" + hashlib.sha256(artifact).hexdigest()
            if item.get("artifact_sha256") not in {None, artifact_sha256}:
                raise ValidationError("repository evidence hash does not match source_ref")
            item["artifact_sha256"] = artifact_sha256
        item.update({
            "privacy_class": privacy,
            "fact": f"{label} reference metadata reports {item.get('result')}.",
            "gap_or_decision": "Only approved reference metadata was observed; no raw payload was collected.",
            "owner_action": f"Inspect the linked {source_type} source before accepting the transition.",
            "recheck_source": str(metadata.get("source_ref", "")),
            "human_gate": "Any remote write requires controller authorization.",
        })
        return item

    def collect_external_reference(self, **metadata: Any) -> dict[str, Any]:
        return self._collect_normalized([self._external_record(**metadata)])

    def promotions(self, ledger: dict[str, Any] | None = None, *, dry_run: bool = True) -> list[dict[str, Any]]:
        if not dry_run:
            raise ValidationError("remote writes are not supported; verify a dry-run and use the controller")
        source = self._validate_ledger(ledger) if ledger is not None else self._load()
        promotions = []
        for record in source["records"]:
            category = record["promotion_category"]
            if category is None or record["result"] == "superseded":
                continue
            target = record["linear_issue_id"] or record["github_issue_or_pr_id"]
            promotion_id = _identifier(
                "pr", str(target), record["source_type"], record["source_id"],
                record["lifecycle_transition"], category,
            )
            promotions.append({
                "promotion_id": promotion_id, "evidence_id": record["evidence_id"],
                "promotion_category": category, "source_ref": record["source_ref"],
                "claim": {key: record[key] for key in (
                    "fact", "gap_or_decision", "owner_action", "recheck_source", "human_gate", "unknowns"
                )},
                "dry_run": True, "write_performed": False,
            })
        return sorted(promotions, key=lambda item: item["promotion_id"])

    def _material(self, ledger: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        source = self._validate_ledger(ledger) if ledger is not None else self._load()
        return [
            record for record in source["records"]
            if record["promotion_category"] is not None and record["result"] != "superseded"
        ]

    @staticmethod
    def _claim_lines(record: dict[str, Any]) -> list[str]:
        return [
            f"- [{record['result']}] {record['fact']} ({record['source_ref']})",
            f"  - Gap/decision: {record['gap_or_decision']}",
            f"  - Owner/action: {record['owner_action']}",
            f"  - Recheck: {record['recheck_source']}",
            f"  - Human gate: {record['human_gate']}",
            f"  - Unknowns: {', '.join(record['unknowns']) if record['unknowns'] else 'None.'}",
        ]

    def issue_handoff(self, issue: str, ledger: dict[str, Any] | None = None,
                      *, evidence_ids: set[str] | None = None) -> str:
        if not ISSUE_ID.fullmatch(issue):
            raise ValidationError("issue identifier must be bounded metadata")
        if not evidence_ids:
            raise ValidationError("issue handoff requires explicit evidence IDs")
        if any(not EVIDENCE_ID.fullmatch(evidence_id) for evidence_id in evidence_ids):
            raise ValidationError("evidence IDs must be deterministic metadata")
        records = self._material(ledger)
        by_id = {record["evidence_id"]: record for record in records}
        missing = evidence_ids - set(by_id)
        if missing:
            raise ValidationError(f"missing scoped evidence: {', '.join(sorted(missing))}")
        selected = [by_id[evidence_id] for evidence_id in sorted(evidence_ids)]
        if any(issue not in {record["linear_issue_id"], record["github_issue_or_pr_id"]} for record in selected):
            raise ValidationError("scoped evidence is not linked to the requested issue")
        lines = [f"# Evidence handoff: {issue}", ""]
        for record in selected:
            lines.extend(self._claim_lines(record))
        return "\n".join(lines) + "\n"

    def friday_update(self, period: str, ledger: dict[str, Any] | None = None, *,
                      live_linear_evidence_ids: set[str], linked_evidence_ids: set[str]) -> str:
        if not FRIDAY_PERIOD.fullmatch(period):
            raise ValidationError("Friday period must use YYYY-Www metadata format")
        if not live_linear_evidence_ids:
            raise ValidationError("Friday update requires live Linear evidence")
        requested = live_linear_evidence_ids | linked_evidence_ids
        if any(not EVIDENCE_ID.fullmatch(evidence_id) for evidence_id in requested):
            raise ValidationError("evidence IDs must be deterministic metadata")
        records = self._material(ledger)
        by_id = {record["evidence_id"]: record for record in records}
        missing = requested - set(by_id)
        if missing:
            raise ValidationError(f"Friday update is missing linked evidence: {', '.join(sorted(missing))}")
        if any(
            by_id[evidence_id]["source_type"] != "linear"
            or by_id[evidence_id]["result"] == "unobserved"
            or by_id[evidence_id]["revision"] == "unavailable"
            or _is_degraded(by_id[evidence_id])
            for evidence_id in live_linear_evidence_ids
        ):
            raise ValidationError("Friday update is missing live Linear evidence")
        lines = [f"# Friday Project Update: {period}", ""]
        for evidence_id in sorted(requested):
            record = by_id[evidence_id]
            lines.append(f"## {record['promotion_category']}")
            lines.extend(self._claim_lines(record))
        return "\n".join(lines) + "\n"

    @staticmethod
    def route_repeated_feedback(invariant: str, *, evidence_refs: list[str], run_ids: list[str],
                                event_class: str, available_surfaces: list[str],
                                accepted_threshold: int = 2) -> dict[str, Any]:
        if not METADATA_CODE.fullmatch(invariant) or event_class not in FEEDBACK_EVENTS:
            raise ValidationError("feedback invariant and event class must be bounded metadata")
        if len(evidence_refs) != len(run_ids) or not evidence_refs:
            raise ValidationError("feedback evidence and run IDs must be paired")
        if any(not (_https_ref(ref, {"github.com", "linear.app"}) or _is_repo_ref(ref)) for ref in evidence_refs):
            raise ValidationError("feedback evidence must use inspectable approved references")
        repository_root = Path(__file__).resolve().parent.parent
        for ref in evidence_refs:
            if _is_repo_ref(ref):
                evidence_path = (repository_root / ref).resolve()
                if not evidence_path.is_relative_to(repository_root) or not evidence_path.is_file():
                    raise ValidationError("feedback evidence must exist inside the repository")
        if any(not METADATA_CODE.fullmatch(run_id) for run_id in run_ids):
            raise ValidationError("feedback run IDs must be bounded metadata")
        threshold = 1 if event_class in SEVERE_EVENTS else max(2, accepted_threshold)
        if len(set(run_ids)) < threshold:
            return {"status": "below-threshold", "invariant": invariant, "selected_surfaces": []}
        allowed = []
        for surface in dict.fromkeys(available_surfaces):
            if not _is_repo_ref(surface):
                continue
            path = Path(__file__).resolve().parent.parent / surface
            if path.exists() and (
                surface.startswith("docs/") or surface.endswith("SKILL.md")
                or "lint" in surface.casefold() or surface.startswith("tests/")
            ):
                allowed.append(surface)
        if not allowed:
            return {"status": "unobserved", "invariant": invariant, "selected_surfaces": []}
        surface = allowed[0]
        return {"status": "accepted", "invariant": invariant, "surface": surface, "selected_surfaces": [surface]}

    def collect_adapter_items(self, items: Iterable[dict[str, Any]]) -> dict[str, Any]:
        if isinstance(items, (str, bytes, dict)):
            raise ValidationError("CLI input must be a JSON array")
        try:
            raw_items = list(items)
        except TypeError as error:
            raise ValidationError("CLI input must be a JSON array") from error
        records = []
        for raw in raw_items:
            if not isinstance(raw, dict):
                raise ValidationError("CLI input array items must be objects")
            item = dict(raw)
            adapter = item.pop("adapter", None)
            if adapter != "external-reference":
                raise ValidationError("CLI input requires the external-reference adapter")
            allowed = set(REQUIRED) - {
                "privacy_class", "fact", "gap_or_decision", "owner_action", "recheck_source", "human_gate",
            }
            if set(item) - allowed:
                raise ValidationError("external adapter input contains unsupported fields")
            try:
                records.append(self._external_record(**item))
            except TypeError as error:
                raise ValidationError(f"external adapter input is incomplete: {error}") from error
        return self._collect_normalized(records) if records else self._load()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--input", type=Path, help="JSON array of typed external-reference adapter items")
    output_group = parser.add_mutually_exclusive_group()
    output_group.add_argument("--promotions", action="store_true", help="print a remote-write dry-run")
    output_group.add_argument("--issue-handoff", metavar="ISSUE", help="render a scoped issue handoff")
    output_group.add_argument("--friday-update", metavar="PERIOD", help="render a scoped Friday Project Update")
    parser.add_argument("--evidence-id", action="append", default=[], help="evidence ID included in an issue handoff")
    parser.add_argument("--live-linear-evidence-id", action="append", default=[], help="live Linear evidence ID for Friday")
    parser.add_argument("--linked-evidence-id", action="append", default=[], help="linked evidence ID for Friday")
    args = parser.parse_args()
    ledger = EvidenceLedger(args.ledger)
    try:
        result = ledger.collect_adapter_items(_load_json(args.input.read_text())) if args.input else ledger._load()
        if args.issue_handoff:
            if not args.evidence_id:
                parser.error("--issue-handoff requires at least one --evidence-id")
            print(ledger.issue_handoff(args.issue_handoff, result, evidence_ids=set(args.evidence_id)), end="")
        elif args.friday_update:
            if not args.live_linear_evidence_id:
                parser.error("--friday-update requires at least one --live-linear-evidence-id")
            print(ledger.friday_update(
                args.friday_update, result,
                live_linear_evidence_ids=set(args.live_linear_evidence_id),
                linked_evidence_ids=set(args.linked_evidence_id),
            ), end="")
        else:
            output: Any = ledger.promotions(result, dry_run=True) if args.promotions else result
            print(_canonical(output).decode(), end="")
    except (OSError, json.JSONDecodeError, ValidationError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
