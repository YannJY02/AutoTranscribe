from pathlib import Path


def test_package_uses_swiftpm_reported_binary_directory() -> None:
    script = Path("scripts/package_insightkit_app.sh").read_text()

    assert "--show-bin-path" in script
    assert 'bin_path="$bin_dir/$EXECUTABLE_NAME"' in script


def test_sentry_release_accepts_packaged_timestamp_build() -> None:
    package_script = Path("scripts/package_insightkit_app.sh").read_text()
    sentry_script = Path("scripts/sentry_release.sh").read_text()

    assert 'build_number="$(date +%Y%m%d%H%M%S)"' in package_script
    assert '[[ "$build" =~ ^[0-9]{1,14}$ ]]' in sentry_script
