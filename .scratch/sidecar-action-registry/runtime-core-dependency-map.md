# Runtime Core Dependency Map

Status: current
Last reviewed: 2026-06-29

## Purpose

This map bounds Stage 3 runtime-core rewrite work behind the existing Runtime Action Boundary. It identifies the seams that can be deepened without changing Swift-facing RPC Action contracts.

## Core Seams

| Seam | Runtime role | Depends on | Feeds | Rewrite risk |
| --- | --- | --- | --- | --- |
| ASR Runtime Profile | Reports configured ASR Engine, active ASR Engine, live/final-media readiness, warm state, backend status, diarization state, degradation, and user recovery hint. | ASR Model Catalog, ASR Runtime bootstrap, Runtime Warmup, diarization probes, Apple Speech parity signal. | Settings, diagnostics, ASR prewarm/status, Final Media Transcription readiness proof. | High product leverage; low contract risk when added as a status snapshot. |
| Transcript Store | Owns current meeting Transcript Segments and replacement semantics during live and final-media transitions. | Meeting ID, live deltas, final-media transcript, Record Save Action. | Live Workspace, Smart Minutes generation, Transcript Recovery. | Medium; mistakes can overwrite official transcript evidence. |
| Record Writer | Writes complete Record Folder artifacts. | Transcript Store, media path, notes, insight package, metadata. | Record Review, export, recovery. | High; protected by ADR-0004 and existing record tests. |
| Smart Minutes Generation | Builds final insight package from transcript evidence. | Transcript Store, Provider, prompt templates, Record Writer. | Live Workspace result, Record Review, exports. | Medium; provider failures must degrade locally. |
| Provider Probe | Reports analysis-provider configuration and bounded probe result. | App config/env, provider SDKs, timeouts. | Settings, diagnostics, Smart Minutes. | Low-to-medium; timeout behavior is user-visible. |
| Job Queue | Orders import/watch transcription jobs and reports progress. | Transcription runner, Provider, Record Writer, Push Broker. | Import Workspace, transcription status, cancellation. | Medium; concurrency and cancellation-sensitive. |
| Runtime Status | Reports sidecar and runtime availability without blocking. | Sidecar state, ASR Runtime Profile, Provider Probe, Job Queue. | Settings, diagnostics, proof scripts. | High leverage; must avoid slow model locks. |
| Long-Running Work | Runs prewarm, import, watch, final-media transcription, and provider work without freezing app RPC. | Job Queue, Push Broker, Runtime Warmup, action registry states. | Persistent RPC events, status actions, recovery actions. | High; broad but can be rewritten one action at a time. |

## First Slice Selection

ASR Runtime Profile remains the first Stage 3 slice because it improves a real product flow with bounded blast radius:

- Settings, diagnostics, and proof previously read overlapping but not identical ASR status shapes.
- Live ASR readiness and final-media ASR readiness need to be reported separately.
- Runtime Warmup can be incomplete while final-media ASR is still usable.
- Apple Speech needs explicit peer-engine capability and limitation reporting without pretending it is already a Python Sidecar ASR Engine.

The first implementation slice adds a shared profile snapshot and wires `asr.runtime.status`, diagnostics, and proof to consume it while preserving existing RPC fields.

## Stage 3 Stop Point

Stop after the ASR Runtime Profile snapshot is covered by focused tests and proof. Do not rewrite Transcript Store, Record Writer, Smart Minutes, Job Queue, or long-running work in this slice.
