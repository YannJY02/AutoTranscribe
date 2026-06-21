# InsightKit Architecture (M1/M2 Baseline)

## Goals
- Personal knowledge-asset meeting assistant.
- Differentiated information model: 会话总览 / 高光洞察 / 观点图谱 / 决策账本 / 执行清单 / 时间脉络.
- Unloadable integration path for external host app (`/Users/yann.jy/Desktop/AI/RSS`).

## Runtime Components
1. `macos/InsightKitApp` (SwiftUI shell)
2. `scripts/insight_sidecar.py` (Unix socket JSON-RPC)
3. `insightkit/data/store.py` (SQLite + FTS5)
4. `insightkit/insights/*` (prompting, provider adapter, schema validation, postprocess)

## JSON-RPC Methods
- `session.start`
- `stream.push_audio`
- `transcript.delta`
- `insight.refresh_live`
- `insight.build_final`
- `document.export`

## InsightPackageV1
Schema file:
- `/Users/yann.jy/Desktop/AI/transcription/insightkit/schemas/insight_package_v1.json`

Required top-level keys:
- `session_overview`
- `highlight_insights`
- `speaker_perspectives`
- `decision_ledger`
- `action_tracks`
- `timeline_beats`
- `provenance_links`

## Compliance Safeguard
Banned term scanner:
- `/Users/yann.jy/Desktop/AI/transcription/insightkit/compliance/scan_terms.py`

Usage:
```bash
python3 insightkit/compliance/scan_terms.py \
  README.md scripts/*.py insightkit/**/*.py macos/InsightKitApp/Sources/InsightKitApp/*.swift
```
