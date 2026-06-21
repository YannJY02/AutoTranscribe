# Architecture Decision Map

Status: historical-reference

## Purpose

This file maps the moved architecture reference to current accepted decisions.

Original architecture source:
- `docs/Legacy/matt-workflow-library/original-assets/docs/architecture/insightkit-architecture.md`

## Current Decision Chain

| Historical architecture idea | Current accepted decision | Current authority |
| --- | --- | --- |
| Native SwiftUI app as the user shell | Keep native macOS shell with Python Sidecar | `docs/adr/0001-keep-native-macos-shell-with-python-sidecar.md` |
| Python runtime outside the app UI layer | Keep runtime-heavy work in Python Sidecar | `docs/adr/0001-keep-native-macos-shell-with-python-sidecar.md` |
| JSON-RPC methods for app-runtime actions | Use persistent Unix socket RPC | `docs/adr/0002-use-persistent-unix-socket-rpc-for-app-runtime-communication.md` |
| Local proof before public distribution | Separate Local Release Ready from Distribution Ready | `docs/adr/0003-separate-local-readiness-from-public-distribution-readiness.md` |
| Insight package with summary, highlights, speaker views, decisions, actions, and timeline | Use current product and runtime context vocabulary | `docs/contexts/product/CONTEXT.md`, `docs/contexts/python-runtime/CONTEXT.md` |

## What The Historical Source Is Good For

- Understanding why the app/runtime split exists.
- Finding older JSON-RPC method names.
- Understanding the early `InsightPackageV1` shape.
- Understanding how compliance scanning entered the project.

## What The Historical Source Must Not Do

- Override accepted ADRs.
- Define current release readiness.
- Replace context vocabulary.
- Become the starting point for new refactors.

## Future Matt Workflow Use

When architecture work starts, use this order:

1. Read `AGENTS.md`.
2. Read `CONTEXT-MAP.md`.
3. Read the relevant context docs.
4. Read accepted ADRs.
5. Use this Legacy map only as background.
6. Create or update current `.scratch/` PRD and issues before changing code.
