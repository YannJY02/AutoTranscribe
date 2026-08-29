# Matt Workflow Loop Engineering

Status: current
Mode: sequential safe

Every development pass is a bounded Goal, Context, Boundary, Action, Verification, Feedback, and Record loop.

## Purpose

Ship one small verified change or one evidence-backed investigation, then leave the Linear task and synchronized GitHub execution issue easier for the next agent to operate.

## Preconditions

- Read `AGENTS.md`, `docs/agents/harness.md`, issue-tracker and triage rules.
- Interactive planning reads the canonical Linear task and its GitHub-synced thread. Unattended Symphony treats the synchronized GitHub projection as its execution contract; preflight resolves the Linear identifier from the verified `linear-code` linkback comment, while Linear-only fields remain guaranteed by triage.
- Read `CONTEXT-MAP.md`, only relevant `CONTEXT.md` files, and affected ADRs.
- Run `agent_harness.py issue-preflight` before unattended execution.

## Standard Loop Packet

1. Goal: concrete repository or software state at completion.
2. Context: authoritative docs, code, issue, ADR, and evidence.
3. Boundary: in scope, out of scope, Resource class, and stop conditions.
4. Action: smallest root-cause change.
5. Verification: exact commands and user-visible proof.
6. Feedback: smallest next action when a gate fails.
7. Record: GitHub comment, PR, manifest, proof, Context, or ADR.

## Matt Workflow Routes

### Project Health Route

`review` → `improve-codebase-architecture` → `grilling`/`domain-modeling` → `to-prd` → `to-issues` → `implement`. Publish the accepted PRD and slices as linked Linear issues, let native sync create their GitHub mirrors, and do not use local active markdown.

### Feature Route

`grill-with-docs` → `to-prd` → `to-issues` → `implement`, with each implementation slice independently verifiable.

### Incoming Issue Route

`triage` first; `implement` only after the issue contract passes and `ready-for-agent` is present.

### Legacy Asset Promotion Route

Start at `docs/Legacy/matt-workflow-library/manifest.md`, compare the converted asset with current code, Context, ADRs, and proof, then classify it as a context term, ADR candidate, current PRD or issue, proof, owner input, or Legacy reference. Promote unfinished useful work into Linear issues. Verify documentation with `verify_project_normalization.py`.

## Verification Ladder

| Level | Question |
| --- | --- |
| Exists | Does the claimed artifact exist? |
| Contains | Does it contain the required contract? |
| Matches | Does it match current repository conventions and ADRs? |
| Works | Does executable verification pass? |
| Explains | Can the next agent determine the next action? |
| Records | Is evidence attached to the Linear task, synchronized GitHub Issue, PR, or proof ledger? |

## Required Gates

Run the narrowest useful gate first, then `python3.11 scripts/agent_harness.py verify --mode full` before handoff.

| Claim | Additional gate |
| --- | --- |
| Documentation or Matt assets changed | `python3 scripts/verify_project_normalization.py` |
| Release claim changed | `python3 scripts/verify_release_closure.py` |
| Installed app behavior changed | Packaged-App Smoke and Visual GUI Proof under the resource lock |
| Swift/macOS behavior changed | targeted Swift test, then broader Swift tests |

## Feedback Packet

Record exact Evidence, Gap, Constraint, Next action, Recheck command, and Stop rule. Do not respond to failure with an unchanged retry.

## Stop Rules

Stop and route to `needs-info` or `ready-for-human` before credentials, Apple account or notarization actions, destructive user-data operations, accepted ADR replacement, broad unrelated refactors, or a Distribution Ready claim based only on Local Release Ready evidence. These are External Blocker or Owner-Controlled Input states, not failed code work.

## Record Keeping

- Record the PR or no-change result, manifest path, commands, results, and remaining human gate in the GitHub-synced Linear thread so both task surfaces receive it.
- Update Context only when vocabulary changed; add an ADR only for hard-to-reverse decisions with real alternatives.
- Keep generated proof under `logs/diagnostics/` or `logs/harness/`; CI uploads it as an artifact.
- Finish at `ready-for-human`; do not merge or close automatically.
