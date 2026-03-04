#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package_insightkit_app.sh"

INSTALL_DIR="${INSIGHTKIT_INSTALL_DIR:-$HOME/Applications}"
RUN_TESTS=1
VERIFY_SYNC=1
CONFIG_FLAG=""
VERSION_ARG=""
CLEAN_FLAG="--clean"

WORKFLOW_DIR="$ROOT_DIR/logs/workflow"
LATEST_SYNC_PATH="$WORKFLOW_DIR/latest_sync.json"
SYNC_STATUS_PATH="$WORKFLOW_DIR/sync_status.json"

LAST_STEP="bootstrap"
STATUS_WRITTEN=0
FINAL_REASON=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --debug                      Build debug bundle
  --install-dir <path>         Install directory (default: \$HOME/Applications)
  --skip-tests                 Skip swift/python test checks
  --skip-verify                Skip post-install verification
  --version <semver>           App version string
  --no-clean                   Disable pre-build clean (default is clean)
  --clean                      Force pre-build clean
  -h, --help                   Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIG_FLAG="--debug"
      shift
      ;;
    --install-dir)
      INSTALL_DIR="${2:-}"
      shift 2
      ;;
    --skip-tests)
      RUN_TESTS=0
      shift
      ;;
    --skip-verify)
      VERIFY_SYNC=0
      shift
      ;;
    --version)
      VERSION_ARG="--version ${2:-}"
      shift 2
      ;;
    --no-clean)
      CLEAN_FLAG="--no-clean"
      shift
      ;;
    --clean)
      CLEAN_FLAG="--clean"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

write_sync_payload() {
  local status="$1"
  local reason="$2"
  local exit_code="$3"
  local skipped_gate="${4:-0}"

  mkdir -p "$WORKFLOW_DIR"

  ROOT_DIR="$ROOT_DIR" \
  INSTALL_DIR="$INSTALL_DIR" \
  STATUS="$status" \
  REASON="$reason" \
  EXIT_CODE="$exit_code" \
  SKIPPED_GATE="$skipped_gate" \
  VERIFY_SYNC="$VERIFY_SYNC" \
  LATEST_SYNC_PATH="$LATEST_SYNC_PATH" \
  SYNC_STATUS_PATH="$SYNC_STATUS_PATH" \
  python3 - <<'PY'
import json
import os
import plistlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
install_dir = Path(os.environ["INSTALL_DIR"])
status = os.environ["STATUS"]
reason = os.environ["REASON"]
exit_code = int(os.environ["EXIT_CODE"])
skipped_gate = os.environ.get("SKIPPED_GATE", "0") == "1"
verify_sync = os.environ.get("VERIFY_SYNC", "1") == "1"
latest_sync_path = Path(os.environ["LATEST_SYNC_PATH"])
sync_status_path = Path(os.environ["SYNC_STATUS_PATH"])

app_path = install_dir / "InsightKit.app"
plist_path = app_path / "Contents" / "Info.plist"
server_path = app_path / "Contents" / "Resources" / "insightkit_runtime" / "insightkit" / "ipc" / "server.py"

def run(cmd):
    p = subprocess.run(cmd, cwd=root, text=True, capture_output=True, check=False)
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()

code, out, _ = run(["git", "rev-parse", "--short", "HEAD"])
local_git_revision = out if code == 0 else "unknown"

dirty = False
code1, _, _ = run(["git", "diff", "--quiet", "--ignore-submodules", "HEAD", "--"])
code2, _, _ = run(["git", "diff", "--cached", "--quiet", "--ignore-submodules", "--"])
if code1 != 0 or code2 != 0:
    dirty = True

bundle = {
    "short_version": "",
    "build_version": "",
    "git_revision": "",
    "build_source": "",
}

if plist_path.exists():
    with plist_path.open("rb") as f:
        info = plistlib.load(f)
    bundle["short_version"] = str(info.get("CFBundleShortVersionString", ""))
    bundle["build_version"] = str(info.get("CFBundleVersion", ""))
    bundle["git_revision"] = str(info.get("InsightKitGitRevision", ""))
    bundle["build_source"] = str(info.get("InsightKitBuildSource", ""))

required_caps = [
    "transcription.status",
    "asr.runtime.status",
    "asr.runtime.bootstrap",
    "diagnostics.quick_check",
]
cap_snapshot = {cap: False for cap in required_caps}
if server_path.exists():
    text = server_path.read_text(encoding="utf-8")
    for cap in required_caps:
        cap_snapshot[cap] = f"\"{cap}\"" in text

verify = {
    "enabled": verify_sync,
    "installed_exists": app_path.exists(),
    "git_revision_match": False,
    "required_capabilities": cap_snapshot,
}
if verify_sync:
    verify["git_revision_match"] = bool(bundle["git_revision"]) and bundle["git_revision"] == local_git_revision

ok = status == "success"
if verify_sync and ok:
    ok = (
        verify["installed_exists"]
        and verify["git_revision_match"]
        and all(cap_snapshot.values())
    )

payload = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "status": status if ok or status != "success" else "failed",
    "ok": ok,
    "reason": reason if reason else ("sync complete" if ok else "verification failed"),
    "exit_code": exit_code,
    "skipped_due_to_gate_failure": skipped_gate,
    "install_path": str(app_path),
    "workspace_root": str(root),
    "local_git_revision": local_git_revision,
    "local_git_dirty": dirty,
    "bundle": bundle,
    "verify": verify,
}

sync_status_path.parent.mkdir(parents=True, exist_ok=True)
sync_status_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
if payload["ok"] and payload["status"] == "success":
    latest_sync_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
PY
}

on_exit() {
  local exit_code="$1"
  if [[ "$STATUS_WRITTEN" -eq 0 ]]; then
    if [[ "$exit_code" -eq 0 ]]; then
      write_sync_payload "success" "${FINAL_REASON:-sync complete}" 0 0 || true
      STATUS_WRITTEN=1
    else
      write_sync_payload "failed" "${FINAL_REASON:-failed at step: $LAST_STEP}" "$exit_code" 0 || true
      STATUS_WRITTEN=1
    fi
  fi
  return "$exit_code"
}
trap 'on_exit $?' EXIT

check_app_running() {
  if pgrep -x "InsightKitApp" >/dev/null 2>&1; then
    FINAL_REASON="InsightKit 正在运行，请先退出应用后再同步。"
    echo "$FINAL_REASON" >&2
    return 1
  fi
}

verify_install() {
  local app_path="$INSTALL_DIR/InsightKit.app"
  local plist_path="$app_path/Contents/Info.plist"
  local runtime_server="$app_path/Contents/Resources/insightkit_runtime/insightkit/ipc/server.py"
  local local_rev bundled_rev

  if [[ ! -d "$app_path" ]]; then
    FINAL_REASON="安装校验失败：未找到 $app_path"
    echo "$FINAL_REASON" >&2
    return 1
  fi

  local_rev="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  bundled_rev="$(/usr/libexec/PlistBuddy -c "Print :InsightKitGitRevision" "$plist_path" 2>/dev/null || true)"
  if [[ -z "$bundled_rev" || "$bundled_rev" != "$local_rev" ]]; then
    FINAL_REASON="安装校验失败：bundle revision($bundled_rev) 与本地 revision($local_rev) 不一致"
    echo "$FINAL_REASON" >&2
    return 1
  fi

  if [[ ! -f "$runtime_server" ]]; then
    FINAL_REASON="安装校验失败：缺少 runtime server 文件"
    echo "$FINAL_REASON" >&2
    return 1
  fi

  local required_caps=(
    "\"transcription.status\""
    "\"asr.runtime.status\""
    "\"asr.runtime.bootstrap\""
    "\"diagnostics.quick_check\""
  )
  local cap
  for cap in "${required_caps[@]}"; do
    if ! /usr/bin/grep -q "$cap" "$runtime_server"; then
      FINAL_REASON="安装校验失败：缺少 capability $cap"
      echo "$FINAL_REASON" >&2
      return 1
    fi
  done

  FINAL_REASON="sync complete"
}

LAST_STEP="preflight_running_check"
check_app_running

if [[ $RUN_TESTS -eq 1 ]]; then
  LAST_STEP="swift_test"
  FINAL_REASON="swift test failed"
  swift test --package-path "$ROOT_DIR/macos/InsightKitApp"

  LAST_STEP="python_unittest"
  FINAL_REASON="python unittest failed"
  python3 -m unittest discover -s "$ROOT_DIR/tests" -v
fi

LAST_STEP="package_install"
FINAL_REASON="package/install failed"
# shellcheck disable=SC2086
"$PACKAGE_SCRIPT" $CONFIG_FLAG $CLEAN_FLAG --install-dir "$INSTALL_DIR" $VERSION_ARG

if [[ $VERIFY_SYNC -eq 1 ]]; then
  LAST_STEP="verify_install"
  FINAL_REASON="install verification failed"
  verify_install
else
  FINAL_REASON="sync complete (verification skipped)"
fi

echo "Synced app: $INSTALL_DIR/InsightKit.app"
echo "Sync status: $SYNC_STATUS_PATH"
echo "Latest successful sync: $LATEST_SYNC_PATH"
