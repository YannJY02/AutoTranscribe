---
name: promote-feedback
description: Turn repeated review or bug feedback into one durable repository guardrail without duplicating rules or broadening the task.
---

# Promote feedback

Use this when a maintenance issue or repeated failure asks the repository to learn.

Inspect the bounded evidence named by the issue. Promote at most one material invariant into exactly one surface:

- Docs: a stable fact or decision the agent must understand.
- Skill: a non-obvious procedure or tool choice.
- Lint: a cheap deterministic rule with low false-positive risk.
- Structural Test: an executable architecture or behavior contract.

Search for an existing rule first and strengthen it at its authoritative location. Do not encode one-off preferences, copy review prose, add a dependency, or create a new abstraction. If the evidence is not repeated or material, leave a no-change result.

Run the narrowest regression check and `python3.11 scripts/agent_harness.py verify --mode full`. Record the evidence, selected surface, and why the other surfaces were unnecessary.
