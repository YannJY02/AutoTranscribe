# InsightKit AI product-manager case: from parity intent to a bounded iterate decision

## Problem and job to be done

- [Accepted intent] InsightKit is a personal macOS meeting assistant that turns live or imported media into searchable, reviewable, and exportable Meeting Assets. ([Sources: product context](../../contexts/product/CONTEXT.md))
- [Accepted intent] The job to be done is to move either a Live or Import session, using Local or Cloud Smart Minutes, through saved Record, Record Review, Smart Minutes review, and export while retaining source provenance and reviewability. ([Sources: GH-56](https://github.com/YannJY02/AutoTranscribe/issues/56), [GH-57](https://github.com/YannJY02/AutoTranscribe/issues/57))
- [Inference] The product-management problem was not merely feature parity; it was whether parity could be demonstrated as a complete, privacy-safe lifecycle with inspectable failure and rollback evidence. ([Sources: GH-56](https://github.com/YannJY02/AutoTranscribe/issues/56), [GH-73](https://github.com/YannJY02/AutoTranscribe/issues/73))

## Constraints and prioritization

- [Accepted intent] The cohort was bounded to one owner on one reference Mac, with four serialized segments and no automatic conversion of measurements into thresholds. ([Sources: GH-56](https://github.com/YannJY02/AutoTranscribe/issues/56), [pilot manifest](../../../pilots/gh-73-owner-lifecycle.json))
- [Accepted intent] Meeting content, participant identity, raw media, transcript and Smart Minutes text, credentials, provider bodies, and private local paths are outside the publishable artifact boundary. ([Sources: GH-74 contract](https://github.com/YannJY02/AutoTranscribe/issues/74))
- [Inference] The sequence prioritized claim integrity over coverage: exact-build provenance, serialized attempts, bounded reconciliation, and rollback make a partial outcome inspectable even though they do not make it successful. ([Sources: build proof](../../../pilots/evidence/GH-73/build-proof.json), [pilot manifest](../../../pilots/gh-73-owner-lifecycle.json))

## Artifact chain and design evidence

- [Observed] The inspectable chain is accepted scope in GH-56/GH-57, implementation and pilot contract in GH-73, exact build and source attestation, attempt proof, analytics/diagnostic readbacks, rollback proof, evidence ledger, and this outcome review. ([Sources: GH-56](https://github.com/YannJY02/AutoTranscribe/issues/56), [GH-57](https://github.com/YannJY02/AutoTranscribe/issues/57), [PR 92](https://github.com/YannJY02/AutoTranscribe/pull/92), [outcome review](outcome-review.md))
- [Observed] The only visible design evidence in the merged pilot is a privacy-safe synthetic screenshot of the Live/local review surface, referenced by hash from the proof; it is behavior evidence, not evidence of user preference. ([Sources: live/local proof](../../../pilots/evidence/GH-73/live-local-proof.json))
- [Observed] The Linear project resources link the reverse-engineered `Current Journey — FigJam`; it supplies journey-design provenance for this case, but it is not pilot behavior, user feedback, or design approval evidence. ([Sources: FigJam journey](https://www.figma.com/board/lW9KVQ5QqWaJaKUkV5QwBr/InsightKit-Current-Journey?node-id=0-1), [YAN-46 design package](https://linear.app/yannjy/issue/YAN-46), [Linear project](https://linear.app/yannjy/project/insightkit-autotranscribe-a2f3a38cd145))
- [Observed] Task truth is linked through the canonical Linear project and the YAN-55 pilot ledger record; repository delivery is linked through GitHub issues, PR 92, and checked-in evidence. ([Sources: Linear project](https://linear.app/yannjy/project/insightkit-autotranscribe-a2f3a38cd145), [YAN-55](https://linear.app/yannjy/issue/YAN-55), [evidence ledger](../../../pilots/evidence/GH-73/evidence-ledger.json))

## Implementation, evaluation, and pilot

- [Observed] The implementation established consent-default-off telemetry, an explicit enable-then-disable plan, aggregate analytics queries, bounded diagnostic metadata, exact-build attestation, and deterministic rollback verification. ([Sources: pilot manifest](../../../pilots/gh-73-owner-lifecycle.json), [rollback proof](../../../pilots/evidence/GH-73/rollback-proof.json))
- [Observed] Evaluation infrastructure read back 14 matched prerequisite-synthetic analytics events, one bounded Sentry diagnostic event, and a four-item Langfuse SDK experiment with nine named scores. ([Sources: PostHog readback](../../../pilots/evidence/GH-73/posthog-readback.json), [Sentry readback](../../../pilots/evidence/GH-73/sentry-readback.json), [Langfuse readback](../../../pilots/evidence/GH-73/langfuse-readback.json))
- [Unknown] Those evaluation artifacts do not establish a quality threshold, production telemetry, a product success rate, or external-user usefulness. ([Sources: pilot manifest](../../../pilots/gh-73-owner-lifecycle.json), [pilot outcome](../../../pilots/evidence/GH-73/pilot-outcome.json))
- [Observed] The pilot produced one failed synthetic Live/local route and no observations for Live/cloud, Import/local, or Import/cloud; its outcome is partial and explicitly disclaims production readiness. ([Sources: pilot outcome](../../../pilots/evidence/GH-73/pilot-outcome.json), [live/local proof](../../../pilots/evidence/GH-73/live-local-proof.json))

## Results and product decision

- [Observed] The attempt proved the app could start the synthetic route and present Smart Minutes review, but it did not prove Record save, reopen, export, or observed local analysis mode. ([Sources: live/local proof](../../../pilots/evidence/GH-73/live-local-proof.json))
- [Observed] The safety dry-run verified the frozen app target and passed tests for consent revocation, deterministic queue-purge readback, Sentry disablement, and evidence preservation; it did not act on or read back the current owner runtime. ([Sources: rollback proof](../../../pilots/evidence/GH-73/rollback-proof.json))
- [Inference] The evidence supports **iterate**: repair or explain the failed route, then rerun the same bounded segment matrix before any rollout, parity, or portfolio-impact claim. ([Sources: outcome review](outcome-review.md), [pilot manifest](../../../pilots/gh-73-owner-lifecycle.json))
- [Unknown] Current owner-runtime consent and queue state, baseline deltas, segment parity, user value from owner or external-user observation, market demand, retention, willingness to pay, and public distribution readiness remain unknown. ([Sources: rollback proof](../../../pilots/evidence/GH-73/rollback-proof.json), [pilot outcome](../../../pilots/evidence/GH-73/pilot-outcome.json), [ADR 0003](../../adr/0003-separate-local-readiness-from-public-distribution-readiness.md))

## Lessons

- [Inference] A failed but source-bound pilot can be a useful product result when it narrows uncertainty without converting tooling evidence into user-outcome evidence. ([Sources: evidence ledger](../../../pilots/evidence/GH-73/evidence-ledger.json), [pilot outcome](../../../pilots/evidence/GH-73/pilot-outcome.json))
- [Inference] Segment labels are only meaningful when the analysis path itself is observed; naming an attempt Live/local did not prove local analysis mode in this run. ([Sources: live/local proof](../../../pilots/evidence/GH-73/live-local-proof.json))
- [Inference] Analytics reconciliation, diagnostic capture, Eval scores, and rollback are guardrails around a product decision; none substitutes for completion of the Meeting Asset workflow. ([Sources: pilot manifest](../../../pilots/gh-73-owner-lifecycle.json), [GH-57](https://github.com/YannJY02/AutoTranscribe/issues/57))
- [Future work] The next evidence increment is one diagnosed and rerun four-segment lifecycle with per-stage, analysis-mode, privacy, and guardrail results; public case publication remains a separate human gate. ([Sources: outcome review](outcome-review.md), [GH-74 contract](https://github.com/YannJY02/AutoTranscribe/issues/74))
