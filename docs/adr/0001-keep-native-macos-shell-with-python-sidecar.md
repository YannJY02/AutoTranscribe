# Keep the native macOS shell with a Python sidecar

Status: accepted

## Context

InsightKit started as local transcription tooling, then grew into a native meeting-asset app with live capture, import, record review, local ASR, provider-backed insight generation, and export workflows. Historical architecture plans considered larger rewrites, but the current code already depends on SwiftUI for the macOS app surface and Python for ASR/provider/runtime work.

## Decision

InsightKit keeps a native SwiftUI macOS app as the user shell and a Python sidecar as the local speech and insight runtime. The app owns macOS capture, permissions, record review, notes, and export UX. The sidecar owns ASR, transcript ingestion, provider probing, insight generation, record writing, and integration-facing RPC actions.

## Consequences

- Preserve native macOS capture and review behavior instead of moving the primary app into a web shell.
- Preserve Python's stronger local ASR, diarization, provider, and data-processing ecosystem instead of forcing a full Swift rewrite.
- Treat the app/sidecar boundary as an intentional architecture seam. Refactors may shrink modules on either side, but they should not silently replace the sidecar with a remote service or merge runtime-heavy work into Swift.
- Historical AutoTranscribe language remains lineage only; current user-facing product language should stay InsightKit.
