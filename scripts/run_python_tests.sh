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
PYTEST_ARGS=(tests/)

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
  info "Running ALL tests (including integration)..."
else
  PYTEST_ARGS+=(-m "not integration and not requires_model and not slow")
  info "Running unit tests only (use --all for integration tests)..."
fi

if [[ "$RUN_COV" -eq 1 ]]; then
  PYTEST_ARGS+=(--cov=insightkit --cov-report=term-missing --cov-report=html:htmlcov)
  info "Coverage report will be generated in htmlcov/"
fi

PYTEST_ARGS+=(-v)
set +e
pytest "${PYTEST_ARGS[@]}" 2>&1 | tee /tmp/insightkit_pytest.log
pytest_status=${PIPESTATUS[0]}
set -e

if [[ "$pytest_status" -eq 0 ]]; then
  info "Python tests passed!"
  exit 0
else
  error "Some Python tests failed. Check /tmp/insightkit_pytest.log"
  exit 1
fi
