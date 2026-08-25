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

if [[ -e "$RESULT_BUNDLE" ]]; then
    error "Result bundle already exists: $RESULT_BUNDLE"
    exit 1
fi

set +e
xcodebuild test \
    -project InsightKitUITestHost.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -only-testing:InsightKitUITests \
    > "$LOG_PATH" 2>&1 &
XCODEBUILD_PID=$!

deadline=$((SECONDS + UITEST_TIMEOUT_SEC))
while kill -0 "$XCODEBUILD_PID" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
        warn "XCUITests exceeded ${UITEST_TIMEOUT_SEC}s; terminating xcodebuild pid ${XCODEBUILD_PID}."
        kill -INT "$XCODEBUILD_PID" 2>/dev/null
        sleep 5
        kill -TERM "$XCODEBUILD_PID" 2>/dev/null
        sleep 2
        kill -KILL "$XCODEBUILD_PID" 2>/dev/null
        wait "$XCODEBUILD_PID" 2>/dev/null
        error "XCUITests timed out. Log: $LOG_PATH Result bundle: $RESULT_BUNDLE"
        tail -n 400 "$LOG_PATH" || true
        exit 124
    fi
    sleep 2
done

wait "$XCODEBUILD_PID"
TEST_STATUS=$?
set -e

# ── Results ─────────────────────────────────────────────────────────
if [[ "$TEST_STATUS" -eq 0 ]] && grep -q "passed" "$LOG_PATH" && ! grep -q "TEST FAILED" "$LOG_PATH"; then
    info "All UI tests passed!"
    info "Log: $LOG_PATH"
    info "Result bundle: $RESULT_BUNDLE"
    exit 0
else
    error "Some UI tests failed. Log: $LOG_PATH Result bundle: $RESULT_BUNDLE"
    tail -n 400 "$LOG_PATH" || true
    exit 1
fi
