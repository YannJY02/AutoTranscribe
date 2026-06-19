#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/quit_insightkit_app.sh"
"$ROOT_DIR/scripts/dev_check_insightkit_processes.sh"
