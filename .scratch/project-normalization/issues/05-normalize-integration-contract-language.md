# Normalize integration contract language

Status: ready-for-human

## Parent

`.scratch/project-normalization/PRD.md`

## What to build

Normalize the AttentionOS integration contract around the Integrations glossary while preserving the core InsightKit product vocabulary. The slice should make the Host App, AttentionOS Module, Module Bundle, Bridge Action, Host Call, Bridge Payload, Module State, and External Host Contract terms clear in current-facing integration docs and generated module material.

User stories covered: 8, 13, 15, 21, 22.

## Acceptance criteria

- [ ] Current integration docs use Integration glossary terms consistently.
- [ ] Generated module material uses InsightKit meeting-asset vocabulary for product concepts and host-specific vocabulary only for host boundaries.
- [ ] Supported bridge actions are described as a stable External Host Contract.
- [ ] The integration source ledger entries distinguish current integration contracts from historical or exploratory notes.
- [ ] A focused test or verifier check confirms generated module material can still be produced and inspected for required contract markers.

## Blocked by

- `.scratch/project-normalization/issues/01-create-normalization-source-ledger.md`
- `.scratch/project-normalization/issues/02-add-project-normalization-verifier.md`

## Comments

### 2026-06-20 - Codex

Aligned AttentionOS integration contract language with the Integrations glossary.

Changed:
- `docs/attentionos-integration.md` now frames the integration as an AttentionOS Module, Module Bundle, Host App, Host Call, Bridge Payload, Bridge Action, Module State, and External Host Contract.
- `insightkit/integration/attentionos_bridge.py` generated README now includes External Host Contract markers and keeps InsightKit meeting-asset vocabulary for product results.
- `docs/project-normalization-source-ledger.md` now identifies `docs/attentionos-integration.md` and generated module README as current External Host Contract surfaces.
- `tests/test_attentionos_bridge.py` checks generated module material for required contract markers.

Evidence:
- `PYTHONPATH=. pytest tests/test_attentionos_bridge.py tests/test_verify_project_normalization.py` -> `8 passed`
- `python3 scripts/export_attention_module.py --output /tmp/insightkit-attentionos-module-check` -> module exported
- `python3 scripts/verify_project_normalization.py` -> `status: passed`
- Proof written to `logs/diagnostics/2026-06-20/project-normalization-20260620-001806/proof.json`
