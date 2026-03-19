#!/usr/bin/env bash
set -euo pipefail

# ── InsightKit UI Tests Runner ──────────────────────────────────────
# Generates xcodeproj via XcodeGen (if needed) and runs XCUITests.
# Usage: ./scripts/run_uitests.sh [--regenerate]

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

if [[ ! -d "$XCODEPROJ" ]] || [[ "${1:-}" == "--regenerate" ]]; then
    info "Generating xcodeproj with XcodeGen..."
    xcodegen generate
    info "xcodeproj generated at $XCODEPROJ"
else
    info "Using existing xcodeproj at $XCODEPROJ"
fi

# ── Run UI Tests ────────────────────────────────────────────────────
info "Running XCUITests..."

xcodebuild test \
    -project InsightKitUITestHost.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -only-testing:InsightKitUITests \
    2>&1 | tee /tmp/insightkit_uitest.log

# ── Results ─────────────────────────────────────────────────────────
if grep -q "passed" /tmp/insightkit_uitest.log && ! grep -q "TEST FAILED" /tmp/insightkit_uitest.log; then
    info "All UI tests passed!"
    exit 0
else
    error "Some UI tests failed. Check /tmp/insightkit_uitest.log for details."
    exit 1
fi
