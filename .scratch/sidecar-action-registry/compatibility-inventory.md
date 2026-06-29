# Runtime Compatibility Inventory

Status: current
Last reviewed: 2026-06-29

Parent: `.scratch/sidecar-action-registry/issues/04-clean-up-runtime-compatibility-paths.md`

## Scope

This inventory quarantines old sidecar method names after the product action boundary became available. The current cleanup rule is conservative: keep a compatibility shim when an older app build, local automation, or optional integration route may still call the old method.

## Current Product Boundary

The app-facing product actions are:

- `record.save`
- `transcript.recover`
- `media.transcribe_final`
- `runtime.transcript.replace`
- `smart_minutes.generate`

`sidecar.action_registry` remains the authoritative capability source for product actions. `sidecar.compatibility_routes` explains legacy method names that remain available only as compatibility shims.

## Compatibility Shims

| Legacy method | Replacement product action | Current handling | Cleanup decision | Proof |
| --- | --- | --- | --- | --- |
| `records.save` | `record.save` | Handler remains unchanged; `record.save` delegates to the same Record Writer and adds product boundary status. | Keep as shim for older app builds and local automation. | `tests/test_runtime_compatibility_cleanup.py` proves both methods save records. |
| `asr.transcribe_media` | `media.transcribe_final` | Handler remains unchanged; `media.transcribe_final` wraps it with product boundary status. | Keep as shim while final media transcription and transcript recovery share ASR media transcription. | `tests/test_runtime_compatibility_cleanup.py` proves legacy and product media transcription return matching segments. |
| `transcript.replace` | `runtime.transcript.replace` | Handler remains unchanged; product action validates product input and delegates to the runtime transcript store. | Keep as shim for older app builds. | `tests/test_runtime_compatibility_cleanup.py` proves legacy and product replacement both work. |
| `insight.build_final` | `smart_minutes.generate` | Handler remains unchanged; product action adds transcript sufficiency and degraded-provider status. | Keep as shim for older app builds and optional integration routes. | `tests/test_runtime_compatibility_cleanup.py` proves legacy and product Smart Minutes generation both work. |

## Duplicate Status And Capability Paths

- `sidecar.action_registry` is the product action capability source.
- `sidecar.version.capabilities` still lists callable JSON-RPC methods for older app code.
- `sidecar.version.compatibility_routes` and `sidecar.compatibility_routes` make legacy shims explicit.
- `module.capabilities` remains a broad compatibility list for older module callers, but product action clients should not treat it as the primary action state model.

## Integration-Only Routes

`insightkit/integration/attentionos_bridge.py` still uses legacy `insight.build_final` because optional external integration is deferred to Stage 5. It is not a core InsightKit app dependency.

## Removal Gate

A shim can be removed only after all of the following are true:

- current Swift app code no longer needs the legacy method name;
- installed app smoke proof passes through the product action boundary;
- any optional integration caller has been migrated or intentionally retired;
- a focused compatibility test is updated to prove the removal or the remaining shim.
