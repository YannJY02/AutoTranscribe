# Use persistent Unix socket RPC for app-runtime communication

Status: accepted

## Context

The early app/runtime seam used short Unix socket JSON-RPC calls. Historical IPC plans identified repeated socket setup, live-workflow latency, manual untyped decoding, and lack of server push as friction for live transcription and long-running imports.

## Decision

The app and sidecar communicate through Unix socket JSON-RPC, with persistent NDJSON framing for long-running/live workflows while retaining compatibility with older short-call behavior.

Persistent clients perform an InsightKit handshake, exchange one JSON message per line, match request/response messages by id, and receive RPC Event messages such as transcription progress or warmup-state changes. The Python sidecar keeps a `PushBroker` for active persistent clients, while Swift uses `RPCTransport` and `RPCCodec` for framing and typed decoding.

## Consequences

- Runtime communication stays local and low-overhead without moving the app to an embedded web server or remote service model.
- Live and import workflows can receive pushed progress instead of relying only on repeated polling.
- Existing short-call behavior remains a compatibility path for scripts, tests, and older callers.
- Future RPC changes should preserve the action vocabulary in `docs/contexts/python-runtime/CONTEXT.md` and avoid duplicating app/runtime contracts in unrelated integration code.
