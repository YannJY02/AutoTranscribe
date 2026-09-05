# AI product iteration

The AI owns discovery, diagnosis, a bounded repair, verification, and the next action within the owner's authorized product scope. It should use the current app and requirements to find friction, rather than wait for a fully specified bug report. Portfolio writing follows demonstrated product improvements and real use; it is not the current delivery objective.

Linear remains the task and priority source. GitHub owns commits, PRs, CI, and delivery evidence. Symphony executes accepted tasks through the existing protected controller. The observation packet below is disposable evidence for the model, not another task queue or a deterministic product manager.

## First pass

Run from the chosen checkout:

```bash
python3.11 scripts/agent_harness.py doctor --json
python3.11 scripts/product_iteration.py observe
```

The observer reads `agent_harness.py runtime-status`, the last ten main-branch CI runs, and any explicitly selected existing evidence ledgers. It does not launch the app, read meeting content, send telemetry, write to Linear/GitHub, or change local files by default. It discards arbitrary error text and private runtime paths. CI is attached only to a remotely observed main revision. A pending/cancelled run, unavailable API, missing ledger, or historical green run cannot become a current pass or a product failure.

To retain a new observation or include a prior ledger, opt in explicitly:

```bash
python3.11 scripts/product_iteration.py observe \
  --ledger pilots/evidence/GH-73/evidence-ledger.json \
  --output logs/product-iteration/first-observation.json
```

Choose a fresh output name each time; existing packets are never overwritten. The existing evidence-ledger schema validates ledger input, then only metadata is projected. `freshness` is a configurable 24-hour observation window (`--max-age-hours`), not a product threshold. `revision_matches_checkout` compares recorded commit identity, not uncommitted changes or artifact execution. Inspect `checkout_dirty` and the actual build before trusting a comparison. File presence does not establish telemetry delivery, successful use, or quality. Historical evidence is context until reproduced on the selected version.

The observer has no credentials of its own. Under the restricted Symphony worker, missing GitHub access becomes `unavailable`; it is not a reason to copy controller credentials into that worker. The coordinating Codex task can collect the read-only packet before dispatch and link bounded evidence in the existing task contract.

## Observation → candidate → task → proof → next action

1. **Observe.** Read the packet, current Linear priorities, the [Context Map](../../CONTEXT-MAP.md), and the relevant accepted requirements. Check the source revision of CI, the installed app, and retained proof. Consult existing issues before creating anything. An unavailable source means incomplete coverage; retry only when there is a changed condition or a useful alternate source.
2. **Choose one candidate.** The packet's questions are starting points for AI investigation. Inspect the referenced failure, or explore one complete user journey when infrastructure is healthy. Reproduce a concrete symptom, describe its user impact, and distinguish observation from a cause hypothesis. Do not generate an issue for each metadata warning. A running CI check can simply be awaited.
3. **Use the existing task.** Continue a matching Linear issue; otherwise create one within the authorized initiative using Goal, Context, Boundary, Acceptance, Verification, Resource class, Blockers, and Human gates. Include the observation/build, reproduction, one intended improvement, and the comparison that will establish success. Native sync supplies the GitHub mirror. An unattended issue must pass `issue-preflight` before `ready-for-agent`; do not put speculative findings into completed status. AI may update routine task scope and evidence within the accepted objective without another permission round.
4. **Repair and prove.** Preserve before evidence, implement the smallest change that resolves the diagnosed cause, and compare the same journey afterward on an identified build. Run the narrow behavioral/data/privacy checks that protect the change, followed by the diff-selected full Harness and independent review required for handoff. Keep the user's existing work and Records intact. Package/GUI/capture/performance work uses the installed-app resource lock. Commit/push and open the PR within existing authorization; the protected Symphony controller handles those writes for an unattended worker.
5. **Record and continue.** Attach source/build/scenario, commands, before/after result, actual limitations, and the next bounded action to the existing Linear/GitHub thread and evidence ledger as appropriate. Run `observe` again to refresh infrastructure signals. Compare the result with the previous observation and task outcome. Continue an unresolved failure with new evidence, select another accepted journey, or report that the current slice needs human acceptance. Never infer successful user value from a green CI or a completed task label.

Routine reproduction, code repair, relevant tests, review fixes, and PR preparation are already within authorized delivery. Ask the owner only for genuinely missing credentials/account access, destructive changes to user data, a material product-direction or accepted UX tradeoff not resolved by existing requirements, and merge/public release. Current explicit authorization overrides older blanket intake requirements. Do not make every aesthetic choice, minor implementation decision, or repeated test a human gate.

## Use the actual interface to discover problems

CUA is the active exploration tool for the native app: inspect a window, follow Live or Import through Record Review and export, and use representative synthetic data to uncover confusing states or interaction failures. Read CUA's returned API documentation and inspect the actual UI before each action; a model's description of a proposed interface is not app evidence. Record the exact build, scenario, screenshot or observation reference, expected result, actual result, and remaining uncertainty.

CUA complements deterministic data, runtime, privacy, and regression tests. Preserve XCUITest/native-app-proof for repeatable uniquely visible acceptance where it works. CUA observations can expose product or test defects and guide a focused regression; they do not silently replace a required proof rung. Do not claim a redesigned screen, revised architecture, or new model is better until the relevant before/after comparison is complete. See [product proof](../product-proof/README.md) and [native-app-proof](../../.agents/skills/native-app-proof/SKILL.md).

For an interface complaint, compare visible alternatives against the same content and user task. For slowness, measure the actual interaction before attributing it to architecture. For Smart Minutes, inspect fidelity against source evidence; schema validity and a generated summary are insufficient. If the worker lacks GUI permission or has no usable graphical session, it should leave a precise, bounded request for the coordinating task rather than repeatedly attempt a blind interaction.

## Continuous reuse

The coordinating Codex task or its authorized heartbeat reads fresh signals, checks the existing Linear frontier, and advances one useful in-scope investigation at a time. Symphony continues executing accepted tasks. Keep unchanged, non-actionable observations quiet; notify on a material improvement, a new failure, completion, or owner action. A notification is not a substitute for updating the linked task's evidence. The observer itself is never a scheduler, external writer, or source of product priorities.

Use `.codex/symphony.config.toml` for the worker model: GPT-6 Astra with `high` reasoning. The local model catalogue supports that combination; apply a different effort only when the task warrants it. Preserve the worker/controller privilege boundary and verify the live service configuration after an authorized restart—editing a file alone does not prove that a resident agent changed models.
