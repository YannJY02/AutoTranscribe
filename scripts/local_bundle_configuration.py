#!/usr/bin/env python3
"""Preserve the installed app's explicit owner-pilot bundle configuration.

This only reads Info.plist and a private snapshot; it never reads preferences or
infers whether analytics should be enabled. Exit codes: 0 success, 1 verification
mismatch, 2 invalid input or an I/O failure. Reports contain no configuration values.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
from typing import Any
from xml.parsers.expat import ExpatError


BUNDLE_IDENTIFIER = "com.yannjy.insightkit"
INFO_FIELDS = {
    "InsightKitPostHogOwnerPilotHost": str,
    "InsightKitPostHogOwnerPilotProjectKey": str,
    "InsightKitPostHogOwnerPilotRetentionVerified": bool,
}
ENVIRONMENT_FIELDS = {
    "INSIGHTKIT_ANALYTICS_ENVIRONMENT": str,
    "POSTHOG_OWNER_PILOT_HOST": str,
    "POSTHOG_OWNER_PILOT_PROJECT_KEY": str,
    "POSTHOG_OWNER_PILOT_RETENTION_VERIFIED": str,
}


class ConfigurationError(Exception):
    """Only a fixed field name is exposed, never parser errors or field values."""

    def __init__(self, field: str):
        self.field = field
        super().__init__(field)


def _read_bundle(app: Path, role: str) -> tuple[Path, bytes, dict[str, Any]]:
    info_path = app / "Contents" / "Info.plist"
    try:
        raw = info_path.read_bytes()
        info = plistlib.loads(raw)
    except (OSError, ValueError, TypeError, OverflowError, ExpatError) as error:
        raise ConfigurationError(f"{role}.Info.plist") from error
    if not isinstance(info, dict):
        raise ConfigurationError(f"{role}.Info.plist")
    if info.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER:
        raise ConfigurationError(f"{role}.CFBundleIdentifier")
    if "LSEnvironment" in info and not isinstance(info["LSEnvironment"], dict):
        raise ConfigurationError(f"{role}.LSEnvironment")
    return info_path, raw, info


def _validate_section(
    section: Any, fields: dict[str, type], name: str
) -> dict[str, Any]:
    if not isinstance(section, dict) or not section.keys() <= fields.keys():
        raise ConfigurationError(name)
    for field, value in section.items():
        if type(value) is not fields[field]:
            raise ConfigurationError(f"{name}.{field}")
    return section


def _read_snapshot(path: Path) -> dict[str, Any]:
    try:
        snapshot = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError) as error:
        raise ConfigurationError("snapshot") from error
    expected_keys = {"schema_version", "bundle_identifier", "info_plist", "launch_environment"}
    if not isinstance(snapshot, dict) or snapshot.keys() != expected_keys:
        raise ConfigurationError("snapshot")
    if type(snapshot["schema_version"]) is not int or snapshot["schema_version"] != 1:
        raise ConfigurationError("snapshot.schema_version")
    if snapshot["bundle_identifier"] != BUNDLE_IDENTIFIER:
        raise ConfigurationError("snapshot.bundle_identifier")
    _validate_section(snapshot["info_plist"], INFO_FIELDS, "snapshot.info_plist")
    _validate_section(
        snapshot["launch_environment"], ENVIRONMENT_FIELDS, "snapshot.launch_environment"
    )
    return snapshot


def _require_distinct(output: Path, inputs: tuple[Path, ...], field: str) -> None:
    if any(output.resolve() == item.resolve() for item in inputs):
        raise ConfigurationError(field)


def _atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".local-bundle-config-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def _json_bytes(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _presence_report(snapshot: dict[str, Any]) -> dict[str, Any]:
    fields = {}
    for section, prefix, names in (
        ("info_plist", "Info", INFO_FIELDS),
        ("launch_environment", "LSEnvironment", ENVIRONMENT_FIELDS),
    ):
        for name in names:
            fields[f"{prefix}.{name}"] = {"present": name in snapshot[section]}
    return {"ok": True, "fields": fields}


def snapshot_configuration(source_app: Path, output: Path) -> dict[str, Any]:
    info_path, _, info = _read_bundle(source_app, "source")
    _require_distinct(output, (info_path,), "snapshot.output")
    environment = info.get("LSEnvironment", {})
    snapshot = {
        "schema_version": 1,
        "bundle_identifier": BUNDLE_IDENTIFIER,
        "info_plist": _validate_section(
            {name: info[name] for name in INFO_FIELDS if name in info},
            INFO_FIELDS,
            "source.Info",
        ),
        "launch_environment": _validate_section(
            {name: environment[name] for name in ENVIRONMENT_FIELDS if name in environment},
            ENVIRONMENT_FIELDS,
            "source.LSEnvironment",
        ),
    }
    _atomic_write(output, _json_bytes(snapshot))
    return _presence_report(snapshot)


def apply_configuration(snapshot_path: Path, target_app: Path) -> dict[str, Any]:
    snapshot = _read_snapshot(snapshot_path)
    info_path, raw, info = _read_bundle(target_app, "target")
    _require_distinct(info_path, (snapshot_path,), "snapshot")
    for name in INFO_FIELDS:
        info.pop(name, None)
    info.update(snapshot["info_plist"])

    if "LSEnvironment" in info or snapshot["launch_environment"]:
        environment = dict(info.get("LSEnvironment", {}))
        for name in ENVIRONMENT_FIELDS:
            environment.pop(name, None)
        environment.update(snapshot["launch_environment"])
        info["LSEnvironment"] = environment

    plist_format = plistlib.FMT_BINARY if raw.startswith(b"bplist00") else plistlib.FMT_XML
    mode = stat.S_IMODE(info_path.stat().st_mode)
    _atomic_write(info_path, plistlib.dumps(info, fmt=plist_format, sort_keys=False), mode)
    return _presence_report(snapshot)


def verify_configuration(
    snapshot_path: Path, target_app: Path, receipt: Path | None = None
) -> dict[str, Any]:
    snapshot = _read_snapshot(snapshot_path)
    info_path, _, info = _read_bundle(target_app, "target")
    if receipt is not None:
        _require_distinct(receipt, (snapshot_path, info_path), "receipt")
    fields = {}
    for expected, actual, prefix, names in (
        (snapshot["info_plist"], info, "Info", INFO_FIELDS),
        (snapshot["launch_environment"], info.get("LSEnvironment", {}), "LSEnvironment", ENVIRONMENT_FIELDS),
    ):
        for name in names:
            expected_present = name in expected
            actual_present = name in actual
            matches = expected_present == actual_present and (
                not expected_present
                or (type(expected[name]) is type(actual[name]) and expected[name] == actual[name])
            )
            fields[f"{prefix}.{name}"] = {
                "expected_present": expected_present,
                "actual_present": actual_present,
                "matches": matches,
            }
    report = {"ok": all(field["matches"] for field in fields.values()), "fields": fields}
    if receipt is not None:
        _atomic_write(receipt, _json_bytes(report))
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("--source-app", type=Path, required=True)
    snapshot.add_argument("--output", type=Path, required=True)
    apply = commands.add_parser("apply")
    apply.add_argument("--snapshot", type=Path, required=True)
    apply.add_argument("--target-app", type=Path, required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--snapshot", type=Path, required=True)
    verify.add_argument("--target-app", type=Path, required=True)
    verify.add_argument("--receipt", type=Path)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "snapshot":
            report = snapshot_configuration(arguments.source_app, arguments.output)
        elif arguments.command == "apply":
            report = apply_configuration(arguments.snapshot, arguments.target_app)
        else:
            report = verify_configuration(arguments.snapshot, arguments.target_app, arguments.receipt)
    except ConfigurationError as error:
        print(json.dumps({"ok": False, "valid_fields": {error.field: False}}), file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError, OverflowError):
        print(json.dumps({"ok": False, "valid_fields": {"file_operation": False}}), file=sys.stderr)
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
