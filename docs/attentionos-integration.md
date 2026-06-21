# AttentionOS Integration (AttentionOS Module)

This repo ships an AttentionOS Module generator for InsightKit. The generated Module Bundle is the current External Host Contract between a Host App and InsightKit's local Sidecar.

## Generate Module Bundle
```bash
python3 scripts/export_attention_module.py --output dist/attentionos-insightkit-module
```

Module Bundle files:
- `manifest.json`
- `index.py`
- `README.md`
- `state.txt` (`enabled`)

## Install Into Host App Modules Folder
```bash
MODULE_ROOT="$HOME/Library/Application Support/AttentionOS/modules/insightkit-meeting-module"
mkdir -p "$MODULE_ROOT"
cp -R dist/attentionos-insightkit-module/* "$MODULE_ROOT"/
```

## External Host Contract

A Host App sends a Host Call to the AttentionOS Module. The Host Call selects one Bridge Action and passes a Bridge Payload.

### Host Call Shape
```json
{
  "action": "insight.build_final",
  "meeting_id": "session-123",
  "payload": {}
}
```

### Stable Bridge Actions
- `session.start`
- `session.stop`
- `live.session.start`
- `live.session.stop`
- `live.session.status`
- `sidecar.ensure_ready`
- `sidecar.version`
- `diagnostics.quick_check`
- `asr.runtime.status`
- `asr.runtime.bootstrap`
- `insight.refresh_live`
- `insight.build_final`
- `document.export`
- `transcription.import_file`
- `transcription.watch.start`
- `transcription.watch.stop`
- `transcription.status`
- `transcription.cancel_job`

### Bridge Payload Rules

- `meeting_id` identifies the InsightKit meeting asset or active session.
- `payload` carries Bridge Action-specific fields such as title, source, output format, ASR engine, model name, import path, watch directories, or cancellation reason.
- The returned `result` is InsightKit meeting-asset data from the local Sidecar. Host-specific labels should stay outside the product model.

## Module State

The generated `state.txt` stores Module State. The current generator writes `enabled`, meaning a Host App may load the Module Bundle.

## Runtime requirement
The local InsightKit Sidecar must be running:
```bash
python3 scripts/insight_sidecar.py
```

Socket path defaults to `/tmp/insightkit.sock` and can be overridden by `INSIGHTKIT_SOCKET`.
