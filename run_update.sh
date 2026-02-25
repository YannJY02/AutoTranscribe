#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "/Users/yann.jy/miniconda3/envs/transcribe/bin/python" "${SCRIPT_DIR}/scripts/update.py"
