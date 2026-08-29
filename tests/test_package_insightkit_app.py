from pathlib import Path


def test_package_uses_swiftpm_reported_binary_directory() -> None:
    script = Path("scripts/package_insightkit_app.sh").read_text()

    assert "--show-bin-path" in script
    assert 'bin_path="$bin_dir/$EXECUTABLE_NAME"' in script
