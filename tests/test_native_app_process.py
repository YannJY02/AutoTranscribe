from __future__ import annotations

import contextlib
import ctypes
import errno
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
from unittest import mock

import pytest

from scripts.native_app_process import executable_process_ids, test_executable as resolve_test_executable, unique_process_id


@pytest.fixture
def test_layout(tmp_path):
    derived_data = tmp_path / "Derived Data With Spaces"
    bundle = derived_data / "Build/Products/UITesting/InsightKitApp.app"
    executable = bundle / "Contents/MacOS/IKTraceFixture"
    executable.parent.mkdir(parents=True)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.yannjy.insightkit.uitesthost",
        "CFBundleExecutable": executable.name,
    }))
    scheme = tmp_path / "Test Scheme.xcscheme"
    scheme.write_text('<Scheme><TestAction buildConfiguration="UITesting" /></Scheme>')
    return derived_data, scheme, executable


@pytest.fixture(scope="module")
def synthetic_binary(tmp_path_factory):
    if sys.platform != "darwin":
        pytest.skip("Native process-path checks require macOS ps")
    compiler = shutil.which("cc")
    if compiler is None:
        pytest.skip("Synthetic process fixture requires the macOS C compiler")
    root = tmp_path_factory.mktemp("trace-process")
    source = root / "fixture.c"
    source.write_text('#include <unistd.h>\nint main(void) { for (;;) pause(); }\n')
    binary = root / "IKTraceFixture"
    subprocess.run([compiler, str(source), "-o", str(binary)], check=True, capture_output=True, timeout=30)
    return binary


@contextlib.contextmanager
def running(executable, *, argv0=None):
    process = subprocess.Popen(
        [str(argv0 or executable)], executable=str(executable),
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        yield process.pid
    finally:
        process.terminate()
        process.wait(timeout=5)


def test_waits_for_exact_host_and_rejects_ambiguous_processes(test_layout, synthetic_binary, tmp_path):
    derived_data, scheme, expected = test_layout
    shutil.copy2(synthetic_binary, expected)
    operator = tmp_path / "Operator App With Spaces" / expected.name
    operator.parent.mkdir()
    shutil.copy2(synthetic_binary, operator)
    assert resolve_test_executable(derived_data, scheme) == expected.resolve()
    assert unique_process_id(expected) is None

    def invoke_selector():
        return subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parents[1] / "scripts/native_app_process.py"),
             "--derived-data", str(derived_data), "--scheme", str(scheme)],
            capture_output=True, text=True, timeout=10,
        )

    with running(operator):
        assert unique_process_id(expected) is None
        result = invoke_selector()
        assert result.returncode == 1 and result.stdout == ""
        with running(expected) as expected_pid:
            assert unique_process_id(expected) == expected_pid
            result = invoke_selector()
            assert result.returncode == 0 and result.stdout.strip() == str(expected_pid)
            with running(expected):
                assert unique_process_id(expected) is None
                result = invoke_selector()
                assert result.returncode == 1 and result.stdout == ""
        assert unique_process_id(expected) is None

    with running(expected) as expected_pid:
        assert unique_process_id(expected) == expected_pid


def test_argv0_cannot_impersonate_the_test_executable(test_layout, synthetic_binary, tmp_path):
    _, _, expected = test_layout
    shutil.copy2(synthetic_binary, expected)
    operator = tmp_path / "other" / expected.name
    operator.parent.mkdir()
    shutil.copy2(synthetic_binary, operator)
    with running(operator, argv0=expected):
        assert unique_process_id(expected) is None


def test_missing_or_wrong_bundle_cannot_supply_an_executable(test_layout):
    derived_data, scheme, expected = test_layout
    assert resolve_test_executable(derived_data, scheme) is None
    expected.touch()
    info = expected.parents[1] / "Info.plist"
    info.write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.yannjy.insightkit",
        "CFBundleExecutable": expected.name,
    }))
    assert resolve_test_executable(derived_data, scheme) is None


def test_executable_symlink_outside_derived_data_is_not_a_test_host(test_layout, tmp_path):
    derived_data, scheme, expected = test_layout
    outside = tmp_path / "outside-executable"
    outside.touch()
    expected.symlink_to(outside)
    assert resolve_test_executable(derived_data, scheme) is None


@pytest.mark.parametrize("failure", [OSError("unavailable"), subprocess.TimeoutExpired("ps", 5)])
def test_process_query_failure_does_not_return_a_pid(tmp_path, failure):
    expected = tmp_path / "test-executable"
    expected.touch()
    with mock.patch("scripts.native_app_process.subprocess.run", side_effect=failure):
        assert executable_process_ids(expected) is None
        assert unique_process_id(expected) is None


@pytest.mark.parametrize("status, output", [(1, "123\n"), (0, ""), (0, "not-a-pid\n")])
def test_unusable_pid_snapshot_does_not_return_partial_results(tmp_path, status, output):
    expected = tmp_path / "test-executable"
    expected.touch()
    with mock.patch("scripts.native_app_process.subprocess.run", return_value=subprocess.CompletedProcess([], status, output)), \
            mock.patch("scripts.native_app_process.ctypes.CDLL"):
        assert executable_process_ids(expected) is None


def test_unreadable_process_after_a_match_discards_partial_results(tmp_path):
    expected = tmp_path / "test-executable"
    expected.touch()

    def read_path(pid, buffer, _size):
        if pid == 101:
            buffer.value = str(expected).encode()
            return len(buffer.value)
        ctypes.set_errno(errno.EACCES)
        return 0

    query = mock.Mock(side_effect=read_path)
    library = mock.Mock(proc_pidpath=query)
    snapshot = subprocess.CompletedProcess([], 0, "101\n102\n")
    with mock.patch("scripts.native_app_process.subprocess.run", return_value=snapshot), \
            mock.patch("scripts.native_app_process.ctypes.CDLL", return_value=library):
        assert executable_process_ids(expected) is None
