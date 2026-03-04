# AttentionOS Integration (Unloadable Module)

This repo now ships a generator that produces an AttentionOS-compatible module bundle.

## Generate module
```bash
python3 scripts/export_attention_module.py --output dist/attentionos-insightkit-module
```

Generated files:
- `manifest.json`
- `index.py`
- `README.md`
- `state.txt` (`enabled`)

## Install into AttentionOS modules folder
```bash
MODULE_ROOT="$HOME/Library/Application Support/AttentionOS/modules/insightkit-meeting-module"
mkdir -p "$MODULE_ROOT"
cp -R dist/attentionos-insightkit-module/* "$MODULE_ROOT"/
```

## Host call input contract
```json
{
  "action": "insight.build_final",
  "meeting_id": "session-123",
  "payload": {}
}
```

Supported actions:
- `session.start`
- `insight.refresh_live`
- `insight.build_final`
- `document.export`

## Runtime requirement
The sidecar must be running:
```bash
python3 scripts/insight_sidecar.py
```

Socket path defaults to `/tmp/insightkit.sock` and can be overridden by `INSIGHTKIT_SOCKET`.
