"""Generate AttentionOS-compatible unloadable module wrapper for InsightKit."""

from __future__ import annotations

import json
from pathlib import Path

MANIFEST = {
    "id": "insightkit.meeting.module",
    "name": "InsightKit Meeting Module",
    "version": "0.1.0",
    "kind": "intervention",
    "permissions": ["network_access", "read_notes"],
    "entry": "index.py",
    "inputSchema": {
        "action": "string",
        "meeting_id": "string",
        "payload": "object"
    },
    "outputSchema": {
        "ok": "boolean",
        "summary": "string",
        "result": "object"
    },
    "description": "AttentionOS Module forwarding Host Calls to the local InsightKit Sidecar."
}

ENTRY_SCRIPT = """#!/usr/bin/env python3
import json
import socket
import os

SOCKET_PATH = os.getenv(\"INSIGHTKIT_SOCKET\", "/tmp/insightkit.sock")


def rpc_call(method, params, req_id=1):
    req = {\"jsonrpc\": \"2.0\", \"id\": req_id, \"method\": method, \"params\": params}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(SOCKET_PATH)
        s.sendall(json.dumps(req).encode(\"utf-8\"))
        data = s.recv(4 * 1024 * 1024)
    resp = json.loads(data.decode(\"utf-8\"))
    if \"error\" in resp:
        raise RuntimeError(resp[\"error\"].get(\"message\", \"unknown rpc error\"))
    return resp.get(\"result\")


def main():
    raw = input().strip()
    payload = json.loads(raw) if raw else {}

    action = payload.get(\"action\", \"insight.build_final\")
    meeting_id = payload.get(\"meeting_id\")
    ext_payload = payload.get(\"payload\", {})

    if action == \"session.start\":
        result = rpc_call(\"session.start\", {
            \"meeting_id\": meeting_id,
            \"title\": ext_payload.get(\"title\", \"AttentionOS Session\"),
            \"source\": ext_payload.get(\"source\", \"file\")
        })
    elif action == \"live.session.start\":
        result = rpc_call(\"live.session.start\", {
            \"meeting_id\": meeting_id,
            \"title\": ext_payload.get(\"title\", \"AttentionOS Live Session\"),
            \"source\": ext_payload.get(\"source\", \"mixed\")
        })
    elif action == \"live.session.stop\":
        result = rpc_call(\"live.session.stop\", {\"meeting_id\": meeting_id})
    elif action == \"live.session.status\":
        result = rpc_call(\"live.session.status\", {\"meeting_id\": meeting_id})
    elif action == \"session.stop\":
        result = rpc_call(\"session.stop\", {\"meeting_id\": meeting_id})
    elif action == \"sidecar.ensure_ready\":
        result = rpc_call(\"sidecar.ensure_ready\", {
            \"timeout_sec\": int(ext_payload.get(\"timeout_sec\", 6))
        })
    elif action == \"sidecar.version\":
        result = rpc_call(\"sidecar.version\", {})
    elif action == \"diagnostics.quick_check\":
        result = rpc_call(\"diagnostics.quick_check\", {})
    elif action == \"asr.runtime.status\":
        result = rpc_call(\"asr.runtime.status\", {
            \"engine\": ext_payload.get(\"engine\", \"\")
        })
    elif action == \"asr.runtime.bootstrap\":
        result = rpc_call(\"asr.runtime.bootstrap\", {
            \"engine\": ext_payload.get(\"engine\", \"\"),
            \"model\": ext_payload.get(\"model\", \"\")
        })
    elif action == \"insight.refresh_live\":
        result = rpc_call(\"insight.refresh_live\", {
            \"meeting_id\": meeting_id,
            \"window_sec\": int(ext_payload.get(\"window_sec\", 120))
        })
    elif action == \"insight.build_final\":
        result = rpc_call(\"insight.build_final\", {\"meeting_id\": meeting_id})
    elif action == \"document.export\":
        result = rpc_call(\"document.export\", {
            \"meeting_id\": meeting_id,
            \"format\": ext_payload.get(\"format\", \"markdown\"),
            \"output_dir\": ext_payload.get(\"output_dir\", \"\")
        })
    elif action == \"transcription.import_file\":
        result = rpc_call(\"transcription.import_file\", {
            \"file_path\": ext_payload.get(\"file_path\", \"\"),
            \"title\": ext_payload.get(\"title\", \"\")
        })
    elif action == \"transcription.watch.start\":
        result = rpc_call(\"transcription.watch.start\", {
            \"dirs\": ext_payload.get(\"dirs\", [])
        })
    elif action == \"transcription.watch.stop\":
        result = rpc_call(\"transcription.watch.stop\", {})
    elif action == \"transcription.status\":
        result = rpc_call(\"transcription.status\", {})
    elif action == \"transcription.cancel_job\":
        result = rpc_call(\"transcription.cancel_job\", {
            \"job_id\": ext_payload.get(\"job_id\", \"\"),
            \"reason\": ext_payload.get(\"reason\", \"\")
        })
    else:
        raise RuntimeError(f\"unsupported action: {action}\")

    output = {
        \"ok\": True,
        \"summary\": f\"InsightKit action {action} completed\",
        \"result\": result
    }
    print(json.dumps(output, ensure_ascii=False))


if __name__ == \"__main__\":
    main()
"""

README = """# InsightKit Meeting Module

This AttentionOS Module is loadable by a Host App and forwards Host Calls to the local InsightKit Sidecar.

## External Host Contract

A Host Call selects one Bridge Action and passes a Bridge Payload. The returned result uses InsightKit meeting-asset vocabulary; host-specific labels should stay outside the product model.

## Stable Bridge Actions
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

## Host Call Shape
```json
{
  "action": "insight.build_final",
  "meeting_id": "your-session-id",
  "payload": {}
}
```

## Bridge Payload

`payload` carries Bridge Action-specific fields such as title, source, output format, ASR engine, model name, import path, watch directories, or cancellation reason.

## Module State

`state.txt` stores Module State. The current generator writes `enabled`.
"""


def export_module(output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "manifest.json").write_text(
        json.dumps(MANIFEST, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    entry = output_dir / "index.py"
    entry.write_text(ENTRY_SCRIPT, encoding="utf-8")
    entry.chmod(0o755)
    (output_dir / "README.md").write_text(README, encoding="utf-8")
    (output_dir / "state.txt").write_text("enabled\n", encoding="utf-8")
    return output_dir
