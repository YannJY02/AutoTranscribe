"""Read native executable identity without inspecting process arguments."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import plistlib
import subprocess
from pathlib import Path
from xml.etree import ElementTree


def test_executable(derived_data: Path, scheme: Path) -> Path | None:
    try:
        configuration = ElementTree.parse(scheme).getroot().find("TestAction").get("buildConfiguration")
        if not configuration or Path(configuration).name != configuration:
            return None
        root = derived_data.expanduser().resolve()
        bundle = root / "Build" / "Products" / configuration / "InsightKitApp.app"
        info = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "com.yannjy.insightkit.uitesthost":
            return None
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or Path(name).name != name:
            return None
        executable = (bundle / "Contents" / "MacOS" / name).resolve()
        return executable if executable.is_file() and executable.is_relative_to(root) else None
    except (OSError, ValueError, RuntimeError, AttributeError, ElementTree.ParseError, plistlib.InvalidFileException):
        return None


def executable_process_ids(executable: Path) -> set[int] | None:
    """Return kernel-confirmed matches, or None when identity is unavailable."""
    try:
        expected = executable.expanduser().resolve()
        if not expected.is_file():
            return set()
        process = subprocess.run(
            ["ps", "-axo", "pid="], capture_output=True, text=True, check=False, timeout=5
        )
        if process.returncode or not process.stdout.strip():
            return None
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        query = library.proc_pidpath
        query.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        query.restype = ctypes.c_int
        matches: set[int] = set()
        for value in process.stdout.split():
            if not value.isdigit() or int(value) <= 0:
                return None
            pid = int(value)
            # PROC_PIDPATHINFO_MAXSIZE from the macOS SDK; no argv or environment.
            buffer = ctypes.create_string_buffer(4096)
            ctypes.set_errno(0)
            if query(pid, buffer, len(buffer)) <= 0:
                if ctypes.get_errno() in {errno.ENOENT, errno.ESRCH}:
                    # The process exited or has no executable vnode (e.g. kernel task).
                    continue
                return None
            path = Path(os.fsdecode(buffer.value))
            if not path.is_absolute():
                return None
            if path.resolve() == expected:
                matches.add(pid)
        return matches
    except (OSError, ValueError, RuntimeError, AttributeError, subprocess.TimeoutExpired):
        return None


def unique_process_id(executable: Path) -> int | None:
    matches = executable_process_ids(executable)
    return next(iter(matches)) if matches is not None and len(matches) == 1 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", required=True, type=Path)
    parser.add_argument("--scheme", required=True, type=Path)
    args = parser.parse_args()
    executable = test_executable(args.derived_data, args.scheme)
    pid = unique_process_id(executable) if executable is not None else None
    if pid is None:
        return 1
    print(pid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
