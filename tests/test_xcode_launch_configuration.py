from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def launch_spec():
    xcodegen = shutil.which("xcodegen")
    if xcodegen is None:
        pytest.skip("XcodeGen launch configuration check runs on the macOS development host")
    result = subprocess.run(
        [xcodegen, "dump", "--type", "json", "--no-env", "--spec", "macos/InsightKitApp/project.yml"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=15,
        check=True,
    )
    return json.loads(result.stdout)


@pytest.mark.parametrize(
    ("action", "bundle_id", "url_scheme"),
    [
        ("run", "com.yannjy.insightkit", "insightkit"),
        ("test", "com.yannjy.insightkit.uitesthost", "insightkit-uitest"),
    ],
)
def test_run_and_test_use_their_own_registered_identity(launch_spec, action, bundle_id, url_scheme):
    scheme = launch_spec["schemes"]["InsightKitApp"]
    config = scheme[action]["config"]
    target = launch_spec["targets"]["InsightKitApp"]
    declared = target["settings"]
    settings = declared["base"] | declared.get("configs", {}).get(config, {})

    assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == bundle_id
    assert scheme["run"]["config"] != scheme["test"]["config"]
    url_types = target["info"]["properties"]["CFBundleURLTypes"]
    registered = [value for item in url_types for value in item["CFBundleURLSchemes"]]
    expanded = [re.sub(r"\$\(([^)]+)\)", lambda match: settings[match[1]], value) for value in registered]
    assert expanded == [url_scheme]
