# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Layout

This repo uses a multi-context domain documentation layout.

Start at the root `CONTEXT-MAP.md`. It points to context-specific `CONTEXT.md` files. Read the context docs relevant to the task before proposing architecture, debugging, refactors, test plans, or PRDs.

Expected contexts:

| Context | Path | Scope |
| --- | --- | --- |
| Product model | `docs/contexts/product/CONTEXT.md` | InsightKit purpose, user value, information model, product boundaries |
| Python runtime | `docs/contexts/python-runtime/CONTEXT.md` | ASR, sidecar, JSON-RPC, job queue, provider/runtime behavior |
| macOS app | `docs/contexts/macos-app/CONTEXT.md` | SwiftUI app, view models, app services, import/live/records UX |
| Release workflow | `docs/contexts/release-workflow/CONTEXT.md` | Package, sync, release validation, smoke tests, evidence artifacts |
| Integrations | `docs/contexts/integrations/CONTEXT.md` | AttentionOS module boundary and external host contracts |

System-wide architectural decisions live in `docs/adr/`.

Historical originals and converted Matt workflow views live in `docs/Legacy/matt-workflow-library/`. Start with `docs/Legacy/matt-workflow-library/manifest.md` when the task mentions old plans, historical release evidence, old product rationale, or moved Legacy assets.

## Before exploring, read these

- `AGENTS.md` and `docs/agents/loop-engineering.md` for the Matt workflow loop standard.
- `CONTEXT-MAP.md` at the repo root.
- The relevant context-specific `CONTEXT.md` files listed in the map.
- ADRs under `docs/adr/` that touch the area you're about to work in.
- `docs/Legacy/matt-workflow-library/manifest.md` only when the task depends on historical material or moved Legacy assets.

If any context or ADR files do not exist, proceed silently and infer from current code and tests. Do not suggest creating them upfront; add them lazily only when terminology or a decision is actually resolved.

## Use the glossary's vocabulary

When output names a domain concept, use the term as defined in the relevant `CONTEXT.md`. Do not drift to synonyms the glossary explicitly avoids.

If the concept is not in the glossary yet, treat that as a domain-doc gap rather than silently adding new terminology.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding it.

## Legacy promotion rules

Use Legacy converted assets as a source of context, not as current authority.

When historical material still matters, classify it into one of these current forms:

- **Context term**: if the code and user-facing workflow still use the concept, add or update the relevant `CONTEXT.md`.
- **ADR candidate**: if the historical material records a hard-to-reverse decision with real tradeoffs, write or update an ADR.
- **Current PRD or issue**: if the historical material describes unfinished useful work, create a Linear issue containing the current scope and a link to the historical source; native sync supplies the GitHub execution mirror.
- **Proof or release evidence**: if it is only evidence, keep it in the proof index and point current release docs to the newest proof.
- **Owner input**: if it requires credentials, legal text, Apple account access, or public release decisions, keep it in the owner-input checklist.
- **Legacy reference**: if the code already implements or supersedes it, leave it in Legacy and point to the current authority.

Make this classification from the repo first. Ask the user only when code, current docs, and proof cannot decide the correct form.
