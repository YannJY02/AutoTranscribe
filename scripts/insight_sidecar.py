#!/usr/bin/env python3
"""Run InsightKit JSON-RPC sidecar."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from insightkit.ipc.server import main


if __name__ == "__main__":
    raise SystemExit(main())
