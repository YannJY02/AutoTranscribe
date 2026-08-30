#!/usr/bin/env bash
set -euo pipefail

# ── InsightKit UI Tests Runner ──────────────────────────────────────
# Generates xcodeproj via XcodeGen and runs XCUITests.
# Usage: ./scripts/run_uitests.sh [--no-regenerate]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOCATION_DIR="$PWD"
PROJECT_DIR="$SCRIPT_DIR/../macos/InsightKitApp"
XCODEPROJ="$PROJECT_DIR/InsightKitUITestHost.xcodeproj"
SCHEME="InsightKitApp"
DESTINATION="platform=macOS"
DERIVED_DATA_PATH="${INSIGHTKIT_UITEST_DERIVED_DATA_PATH:-$PROJECT_DIR/.build/uitest-derived-data}"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
display_path() {
    case "$1" in
        "$HOME") printf '%s' '$HOME' ;;
        "$HOME"/*) printf '%s/%s' '$HOME' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

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
    info "Using existing xcodeproj at $(display_path "$XCODEPROJ")"
else
    info "Generating xcodeproj with XcodeGen..."
    XCODEGEN_LOG="$(mktemp /tmp/insightkit-xcodegen.XXXXXX.log)"
    if ! xcodegen generate --quiet > "$XCODEGEN_LOG" 2>&1; then
        PYTHONPATH="$SCRIPT_DIR/.." python3.11 -c \
            'import sys; from pathlib import Path; from scripts.native_app_proof import _redact_text_file; _redact_text_file(Path(sys.argv[1]))' \
            "$XCODEGEN_LOG"
        error "XcodeGen failed; sanitized log: $XCODEGEN_LOG"
        tail -n 100 "$XCODEGEN_LOG"
        exit 1
    fi
    rm -f "$XCODEGEN_LOG"
    info "xcodeproj generated at $(display_path "$XCODEPROJ")"
fi

# ── Run UI Tests ────────────────────────────────────────────────────
info "Running XCUITests..."

UITEST_TIMEOUT_SEC="${INSIGHTKIT_UITEST_TIMEOUT_SEC:-300}"
LOG_PATH="${INSIGHTKIT_UITEST_LOG_PATH:-/tmp/insightkit_uitest.log}"
RESULT_BUNDLE="${INSIGHTKIT_UITEST_RESULT_BUNDLE:-/tmp/insightkit_uitest_$(date +%Y%m%d%H%M%S).xcresult}"
PROOF_ROOT="${INSIGHTKIT_UITEST_PROOF_ROOT:-${RESULT_BUNDLE%.xcresult}-proof}"
if [[ "$PROOF_ROOT" != /* ]]; then
    PROOF_ROOT="$INVOCATION_DIR/$PROOF_ROOT"
fi
if [[ "$DERIVED_DATA_PATH" != /* ]]; then
    DERIVED_DATA_PATH="$INVOCATION_DIR/$DERIVED_DATA_PATH"
fi
case "$DERIVED_DATA_PATH" in
    *\\*|*\"*) error "Derived-data path cannot contain a backslash or quote."; exit 1 ;;
esac
mkdir -p "$DERIVED_DATA_PATH"
DERIVED_DATA_PATH="$(cd "$DERIVED_DATA_PATH" && pwd -P)"
UNIFIED_LOG="$PROOF_ROOT/unified.ndjson"
ATTACHMENTS_DIR="$PROOF_ROOT/attachments"
XCRESULT_SUMMARY="$PROOF_ROOT/xcresult-summary.json"
VIDEO_PATH="$PROOF_ROOT/journey.mov"
TRACE_PATH="$PROOF_ROOT/journey.trace"
RECORD_VIDEO="${INSIGHTKIT_UITEST_RECORD_VIDEO:-0}"
RECORD_TRACE="${INSIGHTKIT_UITEST_RECORD_TRACE:-0}"
TRACE_TEMPLATE="${INSIGHTKIT_UITEST_TRACE_TEMPLATE:-Time Profiler}"
SOURCE_REVISION="${INSIGHTKIT_UITEST_SOURCE_REVISION:-$(git -C "$SCRIPT_DIR/.." rev-parse HEAD)}"
BUILD_ID="${INSIGHTKIT_UITEST_BUILD:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PROJECT_DIR/InsightKitApp-Info.plist")}"
SCENARIO="${INSIGHTKIT_UITEST_SCENARIO:-all-ui-tests}"
SELECTED_TESTS="${INSIGHTKIT_UITEST_SELECTED_TESTS:-}"
EXPECTED_SCREENSHOTS="${INSIGHTKIT_UITEST_EXPECTED_SCREENSHOTS:-target-window}"
FAILURE_CLASSIFICATION="${INSIGHTKIT_UITEST_FAILURE_CLASSIFICATION:-}"

if [[ -e "$RESULT_BUNDLE" ]]; then
    error "Result bundle already exists: $(display_path "$RESULT_BUNDLE")"
    exit 1
fi

if [[ -e "$PROOF_ROOT" ]]; then
    error "Proof directory already exists: $(display_path "$PROOF_ROOT")"
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

LOG_PREDICATE="process == \"InsightKitApp\" AND processImagePath BEGINSWITH \"$DERIVED_DATA_PATH/\""
/usr/bin/log stream \
    --style ndjson \
    --predicate "$LOG_PREDICATE" \
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

XCODEBUILD_SELECTION=(-only-testing:InsightKitUITests)
if [[ -n "$SELECTED_TESTS" ]]; then
    XCODEBUILD_SELECTION=()
    IFS=',' read -r -a selected_test_items <<< "$SELECTED_TESTS"
    for selected_test in "${selected_test_items[@]}"; do
        XCODEBUILD_SELECTION+=("-only-testing:InsightKitUITests/$selected_test")
    done
fi

set +e
STARTED_SECONDS=$SECONDS
xcodebuild test \
    -project InsightKitUITestHost.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$RESULT_BUNDLE" \
    "${XCODEBUILD_SELECTION[@]}" \
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
        warn "Could not export xcresult attachments; see $(display_path "$PROOF_ROOT/xcresult-attachments.log")"
    xcrun xcresulttool get test-results summary \
        --path "$RESULT_BUNDLE" \
        > "$XCRESULT_SUMMARY" 2> "$PROOF_ROOT/xcresult-summary.log" || \
        warn "Could not export xcresult summary; see $(display_path "$PROOF_ROOT/xcresult-summary.log")"
fi

PROOF_ARGS=(
    --output-root "$PROOF_ROOT"
    --exit-code "$TEST_STATUS"
    --duration-seconds "$ELAPSED_SECONDS"
    --xcodebuild-log "$LOG_PATH"
    --unified-log "$UNIFIED_LOG"
    --result-bundle "$RESULT_BUNDLE"
    --result-summary "$XCRESULT_SUMMARY"
    --attachments-dir "$ATTACHMENTS_DIR"
    --source-revision "$SOURCE_REVISION"
    --build "$BUILD_ID"
    --scenario "$SCENARIO"
)
if [[ -n "$SELECTED_TESTS" ]]; then
    IFS=',' read -r -a selected_test_items <<< "$SELECTED_TESTS"
    for selected_test in "${selected_test_items[@]}"; do
        PROOF_ARGS+=(--selected-test "$selected_test")
    done
fi
if [[ -n "$EXPECTED_SCREENSHOTS" ]]; then
    IFS=',' read -r -a expected_screenshot_items <<< "$EXPECTED_SCREENSHOTS"
    for expected_screenshot in "${expected_screenshot_items[@]}"; do
        PROOF_ARGS+=(--expected-screenshot "$expected_screenshot")
    done
fi
if [[ -n "$FAILURE_CLASSIFICATION" ]]; then
    PROOF_ARGS+=(--failure-classification "$FAILURE_CLASSIFICATION")
fi
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
    info "Log: $(display_path "$LOG_PATH")"
    info "Result bundle: $(display_path "$RESULT_BUNDLE")"
    info "Proof: $(display_path "$PROOF_ROOT/proof.json")"
    exit 0
else
    error "UI proof failed. Log: $(display_path "$LOG_PATH") Result bundle: $(display_path "$RESULT_BUNDLE") Proof: $(display_path "$PROOF_ROOT/proof.json")"
    tail -n 400 "$PROOF_ROOT/xcodebuild.log" || true
    [[ "$TEST_STATUS" -eq 124 ]] && exit 124
    exit 1
fi
