# InsightKit product and delivery map

Audit date: 2026-09-05. Starting repository baseline: `2347654` on `main`.

This map explains the product, its delivery system, and the evidence still needed. It is a dated orientation document. [Linear](https://linear.app/yannjy/project/insightkit-autotranscribe-a2f3a38cd145) owns current requirements, priorities, and task status; live runtime readbacks and exact-build proof establish what is running and working. The current foundation work is linked through [YAN-63](https://linear.app/yannjy/issue/YAN-63).

## Product and delivery target

InsightKit is a personal, local-first macOS meeting assistant. Its main flow is:

**Live capture or imported media → transcript and Smart Minutes → saved Record → reopened Record Review → export.**

Local and Cloud Smart Minutes are separate analysis modes that must be observed explicitly. Record Review, notes, speaker edits, media playback, and export should agree on the same saved Meeting Asset. See the [product model](../contexts/product/CONTEXT.md), [app workflows](../contexts/macos-app/CONTEXT.md), and [accepted lifecycle intent](../outcomes/GH-74/outcome-review.md).

The delivery target also includes the infrastructure: an authorized task can reach an isolated implementation, appropriate verification, an inspectable PR, and human product review; observed product failures can feed the next improvement. The app and this repeatable delivery loop both need demonstrations. Infrastructure evidence should show what the system actually completed and where intervention was needed.

## Where to find authoritative information

| Question | Start here | Evidence boundary |
| --- | --- | --- |
| What should we build next, and why? | [Linear project](https://linear.app/yannjy/project/insightkit-autotranscribe-a2f3a38cd145), [task rules](../agents/issue-tracker.md) | Current accepted scope and detailed status live in Linear. This map adds no task queue. |
| What do the product concepts mean? | [Context map](../../CONTEXT-MAP.md), [product model](../contexts/product/CONTEXT.md), [ADRs](../adr/) | Context files are shared vocabulary, not a complete requirements specification or proof of usability. ADRs record implementation decisions and their reasons. |
| Where is the implementation? | [Native app](../../macos/InsightKitApp/), [Python runtime](../../insightkit/), [sidecar entry](../../scripts/insight_sidecar.py) | Code presence describes the implementation surface. A working installed build needs separate proof. |
| What must survive an implementation change? | [Meeting Asset definitions](../contexts/product/CONTEXT.md), [record storage decision](../adr/0004-use-local-record-folders-with-runtime-record-writer.md), [media timeline decision](../adr/0005-use-final-media-timeline-for-saved-transcript-timestamps.md) | Preserve accepted user behavior, saved-record compatibility, provenance, and explicit degraded states. A historical layout or module name is not automatically a user requirement. |
| What was delivered and verified? | [GitHub PRs](https://github.com/YannJY02/AutoTranscribe/pulls), [Actions](https://github.com/YannJY02/AutoTranscribe/actions), [product-proof contract](../product-proof/README.md), [evidence schema](../evidence/README.md) | Check the commit, build, scenario, result, and retained artifacts. A ticket status or passing process alone does not prove the product claim. |
| What is running now? | [Harness runtime-status entry](../agents/harness.md), local `logs/symphony/runtime-status.json`, installed-app build/source attestation, and the live Symphony queue | Runtime status is a freshness/configuration observation. A configured transport, evidence file, or empty queue does not establish telemetry delivery or workflow completion. |
| Which old material is reusable? | [Legacy manifest](../Legacy/matt-workflow-library/manifest.md), [historical owner QA](../../.scratch/manual-qa-2026-06-25/PRD.md) | Reuse original needs, observed failures, and compatible behavior contracts. Old task states, build results, exact visual styling, and release claims remain historical. |

## What the available evidence supports

| Area | Supported by the inspected material | Still to establish |
| --- | --- | --- |
| Product implementation | Native app, local runtime, Record/Smart Minutes model, review/export surfaces, and verification entry points exist in the repository. | A current installed build completing the chosen real user workflow, including the actual analysis mode. |
| Earlier user feedback | Historical owner QA records specific problems and local retest outcomes, including [usable live notes](../../.scratch/manual-qa-2026-06-25/issues/04-live-notes-entry-is-not-discoverable-or-usable.md) and [consistent review/export assets](../../.scratch/manual-qa-2026-06-25/issues/33-record-review-and-smart-minutes-should-share-canonical-meeting-asset-source.md). | Those old-build observations do not establish current behavior or overall visual acceptance. |
| Lifecycle pilot | [GH-74 outcome review](../outcomes/GH-74/outcome-review.md) records one failed synthetic Live/local route and three unobserved segments. | Save, reopen, export, observed local analysis, and the other Live/Import × Local/Cloud paths were not demonstrated by that pilot. Its decision is **Iterate**. |
| Telemetry and AI evaluation | [Pilot readbacks](../../pilots/evidence/GH-73/) include 14 prerequisite-synthetic PostHog events, a bounded Sentry event, and a four-item Langfuse SDK experiment. | These are infrastructure evidence, not events proving the failed pilot completed, production telemetry, an accepted quality threshold, or user value. A real product attempt must be linked to its own observations. |
| Visual and media quality | [Reference output patterns](../Legacy/matt-workflow-library/converted-assets/product/reference-output-patterns.md) preserve useful structure; the [claim matrix](../product-proof/claim-matrix.json) names visible and manual-only claims. | Reference screenshots and reverse-engineered journeys do not prove design preference. The matrix's saved-media readability and permission-guidance judgments remain `unobserved`. |

The starting 2026-09-05 audit also found a deployment/verification gap: the inspected runtime was at `19d19e4`, behind repository `main` at `2347654`; [main CI](https://github.com/YannJY02/AutoTranscribe/actions/runs/33935889396) reported 66 lifecycle-test failures involving historical pilot fixtures. These are baseline observations to supersede with linked repair and runtime evidence, not permanent product status or a reason to discard the existing assets. The current repair must preserve the meaning of historical proof while restoring checks for new delivery.

## Next evidence gates

These gates describe the next useful proof, not an independently scheduled backlog. Scope and ordering remain in the accepted Linear task.

1. **Restore a trustworthy delivery baseline.** Resolve the lifecycle-fixture failures with focused regression evidence, then obtain the applicable current-commit CI result. Keep historical and new handoff contracts distinguishable; passing archived proof must not authorize a new delivery.
2. **Identify the system under test.** Record the installed build and source revision, controller freshness, selected analysis mode, and telemetry consent/transport state without exposing credentials. Reconcile any intended deployment with its readback before judging behavior.
3. **Observe one complete product attempt.** On the chosen build and scenario, follow capture/import through Smart Minutes, save, reopen, and export. Record each actual result, timings, failures, and content-quality checks. Use the [product-proof ladder](../product-proof/README.md) and [shared macOS resource lock](../agents/harness.md) where applicable. Expand segment coverage after the first path is understood.
4. **Demonstrate one evidence-driven improvement.** Connect the attempt's funnel/timing evidence, relevant diagnostic errors, and approved AI-quality samples to one diagnosed problem. Make a bounded repair and compare the same scenario before and after. Record what changed, what remained unknown, and the user's usability/quality judgment. This demonstrates the infrastructure and the product together; further product shaping can follow from the result.

For workflow mechanics, use the [loop guide](../agents/loop-engineering.md) and [tool boundaries](../agents/tool-boundaries.md). Preserve useful evidence in its existing location and link it from the task and PR; additional documents or services should answer a concrete unresolved question.
