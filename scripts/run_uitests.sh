#!/usr/bin/env bash
set -euo pipefail

# ── InsightKit UI Tests Runner ──────────────────────────────────────
# Generates xcodeproj via XcodeGen and runs XCUITests.
# Usage: ./scripts/run_uitests.sh [--no-regenerate]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../macos/InsightKitApp"
XCODEPROJ="$PROJECT_DIR/InsightKitUITestHost.xcodeproj"
SCHEME="InsightKitApp"
DESTINATION="platform=macOS"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Prerequisites ───────────────────────────────────────────────────
if ! command -v xcodegen &>/dev/null; then
    error "XcodeGen not found. Install with: brew install xcodegen"
    exit 1
fi

if ! command -v xcodebuild &>/dev/null; then
    error "xcodebuild not found. Install Xcode from the App Store."
    exit 1
fi

# ── Generate / Regenerate xcodeproj ─────────────────────────────────
cd "$PROJECT_DIR"

if [[ "${1:-}" == "--no-regenerate" ]] && [[ -d "$XCODEPROJ" ]]; then
    info "Using existing xcodeproj at $XCODEPROJ"
else
    info "Generating xcodeproj with XcodeGen..."
    xcodegen generate
    info "xcodeproj generated at $XCODEPROJ"
fi

# ── Run UI Tests ────────────────────────────────────────────────────
info "Running XCUITests..."

UITEST_TIMEOUT_SEC="${INSIGHTKIT_UITEST_TIMEOUT_SEC:-90}"
LOG_PATH="${INSIGHTKIT_UITEST_LOG_PATH:-/tmp/insightkit_uitest.log}"
RESULT_BUNDLE="${INSIGHTKIT_UITEST_RESULT_BUNDLE:-/tmp/insightkit_uitest_$(date +%Y%m%d%H%M%S).xcresult}"
PROOF_ROOT="${INSIGHTKIT_UITEST_PROOF_ROOT:-${RESULT_BUNDLE%.xcresult}-proof}"
UNIFIED_LOG="$PROOF_ROOT/unified.ndjson"
ATTACHMENTS_DIR="$PROOF_ROOT/attachments"
VIDEO_PATH="$PROOF_ROOT/journey.mov"
TRACE_PATH="$PROOF_ROOT/journey.trace"
RECORD_VIDEO="${INSIGHTKIT_UITEST_RECORD_VIDEO:-0}"
RECORD_TRACE="${INSIGHTKIT_UITEST_RECORD_TRACE:-0}"
TRACE_TEMPLATE="${INSIGHTKIT_UITEST_TRACE_TEMPLATE:-Time Profiler}"

if [[ -e "$RESULT_BUNDLE" ]]; then
    error "Result bundle already exists: $RESULT_BUNDLE"
    exit 1
fi

if [[ -e "$PROOF_ROOT" ]]; then
    error "Proof directory already exists: $PROOF_ROOT"
    exit 1
fi

mkdir -p "$PROOF_ROOT"

LOG_STREAM_PID=""
VIDEO_PID=""
TRACE_WATCHER_PID=""

stop_evidence_capture() {
    if [[ -n "$TRACE_WATCHER_PID" ]]; then
        pkill -INT -P "$TRACE_WATCHER_PID" 2>/dev/null || true
        kill -TERM "$TRACE_WATCHER_PID" 2>/dev/null || true
        wait "$TRACE_WATCHER_PID" 2>/dev/null || true
        TRACE_WATCHER_PID=""
    fi
    if [[ -n "$VIDEO_PID" ]]; then
        kill -INT "$VIDEO_PID" 2>/dev/null || true
        wait "$VIDEO_PID" 2>/dev/null || true
        VIDEO_PID=""
    fi
    if [[ -n "$LOG_STREAM_PID" ]]; then
        kill -TERM "$LOG_STREAM_PID" 2>/dev/null || true
        wait "$LOG_STREAM_PID" 2>/dev/null || true
        LOG_STREAM_PID=""
    fi
}

trap stop_evidence_capture EXIT

/usr/bin/log stream \
    --style ndjson \
    --predicate 'process == "InsightKitApp" OR eventMessage CONTAINS "InsightKit" OR eventMessage CONTAINS "insight_sidecar"' \
    > "$UNIFIED_LOG" 2>&1 &
LOG_STREAM_PID=$!

if [[ "$RECORD_VIDEO" == "1" ]]; then
    # CI runners are isolated. Local runs must opt in because this records the main display.
    /usr/sbin/screencapture -v -x -D1 "$VIDEO_PATH" >/dev/null 2>&1 &
    VIDEO_PID=$!
fi

if [[ "$RECORD_TRACE" == "1" ]]; then
    (
        trace_deadline=$((SECONDS + UITEST_TIMEOUT_SEC))
        app_pid=""
        while (( SECONDS < trace_deadline )); do
            app_pid=$(pgrep -x InsightKitApp | head -n 1 || true)
            [[ -n "$app_pid" ]] && break
            sleep 1
        done
        if [[ -n "$app_pid" ]]; then
            xcrun xctrace record \
                --template "$TRACE_TEMPLATE" \
                --attach "$app_pid" \
                --time-limit "${UITEST_TIMEOUT_SEC}s" \
                --output "$TRACE_PATH"
        fi
    ) > "$PROOF_ROOT/xctrace.log" 2>&1 &
    TRACE_WATCHER_PID=$!
fi

set +e
STARTED_SECONDS=$SECONDS
xcodebuild test \
    -project InsightKitUITestHost.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -only-testing:InsightKitUITests \
    > "$LOG_PATH" 2>&1 &
XCODEBUILD_PID=$!

deadline=$((SECONDS + UITEST_TIMEOUT_SEC))
TIMED_OUT=0
while kill -0 "$XCODEBUILD_PID" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
        warn "XCUITests exceeded ${UITEST_TIMEOUT_SEC}s; terminating xcodebuild pid ${XCODEBUILD_PID}."
        kill -INT "$XCODEBUILD_PID" 2>/dev/null
        sleep 5
        kill -TERM "$XCODEBUILD_PID" 2>/dev/null
        sleep 2
        kill -KILL "$XCODEBUILD_PID" 2>/dev/null
        wait "$XCODEBUILD_PID" 2>/dev/null
        TIMED_OUT=1
        break
    fi
    sleep 2
done

if [[ "$TIMED_OUT" == "1" ]]; then
    TEST_STATUS=124
else
    wait "$XCODEBUILD_PID"
    TEST_STATUS=$?
fi
ELAPSED_SECONDS=$((SECONDS - STARTED_SECONDS))
stop_evidence_capture

if [[ -d "$RESULT_BUNDLE" ]]; then
    xcrun xcresulttool export attachments \
        --path "$RESULT_BUNDLE" \
        --output-path "$ATTACHMENTS_DIR" \
        > "$PROOF_ROOT/xcresult-attachments.log" 2>&1 || \
        warn "Could not export xcresult attachments; see $PROOF_ROOT/xcresult-attachments.log"
fi

PROOF_ARGS=(
    --output-root "$PROOF_ROOT"
    --exit-code "$TEST_STATUS"
    --duration-seconds "$ELAPSED_SECONDS"
    --xcodebuild-log "$LOG_PATH"
    --unified-log "$UNIFIED_LOG"
    --result-bundle "$RESULT_BUNDLE"
    --attachments-dir "$ATTACHMENTS_DIR"
)
[[ -f "$VIDEO_PATH" ]] && PROOF_ARGS+=(--video "$VIDEO_PATH")
[[ -d "$TRACE_PATH" ]] && PROOF_ARGS+=(--trace "$TRACE_PATH")
[[ "$RECORD_VIDEO" == "1" ]] && PROOF_ARGS+=(--require-video)
[[ "$RECORD_TRACE" == "1" ]] && PROOF_ARGS+=(--require-trace)
python3.11 "$SCRIPT_DIR/native_app_proof.py" "${PROOF_ARGS[@]}"
PROOF_STATUS=$?
set -e
trap - EXIT

# ── Results ─────────────────────────────────────────────────────────
if [[ "$TEST_STATUS" -eq 0 ]] && [[ "$PROOF_STATUS" -eq 0 ]] && grep -q "passed" "$LOG_PATH" && ! grep -q "TEST FAILED" "$LOG_PATH"; then
    info "All UI tests passed!"
    info "Log: $LOG_PATH"
    info "Result bundle: $RESULT_BUNDLE"
    info "Proof: $PROOF_ROOT/proof.json"
    exit 0
else
    error "UI proof failed. Log: $LOG_PATH Result bundle: $RESULT_BUNDLE Proof: $PROOF_ROOT/proof.json"
    tail -n 400 "$LOG_PATH" || true
    [[ "$TEST_STATUS" -eq 124 ]] && exit 124
    exit 1
fi
