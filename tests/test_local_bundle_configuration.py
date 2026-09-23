import json
from pathlib import Path
import plistlib
import stat
import subprocess
import sys

import pytest

from scripts.local_bundle_configuration import (
    BUNDLE_IDENTIFIER,
    ENVIRONMENT_FIELDS,
    INFO_FIELDS,
)


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "local_bundle_configuration.py"
SELECTOR = "INSIGHTKIT_ANALYTICS_ENVIRONMENT"
HOST = "InsightKitPostHogOwnerPilotHost"
PROJECT_KEY = "InsightKitPostHogOwnerPilotProjectKey"
RETENTION = "InsightKitPostHogOwnerPilotRetentionVerified"


def app_info() -> dict:
    return {
        "CFBundleIdentifier": BUNDLE_IDENTIFIER,
        "CFBundleVersion": "source-version",
        HOST: "https://private-source-host.invalid/never-log",
        PROJECT_KEY: "private-source-project-key-never-log",
        RETENTION: True,
        "LSEnvironment": {
            SELECTOR: "owner-pilot",
            "POSTHOG_OWNER_PILOT_HOST": "https://private-environment-host.invalid/never-log",
            "POSTHOG_OWNER_PILOT_PROJECT_KEY": "private-environment-project-key-never-log",
            "POSTHOG_OWNER_PILOT_RETENTION_VERIFIED": "yes",
        },
    }


def write_app(path: Path, info: dict, *, binary: bool = False) -> Path:
    destination = path / "Contents" / "Info.plist"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML))
    return destination


def read_app(path: Path) -> dict:
    return plistlib.loads((path / "Contents" / "Info.plist").read_bytes())


def run_cli(*arguments: str | Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *(str(argument) for argument in arguments)],
        capture_output=True,
        text=True,
        check=False,
    )


def make_snapshot(tmp_path: Path, info: dict) -> Path:
    source = tmp_path / "Source.app"
    write_app(source, info)
    snapshot = tmp_path / "snapshot.json"
    result = run_cli("snapshot", "--source-app", source, "--output", snapshot)
    assert result.returncode == 0, result.stderr
    assert "never-log" not in result.stdout + result.stderr
    return snapshot


def assert_boolean_report(value: dict) -> None:
    for item in value.values():
        if isinstance(item, dict):
            assert_boolean_report(item)
        else:
            assert type(item) is bool


def test_verify_detects_lost_selector_even_when_all_owner_pilot_credentials_survive(tmp_path: Path) -> None:
    original = app_info()
    snapshot = make_snapshot(tmp_path, original)
    rebuilt = app_info()
    del rebuilt["LSEnvironment"][SELECTOR]
    target = tmp_path / "Rebuilt.app"
    write_app(target, rebuilt)
    receipt = tmp_path / "missing-selector-receipt.json"

    result = run_cli("verify", "--snapshot", snapshot, "--target-app", target, "--receipt", receipt)

    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["ok"] is False
    assert report["fields"][f"LSEnvironment.{SELECTOR}"] == {
        "expected_present": True,
        "actual_present": False,
        "matches": False,
    }
    assert all(report["fields"][f"Info.{name}"]["matches"] for name in INFO_FIELDS)
    assert json.loads(receipt.read_text()) == report
    assert_boolean_report(report)
    assert "never-log" not in result.stdout + result.stderr + receipt.read_text()


def test_apply_restores_complete_configuration_and_verify_produces_private_receipt(tmp_path: Path) -> None:
    original = app_info()
    snapshot = make_snapshot(tmp_path, original)
    target = tmp_path / "Target.app"
    write_app(target, {"CFBundleIdentifier": BUNDLE_IDENTIFIER, "CFBundleVersion": "new-version"})

    applied = run_cli("apply", "--snapshot", snapshot, "--target-app", target)
    receipt = tmp_path / "receipt.json"
    verified = run_cli("verify", "--snapshot", snapshot, "--target-app", target, "--receipt", receipt)

    assert applied.returncode == verified.returncode == 0
    actual = read_app(target)
    assert actual["CFBundleVersion"] == "new-version"
    assert {name: actual[name] for name in INFO_FIELDS} == {name: original[name] for name in INFO_FIELDS}
    assert actual["LSEnvironment"] == original["LSEnvironment"]
    report = json.loads(verified.stdout)
    assert all(field["matches"] for field in report["fields"].values())
    assert json.loads(receipt.read_text()) == report
    assert_boolean_report(report)
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600
    assert "never-log" not in applied.stdout + verified.stdout + receipt.read_text()


def test_absent_configuration_removes_target_whitelist_without_enabling_anything(tmp_path: Path) -> None:
    snapshot = make_snapshot(tmp_path, {"CFBundleIdentifier": BUNDLE_IDENTIFIER})
    original_target = app_info()
    original_target["LSEnvironment"]["KEEP_TARGET_ENV"] = "keep"
    target = tmp_path / "Target.app"
    write_app(target, original_target)

    assert run_cli("apply", "--snapshot", snapshot, "--target-app", target).returncode == 0
    actual = read_app(target)
    assert all(name not in actual for name in INFO_FIELDS)
    assert actual["LSEnvironment"] == {"KEEP_TARGET_ENV": "keep"}
    assert run_cli("verify", "--snapshot", snapshot, "--target-app", target).returncode == 0
    saved = json.loads(snapshot.read_text())
    assert saved["info_plist"] == saved["launch_environment"] == {}


def test_missing_selector_is_not_inferred_from_existing_owner_pilot_credentials(tmp_path: Path) -> None:
    source = app_info()
    del source["LSEnvironment"][SELECTOR]
    snapshot = make_snapshot(tmp_path, source)
    target = tmp_path / "Target.app"
    write_app(target, app_info())

    assert run_cli("apply", "--snapshot", snapshot, "--target-app", target).returncode == 0
    actual = read_app(target)
    assert actual[RETENTION] is True
    assert SELECTOR not in actual["LSEnvironment"]
    assert run_cli("verify", "--snapshot", snapshot, "--target-app", target).returncode == 0


def test_disabled_and_empty_values_are_preserved_without_normalization(tmp_path: Path) -> None:
    source = app_info()
    source[RETENTION] = False
    source[HOST] = ""
    source[PROJECT_KEY] = ""
    source["LSEnvironment"][SELECTOR] = "release"
    source["LSEnvironment"]["POSTHOG_OWNER_PILOT_RETENTION_VERIFIED"] = "0"
    snapshot = make_snapshot(tmp_path, source)
    target = tmp_path / "Target.app"
    write_app(target, app_info())

    assert run_cli("apply", "--snapshot", snapshot, "--target-app", target).returncode == 0
    assert read_app(target) == source
    assert run_cli("verify", "--snapshot", snapshot, "--target-app", target).returncode == 0


def test_source_secrets_and_unrelated_configuration_are_not_copied(tmp_path: Path) -> None:
    source = app_info()
    source.update({"SentryDSN": "source-secret-canary", "RecordsRoot": "source-records-canary"})
    source["LSEnvironment"].update({
        "SENTRY_DSN": "source-env-secret-canary",
        "OPENAI_API_KEY": "source-api-secret-canary",
        "INSIGHTKIT_POSTHOG_OWNER_PILOT_PROJECT_KEY": "wrong-prefix-secret-canary",
        "INSIGHTKIT_ANALYTICS_CONSENT": "source-consent-canary",
        "INSIGHTKIT_ASR_MODEL": "source-model-canary",
    })
    snapshot = make_snapshot(tmp_path, source)
    assert "canary" not in snapshot.read_text()
    target = tmp_path / "Target.app"
    unrelated = {
        "CFBundleIdentifier": BUNDLE_IDENTIFIER,
        "CFBundleVersion": "new-version",
        "SentryDSN": "target-sentry-keep",
        "RecordsRoot": "target-records-keep",
        "LSEnvironment": {"SENTRY_DSN": "target-sentry-env-keep", "INSIGHTKIT_ASR_MODEL": "target-model-keep"},
    }
    write_app(target, unrelated)

    result = run_cli("apply", "--snapshot", snapshot, "--target-app", target)

    assert result.returncode == 0
    actual = read_app(target)
    for name in ("CFBundleVersion", "SentryDSN", "RecordsRoot"):
        assert actual[name] == unrelated[name]
    for name, value in unrelated["LSEnvironment"].items():
        assert actual["LSEnvironment"][name] == value
    assert "canary" not in json.dumps(actual)
    assert "never-log" not in result.stdout + result.stderr


@pytest.mark.parametrize("case", ["missing", "invalid_plist", "list_root", "wrong_bundle", "invalid_environment", "invalid_host", "invalid_retention", "invalid_environment_value"])
def test_invalid_source_fails_without_creating_snapshot(tmp_path: Path, case: str) -> None:
    source = tmp_path / "Source.app"
    info = app_info()
    if case == "wrong_bundle":
        info["CFBundleIdentifier"] = "invalid-bundle-secret-never-log"
    elif case == "invalid_environment":
        info["LSEnvironment"] = "invalid-environment-secret-never-log"
    elif case == "invalid_host":
        info[HOST] = 42
    elif case == "invalid_retention":
        info[RETENTION] = "true"
    elif case == "invalid_environment_value":
        info["LSEnvironment"][SELECTOR] = True
    if case != "missing":
        info_path = write_app(source, info)
        if case == "invalid_plist":
            info_path.write_bytes(b"invalid-secret-plist-never-log")
        elif case == "list_root":
            info_path.write_bytes(plistlib.dumps(["root-secret-never-log"]))
    snapshot = tmp_path / "snapshot.json"

    result = run_cli("snapshot", "--source-app", source, "--output", snapshot)

    assert result.returncode == 2
    assert not snapshot.exists()
    assert "never-log" not in result.stdout + result.stderr
    assert_boolean_report(json.loads(result.stderr))


@pytest.mark.parametrize("invalid", [b"broken-secret-never-log", plistlib.dumps({"CFBundleIdentifier": "wrong-secret-never-log"})])
def test_invalid_target_fails_without_mutation(tmp_path: Path, invalid: bytes) -> None:
    snapshot = make_snapshot(tmp_path, app_info())
    target = tmp_path / "Target.app"
    info_path = write_app(target, app_info())
    info_path.write_bytes(invalid)

    for command in ("apply", "verify"):
        result = run_cli(command, "--snapshot", snapshot, "--target-app", target)
        assert result.returncode == 2
        assert info_path.read_bytes() == invalid
        assert "never-log" not in result.stdout + result.stderr


@pytest.mark.parametrize("exists", [False, True])
def test_snapshot_is_mode_0600_even_when_replacing_a_public_file(tmp_path: Path, exists: bool) -> None:
    source = tmp_path / "Source.app"
    write_app(source, app_info())
    snapshot = tmp_path / "snapshot.json"
    if exists:
        snapshot.write_text("old")
        snapshot.chmod(0o644)

    result = run_cli("snapshot", "--source-app", source, "--output", snapshot)

    assert result.returncode == 0
    assert stat.S_IMODE(snapshot.stat().st_mode) == 0o600
    saved = json.loads(snapshot.read_text())
    assert set(saved["info_plist"]) == set(INFO_FIELDS)
    assert set(saved["launch_environment"]) == set(ENVIRONMENT_FIELDS)


def test_snapshot_survives_repackaging_at_the_same_app_path(tmp_path: Path) -> None:
    source_and_target = tmp_path / "InsightKit.app"
    original = app_info()
    write_app(source_and_target, original)
    snapshot = tmp_path / "snapshot.json"
    assert run_cli("snapshot", "--source-app", source_and_target, "--output", snapshot).returncode == 0
    write_app(source_and_target, {"CFBundleIdentifier": BUNDLE_IDENTIFIER, "CFBundleVersion": "rebuilt"})

    assert run_cli("apply", "--snapshot", snapshot, "--target-app", source_and_target).returncode == 0
    assert run_cli("verify", "--snapshot", snapshot, "--target-app", source_and_target).returncode == 0
    assert read_app(source_and_target)["CFBundleVersion"] == "rebuilt"
    assert read_app(source_and_target)["LSEnvironment"][SELECTOR] == "owner-pilot"


def test_apply_preserves_target_binary_plist_format_and_permissions(tmp_path: Path) -> None:
    snapshot = make_snapshot(tmp_path, app_info())
    target = tmp_path / "Target.app"
    info_path = write_app(target, {"CFBundleIdentifier": BUNDLE_IDENTIFIER}, binary=True)
    info_path.chmod(0o640)

    assert run_cli("apply", "--snapshot", snapshot, "--target-app", target).returncode == 0

    assert info_path.read_bytes().startswith(b"bplist00")
    assert stat.S_IMODE(info_path.stat().st_mode) == 0o640


@pytest.mark.parametrize("section", ["root", "info_plist", "launch_environment", "schema_version"])
def test_invalid_snapshot_cannot_inject_unlisted_fields(tmp_path: Path, section: str) -> None:
    snapshot = make_snapshot(tmp_path, app_info())
    saved = json.loads(snapshot.read_text())
    if section == "root":
        saved["unknown-secret-never-log"] = "value"
    elif section == "schema_version":
        saved["schema_version"] = True
    else:
        saved[section]["unknown-secret-never-log"] = "value"
    snapshot.write_text(json.dumps(saved))
    target = tmp_path / "Target.app"
    original = {"CFBundleIdentifier": BUNDLE_IDENTIFIER}
    write_app(target, original)

    result = run_cli("apply", "--snapshot", snapshot, "--target-app", target)

    assert result.returncode == 2
    assert read_app(target) == original
    assert "never-log" not in result.stdout + result.stderr


def test_verify_checks_value_types_without_treating_integer_one_as_true(tmp_path: Path) -> None:
    snapshot = make_snapshot(tmp_path, app_info())
    target = tmp_path / "Target.app"
    info = app_info()
    info[RETENTION] = 1
    write_app(target, info)

    result = run_cli("verify", "--snapshot", snapshot, "--target-app", target)

    assert result.returncode == 1
    assert json.loads(result.stdout)["fields"][f"Info.{RETENTION}"]["matches"] is False


def test_report_destinations_cannot_overwrite_inputs(tmp_path: Path) -> None:
    target = tmp_path / "Target.app"
    info_path = write_app(target, app_info())
    original_info = info_path.read_bytes()
    collision = run_cli("snapshot", "--source-app", target, "--output", info_path)
    assert collision.returncode == 2
    assert info_path.read_bytes() == original_info
    snapshot = make_snapshot(tmp_path, app_info())
    original_snapshot = snapshot.read_bytes()

    for receipt in (snapshot, info_path):
        result = run_cli("verify", "--snapshot", snapshot, "--target-app", target, "--receipt", receipt)
        assert result.returncode == 2
        assert info_path.read_bytes() == original_info
        assert snapshot.read_bytes() == original_snapshot
