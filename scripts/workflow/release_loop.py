#!/usr/bin/env python3
"""Gap-driven autonomous release loop (P0 -> P1)."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from datetime import datetime, timezone
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from typing import Callable, Any

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.workflow.consensus import run_two_round_consensus, save_consensus_outputs
from scripts.workflow.gaps import (
    GapItem,
    current_phase,
    load_registry,
    mark_targets,
    save_registry,
    select_targets,
    unresolved_by_severity,
)
from scripts.workflow.skill_router import save_route_decision
from insightkit.compliance.scan_terms import scan_paths
from insightkit.insights.provider import RuleBasedProvider
from insightkit.insights.service import InsightService

MAX_ROUNDS_DEFAULT = 200
MAX_WALL_TIME_SEC_DEFAULT = 28800
MAX_FAIL_STREAK_DEFAULT = 3

OPS_STOP = ROOT / ".ops" / "STOP_AUTO_ITERATE"
WORKFLOW_DIR = ROOT / "logs" / "workflow"
ROUNDS_DIR = WORKFLOW_DIR / "rounds"
GAP_REGISTRY_PATH = WORKFLOW_DIR / "gap_registry.json"
ROUND_EVAL_PATH = WORKFLOW_DIR / "round_eval.json"
FINDINGS_PATH = WORKFLOW_DIR / "findings.json"
CONSENSUS_PATH = WORKFLOW_DIR / "consensus.json"
SKILL_ROUTE_PATH = WORKFLOW_DIR / "skill_route.json"
LATEST_SYNC_PATH = WORKFLOW_DIR / "latest_sync.json"
SYNC_STATUS_PATH = WORKFLOW_DIR / "sync_status.json"


@dataclass
class CmdResult:
    ok: bool
    exit_code: int
    duration_sec: float
    command: list[str]
    stdout_tail: str
    stderr_tail: str
    timed_out: bool = False
    stopped: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "exit_code": self.exit_code,
            "duration_sec": round(self.duration_sec, 3),
            "command": self.command,
            "stdout_tail": self.stdout_tail,
            "stderr_tail": self.stderr_tail,
            "timed_out": self.timed_out,
            "stopped": self.stopped,
        }


@dataclass
class GapRule:
    validator: Callable[[], tuple[bool, str]]
    files: list[str]
    remediation: list[list[str]]
    severity: str


def _read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def _contains(path: str, *patterns: str) -> bool:
    text = _read(path)
    return all(p in text for p in patterns)


def _check_p0_g1() -> tuple[bool, str]:
    ok = _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/Services/LiveASRService.swift",
        "insightkit_runtime/scripts/live_chunk_asr.py",
        "INSIGHTKIT_RUNTIME_ROOT",
    ) and _contains(
        "scripts/package_insightkit_app.sh",
        "insightkit_runtime",
        "cp -R \"$ROOT_DIR/scripts\" \"$runtime_root/\"",
        "cp -R \"$ROOT_DIR/insightkit\" \"$runtime_root/\"",
    )
    return ok, "finder launch path + bundled runtime asset check"


def _check_p0_g2() -> tuple[bool, str]:
    ok = _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/Services/SidecarManager.swift",
        "final class SidecarManager",
        "startIfNeeded()",
        "stop()",
    ) and _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift",
        "sidecarManager.startIfNeeded()",
        "sidecarManager.stop()",
    )
    return ok, "app-hosted sidecar lifecycle check"


def _check_p0_g3() -> tuple[bool, str]:
    ok = _contains(
        "insightkit/insights/provider.py",
        "def resolve_default_provider",
        "RuleBasedProvider",
        "OpenAICompatibleProvider",
    ) and _contains(
        "insightkit/insights/service.py",
        "resolve_default_provider()",
        "\"needs_review\": True",
    )
    return ok, "provider default + observable fallback check"


def _check_p0_g4() -> tuple[bool, str]:
    ok = _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/Services/InsightRPCClient.swift",
        "timeoutSec",
        "maxRetries",
        "breakerThreshold",
        "callWithRetry",
    ) and _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/Services/LiveASRService.swift",
        "processTimeout",
        "maxRetries",
    )
    return ok, "RPC + ASR timeout/retry/circuit-breaker check"


def _check_p1_g1() -> tuple[bool, str]:
    ok = _contains(
        "insightkit/ipc/server.py",
        "render_insight_markdown",
        "def _document_export",
        "insight.build_final",
    ) and _contains(
        "insightkit/insights/render.py",
        "## 会议信封",
        "## 全景纪要",
        "## 执行清单",
        "## 时间脉络",
        "## 溯源链接",
        "## 交互占位提示",
    )
    return ok, "document.export full module rendering check"


def _check_p1_g2() -> tuple[bool, str]:
    ok = _contains(
        "insightkit/integration/attentionos_bridge.py",
        "live.session.start",
        "live.session.stop",
        "live.session.status",
    ) and _contains(
        "insightkit/ipc/server.py",
        "\"live.session.start\"",
        "\"live.session.stop\"",
        "\"live.session.status\"",
    )
    return ok, "RSS bridge live session actions check"


def _check_p1_g3() -> tuple[bool, str]:
    ok = _contains(
        "insightkit/compliance/scan_terms.py",
        "--exclude",
        "self_file = Path(__file__).resolve()",
        "if resolved == self_file",
    )
    return ok, "compliance self-hit exclusion check"


def _check_p1_g4() -> tuple[bool, str]:
    ok = _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/ContentView.swift",
        "打开麦克风设置",
        "打开屏幕录制设置",
    ) and _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift",
        "openMicrophonePrivacySettings",
        "openScreenRecordingSettings",
    )
    return ok, "permission recovery guide chain check"


def _check_p1_g5() -> tuple[bool, str]:
    ok = _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/Services/ChunkAssembler.swift",
        "maxRetainedChunkFiles",
        "cleanupOverflowChunkFilesIfNeeded",
        "cleanupAllChunkFiles",
    ) and _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift",
        "chunkAssembler.reset()",
        "flush(minDurationSec: 1.0)",
    )
    return ok, "chunk lifecycle + resource cap check"


def _check_p1_g6() -> tuple[bool, str]:
    ok = _contains(
        "macos/InsightKitApp/Sources/InsightKitApp/InsightKitApp.swift",
        "CommandMenu(\"会话\")",
        "buildFinalInsight()",
        "startLiveSession()",
        "stopLiveSession()",
    )
    return ok, "menu commands bind to real actions check"


GAP_RULES: dict[str, GapRule] = {
    "P0-G1": GapRule(
        validator=_check_p0_g1,
        files=[
            "macos/InsightKitApp/Sources/InsightKitApp/Services/LiveASRService.swift",
            "scripts/package_insightkit_app.sh",
        ],
        remediation=[["bash", "scripts/package_insightkit_app.sh", "--debug", "--clean"]],
        severity="P0",
    ),
    "P0-G2": GapRule(
        validator=_check_p0_g2,
        files=[
            "macos/InsightKitApp/Sources/InsightKitApp/Services/InsightRPCClient.swift",
            "macos/InsightKitApp/Sources/InsightKitApp/Services/SidecarManager.swift",
            "macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift",
        ],
        remediation=[],
        severity="P0",
    ),
    "P0-G3": GapRule(
        validator=_check_p0_g3,
        files=[
            "insightkit/insights/provider.py",
            "insightkit/insights/service.py",
        ],
        remediation=[],
        severity="P0",
    ),
    "P0-G4": GapRule(
        validator=_check_p0_g4,
        files=[
            "macos/InsightKitApp/Sources/InsightKitApp/Services/InsightRPCClient.swift",
            "macos/InsightKitApp/Sources/InsightKitApp/Services/LiveASRService.swift",
        ],
        remediation=[],
        severity="P0",
    ),
    "P1-G1": GapRule(
        validator=_check_p1_g1,
        files=[
            "insightkit/ipc/server.py",
            "insightkit/insights/render.py",
        ],
        remediation=[],
        severity="P1",
    ),
    "P1-G2": GapRule(
        validator=_check_p1_g2,
        files=[
            "insightkit/integration/attentionos_bridge.py",
            "insightkit/ipc/server.py",
        ],
        remediation=[],
        severity="P1",
    ),
    "P1-G3": GapRule(
        validator=_check_p1_g3,
        files=["insightkit/compliance/scan_terms.py"],
        remediation=[],
        severity="P1",
    ),
    "P1-G4": GapRule(
        validator=_check_p1_g4,
        files=[
            "macos/InsightKitApp/Sources/InsightKitApp/ContentView.swift",
            "macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift",
        ],
        remediation=[],
        severity="P1",
    ),
    "P1-G5": GapRule(
        validator=_check_p1_g5,
        files=[
            "macos/InsightKitApp/Sources/InsightKitApp/Services/ChunkAssembler.swift",
            "macos/InsightKitApp/Sources/InsightKitApp/ViewModels/LiveSessionViewModel.swift",
        ],
        remediation=[],
        severity="P1",
    ),
    "P1-G6": GapRule(
        validator=_check_p1_g6,
        files=["macos/InsightKitApp/Sources/InsightKitApp/InsightKitApp.swift"],
        remediation=[],
        severity="P1",
    ),
}


def _core_unresolved(unresolved: dict[str, int]) -> int:
    return int(unresolved.get("P0", 0)) + int(unresolved.get("P1", 0))


def _run_cmd(cmd: list[str], timeout_sec: int = 1800) -> CmdResult:
    t0 = time.time()
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        dt = time.time() - t0
        return CmdResult(
            ok=False,
            exit_code=127,
            duration_sec=dt,
            command=cmd,
            stdout_tail="",
            stderr_tail=str(exc),
        )
    except Exception as exc:
        dt = time.time() - t0
        return CmdResult(
            ok=False,
            exit_code=1,
            duration_sec=dt,
            command=cmd,
            stdout_tail="",
            stderr_tail=str(exc),
        )

    deadline = t0 + timeout_sec
    while True:
        try:
            remaining = max(0.1, min(0.5, deadline - time.time()))
            stdout, stderr = proc.communicate(timeout=remaining)
            dt = time.time() - t0
            return CmdResult(
                ok=proc.returncode == 0,
                exit_code=proc.returncode,
                duration_sec=dt,
                command=cmd,
                stdout_tail=(stdout or "")[-2000:],
                stderr_tail=(stderr or "")[-2000:],
            )
        except subprocess.TimeoutExpired:
            if _should_stop():
                proc.terminate()
                try:
                    stdout, stderr = proc.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    stdout, stderr = proc.communicate()
                dt = time.time() - t0
                return CmdResult(
                    ok=False,
                    exit_code=130,
                    duration_sec=dt,
                    command=cmd,
                    stdout_tail=(stdout or "")[-2000:],
                    stderr_tail="stopped by stop marker",
                    stopped=True,
                )
            if time.time() >= deadline:
                proc.terminate()
                try:
                    stdout, stderr = proc.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    stdout, stderr = proc.communicate()
                dt = time.time() - t0
                return CmdResult(
                    ok=False,
                    exit_code=124,
                    duration_sec=dt,
                    command=cmd,
                    stdout_tail=(stdout or "")[-2000:],
                    stderr_tail=f"timeout after {timeout_sec}s",
                    timed_out=True,
                )
            continue
        except Exception as exc:
            proc.kill()
            dt = time.time() - t0
            return CmdResult(
                ok=False,
                exit_code=1,
                duration_sec=dt,
                command=cmd,
                stdout_tail="",
                stderr_tail=str(exc),
            )


def _has_stopped_gate(gates: dict[str, Any]) -> bool:
    for key in ("swift_test", "python_test", "package_smoke", "runtime_smoke", "compliance_scan"):
        payload = gates.get(key, {})
        if payload.get("stopped", False):
            return True
    return False


def _gate_swift_test() -> dict[str, Any]:
    result = _run_cmd(["swift", "test", "--package-path", "macos/InsightKitApp"], timeout_sec=2400)
    return result.to_dict()


def _gate_python_test() -> dict[str, Any]:
    result = _run_cmd(["python3", "-m", "unittest", "discover", "-s", "tests", "-v"], timeout_sec=2400)
    return result.to_dict()


def _gate_package_smoke() -> dict[str, Any]:
    result = _run_cmd(
        [
            "bash",
            "scripts/package_insightkit_app.sh",
            "--debug",
            "--clean",
            "--install-dir",
            str(Path.home() / "Applications"),
        ],
        timeout_sec=2400,
    )
    app_path = ROOT / "dist" / "macos" / "InsightKit.app"
    required = [
        app_path / "Contents" / "MacOS" / "InsightKitApp",
        app_path / "Contents" / "Resources" / "insightkit_runtime" / "scripts" / "insight_sidecar.py",
        app_path / "Contents" / "Resources" / "insightkit_runtime" / "scripts" / "live_chunk_asr.py",
        app_path / "Contents" / "Resources" / "insightkit_runtime" / "insightkit" / "ipc" / "server.py",
    ]
    missing = [str(p) for p in required if not p.exists()]
    payload = result.to_dict()
    payload["missing_paths"] = missing
    payload["ok"] = payload["ok"] and not missing
    return payload


def _rpc_unix_call(socket_path: Path, method: str, params: dict[str, Any], req_id: int) -> tuple[bool, dict[str, Any], str]:
    req = {
        "jsonrpc": "2.0",
        "id": req_id,
        "method": method,
        "params": params,
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(str(socket_path))
            payload = json.dumps(req).encode("utf-8")
            client.sendall(payload)
            client.shutdown(socket.SHUT_WR)
            chunks: list[bytes] = []
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
        data = b"".join(chunks).decode("utf-8")
        root = json.loads(data or "{}")
        if "error" in root:
            err = root["error"].get("message", "rpc_error")
            return False, {}, str(err)
        return True, root.get("result", {}), ""
    except Exception as exc:
        return False, {}, str(exc)


def _gate_runtime_smoke() -> dict[str, Any]:
    t0 = time.time()
    with tempfile.TemporaryDirectory(prefix="insightkit-smoke-") as tmp:
        socket_path = Path(tmp) / "insightkit.sock"
        env_full = dict(os.environ)
        env_full.update(
            {
                "PYTHONUNBUFFERED": "1",
                "INSIGHTKIT_SOCKET": str(socket_path),
                "INSIGHTKIT_RUNTIME_ROOT": str(ROOT),
                "PYTHONPATH": str(ROOT),
            }
        )

        proc = subprocess.Popen(
            [sys.executable, "scripts/insight_sidecar.py"],
            cwd=ROOT,
            env=env_full,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.time() + 8
            while time.time() < deadline and not socket_path.exists():
                if proc.poll() is not None:
                    break
                time.sleep(0.1)

            if proc.poll() is not None:
                stderr = (proc.stderr.read() if proc.stderr else "")[-2000:]
                return {
                    "ok": False,
                    "exit_code": proc.returncode,
                    "duration_sec": round(time.time() - t0, 3),
                    "stderr_tail": stderr,
                    "steps": [],
                }

            steps: list[dict[str, Any]] = []
            req_id = 1

            def _step(method: str, params: dict[str, Any], expect_key: str = "") -> bool:
                nonlocal req_id
                ok, result, err = _rpc_unix_call(socket_path, method, params, req_id)
                req_id += 1
                row = {"method": method, "ok": ok, "error": err, "result": result}
                if ok and expect_key:
                    row["ok"] = expect_key in result
                steps.append(row)
                return bool(row["ok"])

            sid = f"smoke-{int(time.time())}"
            ok = True
            ok = _step("sidecar.ensure_ready", {"timeout_sec": 4}, "ready") and ok
            ok = _step("session.start", {"meeting_id": sid, "title": "smoke", "source": "mixed"}, "meeting_id") and ok
            ok = _step(
                "transcript.delta",
                {
                    "meeting_id": sid,
                    "segments": [
                        {
                            "start_ms": 0,
                            "end_ms": 1000,
                            "speaker": "spk0",
                            "source": "mixed",
                            "text": "runtime smoke segment",
                            "confidence": 0.9,
                        }
                    ],
                },
                "ingested",
            ) and ok
            ok = _step("insight.refresh_live", {"meeting_id": sid, "window_sec": 120}, "insight_package") and ok
            ok = _step("sidecar.status", {}, "running") and ok
            ok = _step("session.stop", {"meeting_id": sid}, "status") and ok

            return {
                "ok": ok,
                "exit_code": 0 if ok else 1,
                "duration_sec": round(time.time() - t0, 3),
                "steps": steps,
            }
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)


def _gate_compliance_scan() -> dict[str, Any]:
    allowed = {".py", ".swift", ".md", ".sh", ".txt", ".json", ".toml"}
    scan_roots = [
        ROOT / "insightkit",
        ROOT / "macos" / "InsightKitApp" / "Sources",
        ROOT / "scripts",
    ]
    skip_parts = {
        ".git",
        ".build",
        "dist",
        "logs",
        "__pycache__",
        ".pytest_cache",
        ".ops",
        "tests",
        "docs",
    }

    files: list[Path] = []
    for root in scan_roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if _should_stop():
                return {"ok": False, "stopped": True, "finding_count": 0, "findings": {}}
            if not path.is_file():
                continue
            if path.suffix.lower() not in allowed:
                continue
            if any(part in skip_parts for part in path.parts):
                continue
            files.append(path)

    findings = scan_paths(
        files,
        exclude_patterns=[
            "*insightkit/compliance/scan_terms.py",
        ],
    )
    return {
        "ok": len(findings) == 0,
        "stopped": False,
        "finding_count": len(findings),
        "findings": findings,
    }


def _fallback_review_count() -> int:
    service = InsightService(provider=RuleBasedProvider())
    payload = service.build_live([])
    count = 0
    for item in payload.get("decision_ledger", []):
        if item.get("needs_review") is True:
            count += 1
    for item in payload.get("action_tracks", []):
        if item.get("needs_review") is True:
            count += 1
    return count


def _run_gates() -> dict[str, Any]:
    gates = {
        "swift_test": _gate_swift_test(),
        "python_test": _gate_python_test(),
        "package_smoke": _gate_package_smoke(),
        "runtime_smoke": _gate_runtime_smoke(),
        "compliance_scan": _gate_compliance_scan(),
    }
    gates["fallback_review_items"] = _fallback_review_count()
    gates["performance"] = {
        "swift_test_sec": gates["swift_test"]["duration_sec"],
        "python_test_sec": gates["python_test"]["duration_sec"],
        "package_smoke_sec": gates["package_smoke"]["duration_sec"],
        "runtime_smoke_sec": gates["runtime_smoke"]["duration_sec"],
    }
    return gates


def _all_core_gates_ok(gates: dict[str, Any]) -> bool:
    for key in ("swift_test", "python_test", "package_smoke", "runtime_smoke", "compliance_scan"):
        if not gates.get(key, {}).get("ok", False):
            return False
    return True


def _detect_regressions(items: list[GapItem]) -> int:
    regressions = 0
    for item in items:
        if item.status != "resolved":
            continue
        rule = GAP_RULES.get(item.gap_id)
        if not rule:
            continue
        ok, note = rule.validator()
        if not ok:
            item.status = "reopened"
            item.notes = f"regression: {note}"
            regressions += 1
    return regressions


def _resolve_targets(targets: list[GapItem]) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for target in targets:
        rule = GAP_RULES.get(target.gap_id)
        if not rule:
            target.status = "blocked"
            target.notes = "missing gap rule"
            results.append(
                {
                    "gap_id": target.gap_id,
                    "severity": target.severity,
                    "status": target.status,
                    "notes": target.notes,
                    "files": [],
                }
            )
            continue

        ok, note = rule.validator()
        remediation_logs: list[dict[str, Any]] = []
        if not ok and rule.remediation:
            for cmd in rule.remediation:
                cmd_result = _run_cmd(cmd, timeout_sec=2400)
                remediation_logs.append(cmd_result.to_dict())
            ok, note = rule.validator()

        if ok:
            target.status = "resolved"
            target.notes = f"validated: {note}"
        else:
            target.status = "blocked"
            target.notes = f"unresolved: {note}"

        results.append(
            {
                "gap_id": target.gap_id,
                "severity": target.severity,
                "status": target.status,
                "notes": target.notes,
                "files": rule.files,
                "remediation": remediation_logs,
            }
        )
    return results


def _changed_files() -> tuple[bool, set[str]]:
    changed: set[str] = set()
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=60,
            check=False,
        )
    except Exception:
        return False, changed
    if result.returncode != 0:
        return False, changed
    for line in (result.stdout or "").splitlines():
        if len(line) < 4:
            continue
        changed.add(line[3:].strip())
    return True, changed


def _staged_files() -> tuple[bool, set[str]]:
    staged: set[str] = set()
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "--cached"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=60,
            check=False,
        )
    except Exception:
        return False, staged
    if result.returncode != 0:
        return False, staged
    for line in (result.stdout or "").splitlines():
        value = line.strip()
        if value:
            staged.add(value)
    return True, staged


def _maybe_group_commit(
    target_results: list[dict[str, Any]],
    auto_commit: bool,
    round_ok: bool,
) -> dict[str, Any]:
    if not auto_commit:
        return {"enabled": False, "commits": []}

    if not round_ok:
        return {"enabled": True, "commits": [], "skipped": True, "reason": "round not passed"}

    staged_ok, pre_staged = _staged_files()
    if not staged_ok:
        return {
            "enabled": True,
            "commits": [],
            "skipped": True,
            "reason": "unable to inspect staged files; fail-closed skip",
        }
    if pre_staged:
        return {
            "enabled": True,
            "commits": [],
            "skipped": True,
            "reason": "existing staged changes detected; refusing unsafe auto-commit",
            "staged_files": sorted(pre_staged),
        }

    changed_ok, changed = _changed_files()
    if not changed_ok:
        return {
            "enabled": True,
            "commits": [],
            "skipped": True,
            "reason": "unable to inspect working tree changes; fail-closed skip",
        }
    if not changed:
        return {"enabled": True, "commits": [], "note": "no changed files"}

    bug_files: set[str] = set()
    feature_files: set[str] = set()
    for item in target_results:
        candidate_files = {f for f in item.get("files", []) if f in changed}
        if item.get("severity") == "P0":
            bug_files.update(candidate_files)
        else:
            feature_files.update(candidate_files)

    commits: list[dict[str, Any]] = []

    def _commit(files: set[str], msg: str) -> None:
        if not files:
            return
        sorted_files = sorted(files)
        add_result = _run_cmd(["git", "add", "--", *sorted_files], timeout_sec=60)
        if not add_result.ok:
            commits.append(
                {
                    "message": msg,
                    "files": sorted_files,
                    "ok": False,
                    "exit_code": add_result.exit_code,
                    "error": "git add failed",
                }
            )
            return

        res = _run_cmd(["git", "commit", "-m", msg], timeout_sec=120)
        commits.append(
            {
                "message": msg,
                "files": sorted_files,
                "ok": res.ok,
                "exit_code": res.exit_code,
            }
        )

    _commit(bug_files, "fix(insightkit): close P0 runtime gaps")
    _commit(feature_files, "feat(insightkit): close P1 integration gaps")
    return {"enabled": True, "commits": commits}


def _save_round_artifact(round_id: int, payload: dict[str, Any]) -> None:
    ROUNDS_DIR.mkdir(parents=True, exist_ok=True)
    path = ROUNDS_DIR / f"round_{round_id:03d}.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    ROUND_EVAL_PATH.parent.mkdir(parents=True, exist_ok=True)
    ROUND_EVAL_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def _safe_save_round_artifact(round_id: int, payload: dict[str, Any]) -> None:
    try:
        _save_round_artifact(round_id, payload)
    except Exception:
        pass


def _save_sync_status(payload: dict[str, Any]) -> None:
    try:
        WORKFLOW_DIR.mkdir(parents=True, exist_ok=True)
        SYNC_STATUS_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        if payload.get("ok") is True and payload.get("status") == "success":
            LATEST_SYNC_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception:
        pass


def _load_json(path: Path) -> dict[str, Any]:
    try:
        if not path.exists():
            return {}
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save_round_consensus_history(
    round_id: int,
    findings: list[dict[str, Any]],
    consensus: dict[str, Any],
) -> None:
    ROUNDS_DIR.mkdir(parents=True, exist_ok=True)
    (ROUNDS_DIR / f"round_{round_id:03d}_findings.json").write_text(
        json.dumps(findings, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (ROUNDS_DIR / f"round_{round_id:03d}_consensus.json").write_text(
        json.dumps(consensus, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def _should_stop() -> bool:
    return OPS_STOP.exists()


def _round_two_executed(findings: list[dict[str, Any]], consensus: dict[str, Any]) -> bool:
    if int(consensus.get("review_rounds", 0)) < 2:
        return False
    reviewers = {str(x) for x in consensus.get("reviewers", []) if str(x)}
    if not reviewers:
        return False
    by_round: dict[int, set[str]] = {1: set(), 2: set()}
    evidence_ok = True
    for item in findings:
        review_round = int(item.get("review_round", 0))
        reviewer = str(item.get("reviewer", ""))
        title = str(item.get("title", "")).strip()
        detail = str(item.get("detail", "")).strip()
        evidence = str(item.get("evidence", "")).strip()
        if review_round in by_round and reviewer:
            by_round[review_round].add(reviewer)
            if not title or not detail or not evidence:
                evidence_ok = False
    return evidence_ok and reviewers.issubset(by_round[1]) and reviewers.issubset(by_round[2])


def run_loop(
    max_rounds: int,
    max_wall_time_sec: int,
    max_fail_streak: int,
    auto_commit: bool,
    auto_package: bool,
    install_dir: str,
    package_debug: bool,
    skip_sync_verify: bool,
) -> int:
    t0 = time.time()
    fail_streak = 0
    try:
        WORKFLOW_DIR.mkdir(parents=True, exist_ok=True)
        items = load_registry(GAP_REGISTRY_PATH)
        save_registry(GAP_REGISTRY_PATH, items)
    except Exception as exc:
        boot_eval = {
            "round": 0,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "round_ok": False,
            "error": f"bootstrap failure: {exc}",
            "fail_streak": 1,
        }
        try:
            _safe_save_round_artifact(0, boot_eval)
        except Exception:
            pass
        print("[loop] bootstrap failure")
        return 3

    for round_id in range(1, max_rounds + 1):
        if _should_stop():
            print(f"[loop] stop marker found: {OPS_STOP}")
            return 5

        if time.time() - t0 >= max_wall_time_sec:
            print("[loop] max wall time reached")
            return 2

        active_target_ids: set[str] = set()
        try:
            regressions = _detect_regressions(items)
            if regressions:
                save_registry(GAP_REGISTRY_PATH, items)

            phase = current_phase(items)
            unresolved_before = unresolved_by_severity(items)
            if int(unresolved_before.get("P0", 0)) > 0 and phase != "P0":
                raise RuntimeError("phase violation: unresolved P0 exists but phase is not P0")

            targets = select_targets(items, phase)
            final_only = (not targets) and (_core_unresolved(unresolved_before) == 0)
            if (not targets) and (not final_only):
                fail_streak += 1
                round_eval = {
                    "round": round_id,
                    "generated_at": datetime.now(timezone.utc).isoformat(),
                    "phase": phase,
                    "targets": [],
                    "round_ok": False,
                    "error": "no selectable targets while unresolved gaps remain",
                    "remaining_unresolved": unresolved_before,
                    "fail_streak": fail_streak,
                }
                _safe_save_round_artifact(round_id, round_eval)
                if fail_streak >= max_fail_streak:
                    print(f"[loop] fail streak reached {fail_streak}, aborting")
                    return 3
                continue

            target_ids = {x.gap_id for x in targets}
            route = save_route_decision(SKILL_ROUTE_PATH, round_id, phase, sorted(target_ids))

            if final_only:
                target_results: list[dict[str, Any]] = []
            else:
                active_target_ids = set(target_ids)
                mark_targets(items, active_target_ids, "in_progress")
                save_registry(GAP_REGISTRY_PATH, items)

                try:
                    target_results = _resolve_targets(targets)
                except Exception as resolve_error:
                    for item in items:
                        if item.gap_id in active_target_ids:
                            item.status = "reopened"
                            item.notes = f"reopened: resolve error {resolve_error}"
                    save_registry(GAP_REGISTRY_PATH, items)
                    raise
                save_registry(GAP_REGISTRY_PATH, items)

            gates = _run_gates()
            unresolved_after = unresolved_by_severity(items)
            findings, consensus = run_two_round_consensus(
                round_id=round_id,
                gates=gates,
                target_results=target_results,
                unresolved_after=unresolved_after,
            )
            save_consensus_outputs(FINDINGS_PATH, CONSENSUS_PATH, findings, consensus)
            _save_round_consensus_history(round_id, findings, consensus)

            round_two_ok = _round_two_executed(findings, consensus)
            stop_triggered = _should_stop() or _has_stopped_gate(gates)
            core_gates_ok = _all_core_gates_ok(gates)
            round_ok = (
                not stop_triggered
                and
                core_gates_ok
                and round_two_ok
                and not consensus.get("blocking_in_round_2", True)
                and all(x.get("status") == "resolved" for x in target_results)
            )

            sync_payload: dict[str, Any] = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "enabled": auto_package,
                "status": "pending",
                "ok": False,
                "install_dir": install_dir,
                "package_debug": package_debug,
                "skip_sync_verify": skip_sync_verify,
                "skipped_due_to_gate_failure": False,
                "reason": "",
            }
            if not core_gates_ok:
                sync_payload.update(
                    {
                        "status": "skipped",
                        "ok": False,
                        "skipped_due_to_gate_failure": True,
                        "reason": "core gate failure",
                    }
                )

            if not round_ok and active_target_ids:
                for item in items:
                    if item.gap_id in active_target_ids:
                        item.status = "reopened"
                        item.notes = "reopened: round not approved, awaiting retry"
                save_registry(GAP_REGISTRY_PATH, items)
                unresolved_after = unresolved_by_severity(items)

            commit_info = _maybe_group_commit(
                target_results,
                auto_commit=auto_commit,
                round_ok=round_ok,
            )

            next_phase = current_phase(items)
            next_candidates = [x.gap_id for x in select_targets(items, next_phase)]
            fail_streak = 0 if round_ok else (fail_streak + 1)

            round_eval = {
                "round": round_id,
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "phase": phase,
                "targets": sorted(target_ids),
                "final_only": final_only,
                "skill_route": route,
                "target_results": target_results,
                "gates": gates,
                "consensus": consensus,
                "commit": commit_info,
                "stop_triggered": stop_triggered,
                "round_ok": round_ok,
                "remaining_unresolved": unresolved_after,
                "next_candidates": next_candidates,
                "fail_streak": fail_streak,
                "sync": sync_payload,
            }
            _safe_save_round_artifact(round_id, round_eval)

            print(
                f"[loop] round={round_id} phase={phase} "
                f"targets={sorted(target_ids)} ok={round_ok} remaining={unresolved_after}"
            )

            if not core_gates_ok:
                _save_sync_status(sync_payload)
                print("[loop] core gate failure; auto sync skipped (fail-closed)")
                return 3

            if fail_streak >= max_fail_streak:
                print(f"[loop] fail streak reached {fail_streak}, aborting")
                return 3

            if stop_triggered:
                print("[loop] stop marker triggered during round")
                return 5

            if _core_unresolved(unresolved_after) == 0 and round_ok:
                if auto_package:
                    sync_cmd = ["bash", "scripts/sync_insightkit_app.sh", "--skip-tests", "--install-dir", install_dir]
                    if package_debug:
                        sync_cmd.append("--debug")
                    if skip_sync_verify:
                        sync_cmd.append("--skip-verify")
                    sync_result = _run_cmd(sync_cmd, timeout_sec=3600)
                    latest_sync = _load_json(LATEST_SYNC_PATH)
                    sync_payload.update(
                        {
                            "status": "success" if sync_result.ok else "failed",
                            "ok": sync_result.ok,
                            "reason": "sync completed" if sync_result.ok else "sync command failed",
                            "command": sync_cmd,
                            "result": sync_result.to_dict(),
                            "latest_sync": latest_sync,
                        }
                    )
                    _save_sync_status(sync_payload)
                    round_eval["sync"] = sync_payload
                    _safe_save_round_artifact(round_id, round_eval)
                    if not sync_result.ok:
                        print("[loop] sync failed after successful round")
                        return 3
                else:
                    sync_payload.update(
                        {
                            "status": "disabled",
                            "ok": True,
                            "reason": "auto-package disabled by flag",
                        }
                    )
                    _save_sync_status(sync_payload)
                    round_eval["sync"] = sync_payload
                    _safe_save_round_artifact(round_id, round_eval)
                print("[loop] gap registry cleared")
                return 0
        except Exception as exc:
            if active_target_ids:
                for item in items:
                    if item.gap_id in active_target_ids:
                        item.status = "reopened"
                        item.notes = f"reopened: round exception {exc}"
                try:
                    save_registry(GAP_REGISTRY_PATH, items)
                except Exception:
                    pass
            fail_streak += 1
            round_eval = {
                "round": round_id,
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "round_ok": False,
                "error": str(exc),
                "fail_streak": fail_streak,
            }
            _safe_save_round_artifact(round_id, round_eval)
            if fail_streak >= max_fail_streak:
                print(f"[loop] fail streak reached {fail_streak}, aborting")
                return 3

    print("[loop] max rounds reached")
    return 4


def main() -> int:
    parser = argparse.ArgumentParser(description="Run InsightKit gap-driven autonomous loop")
    parser.add_argument("--max-rounds", type=int, default=MAX_ROUNDS_DEFAULT)
    parser.add_argument("--max-wall-time-sec", type=int, default=MAX_WALL_TIME_SEC_DEFAULT)
    parser.add_argument("--max-fail-streak", type=int, default=MAX_FAIL_STREAK_DEFAULT)
    parser.add_argument(
        "--auto-commit",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Enable grouped local commits (no push). Default: disabled.",
    )
    parser.add_argument(
        "--auto-package",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Auto package + install after a successful round with zero unresolved P0/P1 gaps. Default: enabled.",
    )
    parser.add_argument(
        "--install-dir",
        type=str,
        default=str(Path.home() / "Applications"),
        help="Install directory for auto sync package.",
    )
    parser.add_argument(
        "--package-debug",
        action="store_true",
        help="Use debug package mode during auto sync.",
    )
    parser.add_argument(
        "--skip-sync-verify",
        action="store_true",
        help="Skip post-install verification in sync step.",
    )
    args = parser.parse_args()

    return run_loop(
        max_rounds=max(1, args.max_rounds),
        max_wall_time_sec=max(60, args.max_wall_time_sec),
        max_fail_streak=max(1, args.max_fail_streak),
        auto_commit=bool(args.auto_commit),
        auto_package=bool(args.auto_package),
        install_dir=str(args.install_dir),
        package_debug=bool(args.package_debug),
        skip_sync_verify=bool(args.skip_sync_verify),
    )


if __name__ == "__main__":
    raise SystemExit(main())
