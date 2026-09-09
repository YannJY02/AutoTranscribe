# Local summary screen v1

`local-summary-v1` freezes eight requests for YAN-77 before model generation.
Every input is synthetic and may be published. No private meeting, recording,
previous summary, ASR output, model output, or production configuration is used
to define these expectations. This is a fidelity and latency screen, not a
release gate or evidence of live meeting quality.

## Frozen requests

Run in the listed order, at most once each in the first screen (eight model
generation requests total). A parse failure or truncated response consumes its
request; it does not authorize a ninth retry.

| # | Case ID | Mode | Complete visible segments | Visible end | Main distinction |
| --- | --- | --- | --- | --- | --- |
| 1 | `zh-release-decision-final` | final | 3 legacy rows | 15.0 s | Blue theme decision, 乙, Friday; no launch/budget approval |
| 2 | `en-launch-plan-final` | final | 3 legacy rows | 13.2 s | Offline pilot, Blair, Friday; no deployment/customer approval |
| 3 | `mixed-design-review-final` | final | 3 legacy rows | 13.6 s | Local-first decision, B, Friday; review date remains unknown |
| 4 | `insufficient-transcript-final` | final | 1 legacy row | 1.2 s | Sound check only; empty decisions/actions are valid |
| 5 | `bilingual-plan-correction-prefix-01` | live | story s01–s02 | 28 s | Cloud proposal unapproved; risk list unassigned/undated |
| 6 | `bilingual-plan-correction-prefix-02` | live | story s01–s04 | 64 s | Offline demo decided; checklist Mei/Friday; other dates unknown |
| 7 | `bilingual-plan-correction-prefix-03` | live | story s01–s06 | 110 s | Checklist corrected to Ren/Monday; no upload/production approval |
| 8 | `bilingual-plan-correction-final` | final | story s01–s06 | 110 s | Same full transcript through the product final path |

The first four inputs reference the existing
[`smart-minutes-v1` source](../../smart_minutes/v1/dataset.json), without copying
its transcript into this dataset. Its exact file SHA256 is frozen per reference:
`b6a86ef6261f8e5777771b3323ec2e4e3e9225fd35d9865adb011d7a7854d0b2`.
These legacy rows have no native segment IDs. The loader explicitly assigns
`<source-case-id>:s01`, `:s02`, etc. in source-row order and verifies that every
row is included. They are adapter IDs, not claimed IDs from a recording.

The new Harbor story is authored here once, with explicit stable segment IDs.
Each live request includes the complete cumulative prefix; later text is not
visible to an earlier request. The loader rejects skipped/reordered segments,
future evidence references, changed legacy source hashes, and incomplete final
inputs. All segments end within 120 seconds. There is no previous-summary input
or recursive summarization. The runner must submit only the resolved transcript
and the unchanged product prompt/schema; expectations and hidden suffixes are
review data, never prompt data.

`load_contract()` returns `dataset_version`, a canonical SHA256 over the frozen
manifest plus resolved inputs, `max_generation_requests`, and eight `cases`.
Each case includes `id`, `mode`, `language`, `source`, `safety`,
`stable_segment_ids`, `transcript`, `transcript_sha256`, `visible_end_ms`, and
field-bound `expectations`.

## Assessment interface and interpretation

```python
from scripts.local_summary_assessment import (
    load_contract, assess_payload, assess_pair, make_review_template,
)

contract = load_contract()  # optional Path to dataset.json
case = contract["cases"][0]
checks = assess_payload(case, raw_payload, stage="raw")
review = make_review_template(case, raw_payload, stage="raw")
both = assess_pair(
    case, raw_payload=raw_payload, postprocessed_payload=postprocessed_payload,
)
```

The output contract remains the product's existing `InsightPackageV1` seven
modules: overview, highlights, perspectives, decisions, actions, timeline, and
provenance links. This helper neither changes that schema nor repairs output.

The checks deliberately have different meanings:

- `schema` uses the complete existing product JSON schema. Missing `jsonschema`
  is `validator_unavailable`, never a weaker success. `None` means no parsed
  value is available. Arrays, scalars, incomplete objects, and truncated text
  supplied as a string fail schema; none become an empty package.
- `evidence_scope` checks positive spans that overlap visible source and stay
  inside its bounds, nonempty perspective evidence, and valid timeline times.
  A valid range does **not** establish that the cited text supports the claim.
- `field_domains` checks case-specific empty ledgers and a frozen literal
  domain for owners/deadlines. Unsupported concrete values, unknowns filled
  from the speaker/current date, and current Mei/Friday after the correction
  produce `requires_review`. `within_literal_domains` is not semantic approval:
  a correct person/date can still be attached to the wrong task. An unlisted
  equivalent expression also requires review rather than automatic rejection.
- `semantic_status` stays `not_reviewed` and `semantic_pass` stays `None`.
  Neither word matching nor translation matching assigns semantic verdicts.

`make_review_template` supplies the visible source, exact output field paths,
the frozen expected behavior, and blank verdict/rationale/evidence slots for
each checkpoint. A decision mentioned only in overview cannot count as a
ledger decision: the decision checkpoint exposes only ledger fields. Review
each expected fact and every generated claim, including claims in optional
modules. Record output paths and reasoning for `pass`, `fail`,
`not_applicable`, or `unobserved`. Required substantive facts omitted from the
corresponding module fail recall; abstention or unknown-value requirements may
be satisfied by empty arrays. Do not add entries merely to fill a module.

Review must distinguish proposals from decisions; preserve negation; attach
owners and deadlines to the correct task; leave unknowns unknown; and detect
unsupported approval, rationale, priority, completion, and external links.
Mei/Friday in explicitly superseded history is allowed after correction;
Mei/Friday as the current checklist fields is not. Friday has no absolute
calendar anchor. Required neutral schema defaults for action status/priority
are not statements that the meeting explicitly assigned a priority or status.

`assess_pair` retains deep-copied payloads, separate stage labels, hashes,
checks, and review sheets. The runner must preserve the parsed raw snapshot
**before** in-place product postprocessing, retain raw text separately, and
pass `None` if a stage did not run. A repaired postprocessed field cannot be
used as proof that the model originally emitted it correctly. This helper
cannot reconstruct raw data already overwritten by its caller.

## Evidence limits

Only four short legacy synthetic cases and one 110-second synthetic bilingual
story are covered. There is no stochastic replication, long-context test,
acoustic overlap, quiet speech, real meeting, live ASR/LS-EEND contention, or
installed-app latency result. Live-prefix calls are stable-text experiments,
not an end-to-end streaming measurement. A model must not enter production
configuration based on structural checks or this sample alone.

Regression tests target known false conclusions: cross-module matching,
speaker/date guessing, correct literals attached to the wrong task, stale
values versus historical correction, invalid evidence ranges, and raw versus
postprocessed data confusion. Run them with the repository test environment:

```sh
.venv/bin/python -m pytest -q tests/test_local_summary_assessment.py
```
