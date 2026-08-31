#!/usr/bin/env python3
"""Reconcile privacy-safe aggregate telemetry counts without attempt identifiers."""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


CONTRACT_KEYS = ("schema_version", "environment", "window_start", "window_end")


def normalize_remote(remote):
    if not isinstance(remote, list):
        return remote
    if not remote:
        return {"query_error": "empty-readback"}
    first = remote[0]
    counts = {
        "|".join([row["event_name"], row.get("workflow") or "none", row.get("analysis_mode") or "none"]): row["remote_count"]
        for row in remote
    }
    return {**{key: first.get(key) for key in CONTRACT_KEYS}, "event_counts": counts}


def reconcile(local: dict, remote: dict, now: datetime | None = None) -> dict:
    remote = normalize_remote(remote)
    now = now or datetime.now(timezone.utc)
    expiry = local.get("retention_expires_at")
    try:
        retention_expired = bool(expiry) and now >= datetime.fromisoformat(expiry.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        retention_expired = bool(expiry)
    contract_matches = all(
        key in local and local.get(key) is not None and key in remote and remote.get(key) is not None
        and remote[key] == local[key]
        for key in CONTRACT_KEYS
    )
    if remote.get("query_error"):
        state = "query-failure"
    elif not contract_matches:
        state = "readback-contract-mismatch"
    elif retention_expired:
        state = "retention-window-expired"
    elif local.get("opted_out"):
        state = "opt-out"
    elif local.get("deletion_pending"):
        state = "deletion-pending"
    elif local.get("offline_pending", 0) > 0:
        state = "late-offline-delivery"
    elif local.get("event_counts", {}) != remote.get("event_counts", {}):
        state = "partial-ingestion"
    else:
        state = "complete"
    return {
        "schema_version": local.get("schema_version"),
        "environment": local.get("environment"),
        "window_start": local.get("window_start"),
        "window_end": local.get("window_end"),
        "retention_expires_at": expiry,
        "evidence_state": state,
        "local_event_counts": local.get("event_counts", {}),
        "remote_event_counts": remote.get("event_counts", {}),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("local_manifest", type=Path)
    parser.add_argument("remote_readback", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = reconcile(json.loads(args.local_manifest.read_text()), json.loads(args.remote_readback.read_text()))
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
