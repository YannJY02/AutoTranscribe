import os
import plistlib
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


def test_package_uses_swiftpm_reported_binary_directory() -> None:
    script = Path("scripts/package_insightkit_app.sh").read_text()

    assert "--show-bin-path" in script
    assert 'bin_path="$bin_dir/$EXECUTABLE_NAME"' in script


def test_sentry_release_accepts_packaged_timestamp_build() -> None:
    package_script = Path("scripts/package_insightkit_app.sh").read_text()
    sentry_script = Path("scripts/sentry_release.sh").read_text()

    assert 'build_number="$(date +%Y%m%d%H%M%S)"' in package_script
    assert '[[ "$build" =~ ^[0-9]{1,14}$ ]]' in sentry_script


@pytest.fixture
def package_workspace(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    """Run the real packaging script without compiling or signing real code."""
    root = tmp_path / "workspace"
    scripts = root / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2("scripts/package_insightkit_app.sh", scripts)
    config_helper = Path("scripts/local_bundle_configuration.py")
    if config_helper.exists():
        shutil.copy2(config_helper, scripts)
    (root / "macos/InsightKitApp").mkdir(parents=True)
    runtime = root / "insightkit/ipc"
    runtime.mkdir(parents=True)
    capabilities = [
        "transcription.status", "asr.runtime.status", "asr.runtime.bootstrap",
        "diagnostics.quick_check", "asr.transcribe_live_chunk", "asr.enrich_live_chunk",
    ]
    (runtime / "server.py").write_text("\n".join(f'"{cap}"' for cap in capabilities))
    binaries = root / "built binaries"
    binaries.mkdir()
    for name in ("InsightKitApp", "InsightKitLiveDiarization"):
        path = binaries / name
        path.write_text("test executable\n")
        path.chmod(0o755)
    fake_bin = root / "tools"
    fake_bin.mkdir()
    stubs = {
        "swift": f'case " $* " in *" --show-bin-path "*) printf "%s\\n" {shlex.quote(str(binaries))};; esac\n',
        "codesign": "exit 0\n",
        "ditto": 'cp -R "$1" "$2"\n',
        "rsync": f'exec {shlex.quote(sys.executable)} -c \'import shutil,sys; shutil.copytree(sys.argv[-2], sys.argv[-1], dirs_exist_ok=True)\' "$@"\n',
    }
    for name, body in stubs.items():
        path = fake_bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
    builder = scripts / "build_live_diarization_worker.sh"
    builder.write_text(f'#!/bin/sh\nprintf "%s\\n" {shlex.quote(str(binaries / "InsightKitLiveDiarization"))}\n')
    builder.chmod(0o755)
    env = dict(os.environ)
    for key in ("INSIGHTKIT_ENTITLEMENTS_PATH", "INSIGHTKIT_SIGN_IDENTITY", "INSIGHTKIT_DISTRIBUTION"):
        env.pop(key, None)
    env["PATH"] = str(fake_bin) + os.pathsep + env["PATH"]
    return root, env


def _owner_pilot_bundle(app: Path) -> dict:
    info = {
        "CFBundleIdentifier": "com.yannjy.insightkit",
        "InsightKitPostHogOwnerPilotHost": "https://example.test",
        "InsightKitPostHogOwnerPilotProjectKey": "fixture-public-project-key",
        "InsightKitPostHogOwnerPilotRetentionVerified": True,
        "LSEnvironment": {
            "INSIGHTKIT_ANALYTICS_ENVIRONMENT": "owner-pilot",
            "UNRELATED_PROVIDER_SECRET": "do-not-copy",
        },
    }
    (app / "Contents").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    return info


def _package(root: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(root / "scripts/package_insightkit_app.sh"), "--adhoc-sign",
         "--output-dir", str(root / "output"), *args],
        env=env, text=True, capture_output=True, timeout=20, check=False,
    )


def test_local_update_preserves_owner_pilot_launch_configuration(package_workspace) -> None:
    root, env = package_workspace
    installed = root / "installed/InsightKit.app"
    original = _owner_pilot_bundle(installed)

    result = _package(root, env, "--install-dir", str(installed.parent))

    assert result.returncode == 0, result.stderr
    actual = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
    assert actual.get("LSEnvironment", {}).get("INSIGHTKIT_ANALYTICS_ENVIRONMENT") == "owner-pilot"
    for key in original:
        if key.startswith("InsightKitPostHogOwnerPilot"):
            assert actual[key] == original[key]
    assert "UNRELATED_PROVIDER_SECRET" not in actual.get("LSEnvironment", {})


def test_package_without_local_source_keeps_telemetry_disabled(package_workspace) -> None:
    root, env = package_workspace
    result = _package(root, env)
    assert result.returncode == 0, result.stderr
    actual = plistlib.loads((root / "output/InsightKit.app/Contents/Info.plist").read_bytes())
    assert actual["InsightKitPostHogOwnerPilotRetentionVerified"] is False
    assert "INSIGHTKIT_ANALYTICS_ENVIRONMENT" not in actual.get("LSEnvironment", {})


def test_explicit_local_source_repairs_an_install_with_missing_selector(package_workspace) -> None:
    root, env = package_workspace
    backup = root / "prior owner app/InsightKit.app"
    _owner_pilot_bundle(backup)
    installed = root / "installed/InsightKit.app"
    broken = _owner_pilot_bundle(installed)
    broken.pop("LSEnvironment")
    (installed / "Contents/Info.plist").write_bytes(plistlib.dumps(broken))

    result = _package(root, env, "--install-dir", str(installed.parent),
                      "--preserve-local-config-from", str(backup))

    assert result.returncode == 0, result.stderr
    actual = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
    assert actual["LSEnvironment"]["INSIGHTKIT_ANALYTICS_ENVIRONMENT"] == "owner-pilot"


def test_distribution_build_rejects_local_configuration(package_workspace) -> None:
    root, env = package_workspace
    source = root / "prior owner app/InsightKit.app"
    _owner_pilot_bundle(source)

    result = _package(root, env, "--developer-id", "--preserve-local-config-from", str(source))

    assert result.returncode != 0
    assert "cannot be copied into a distribution build" in result.stderr
    assert not (root / "output/InsightKit.app").exists()
