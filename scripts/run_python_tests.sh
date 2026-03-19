#!/usr/bin/env bash
set -euo pipefail

# ── InsightKit Python Test Runner ──────────────────────────────────
# Runs Python unit tests with coverage.
# Usage: ./scripts/run_python_tests.sh [--all] [--cov]
#
# By default runs only unit tests (no sidecar required).
# --all: also run integration tests (requires running sidecar)
# --cov: generate coverage report

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

RUN_ALL=0
RUN_COV=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) RUN_ALL=1; shift ;;
    --cov) RUN_COV=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

cd "$ROOT_DIR"

if ! command -v pytest &>/dev/null; then
  error "pytest not found. Install with: pip install pytest pytest-cov"
  exit 1
fi

if [[ "$RUN_ALL" -eq 1 ]]; then
  MARKER_FILTER=""
  info "Running ALL tests (including integration)..."
else
  MARKER_FILTER="-m not integration and not requires_model and not slow"
  info "Running unit tests only (use --all for integration tests)..."
fi

COV_FLAGS=""
if [[ "$RUN_COV" -eq 1 ]]; then
  COV_FLAGS="--cov=insightkit --cov-report=term-missing --cov-report=html:htmlcov"
  info "Coverage report will be generated in htmlcov/"
fi

pytest tests/ $MARKER_FILTER $COV_FLAGS -v 2>&1 | tee /tmp/insightkit_pytest.log

if grep -q "passed" /tmp/insightkit_pytest.log && ! grep -q "error" /tmp/insightkit_pytest.log; then
  info "Python tests passed!"
  exit 0
else
  error "Some Python tests failed. Check /tmp/insightkit_pytest.log"
  exit 1
fi
