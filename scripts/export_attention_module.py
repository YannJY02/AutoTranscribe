#!/usr/bin/env python3
"""Export AttentionOS-loadable module bundle for InsightKit."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from insightkit.integration.attentionos_bridge import export_module


def main() -> int:
    parser = argparse.ArgumentParser(description="Export InsightKit module for AttentionOS")
    parser.add_argument(
        "--output",
        default="dist/attentionos-insightkit-module",
        help="output directory for generated module",
    )
    args = parser.parse_args()

    out = export_module(Path(args.output).resolve())
    print(f"module exported: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
