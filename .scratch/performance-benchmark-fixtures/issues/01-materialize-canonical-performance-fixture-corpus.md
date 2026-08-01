# Materialize the Canonical Performance Fixture Corpus

Status: ready-for-human

## Parent

`.scratch/performance-benchmark-fixtures/PRD.md`

## External Ticket

<https://github.com/YannJY02/AutoTranscribe/issues/11>

## What to build

Materialize and freeze every synthetic media, reference transcript, Record
Folder collection, and replay input required by the canonical installed-app
benchmark protocol before baseline tickets run.

## Acceptance Criteria

- [x] `short-zh`, `short-en`, and `short-mixed` are exact 5-minute M4A fixtures.
- [x] `long-mixed` is an exact 60-minute M4A fixture.
- [x] Mixed fixtures have MP4 companions with the same AAC packet stream.
- [x] Reference transcripts are synthetic, timed, speaker-labelled, and include Smart Minutes decisions, actions, and evidence spans.
- [x] Every reference and media asset has a frozen path, duration, format, codec, byte size, and SHA-256 pin.
- [x] Complete 100 and 1,000 Record Folder collections are generated with seed `20260801`.
- [x] Generator revision/version and full inventory hashes are frozen.
- [x] Keyboard, pointer, scroll, resize, navigation, search, playback, seek, and recovery inputs are frozen.
- [x] Private Record Folder roots, credentials, and private meeting content are excluded.
- [x] Media and generated Record Folders remain outside Git.
- [x] Reproduction/acquisition and verification instructions are linked from the canonical protocol.
- [x] Every pinned hash, duration, format, Record Folder parse, inventory, trace, and safety boundary passes verification.

## Constraints

- Matt workflow remains authoritative; non-Matt skills only assist implementation.
- Do not collect baseline results or implement optimizations in this issue.
- Do not read either sandboxed or unsandboxed private Record Folder root.
- Do not commit generated media.

## Verification Plan

- Run the focused generator tests and coverage.
- Run the corpus verifier against the frozen manifest.
- Independently parse every Record Folder with Swift Foundation.
- Run project normalization and the full Swift suite.
- Run the full Python suite and distinguish known baseline failures.
- Run Standards and Spec review against the issue and protocol.

## Blocked by

None. GitHub issue #3 completed the canonical benchmark protocol. This issue
blocks baseline tickets #4-#9.

## Comments

### 2026-08-01 - Codex

Implemented and verified.

- Frozen manifest: `docs/performance/fixture-corpus-manifest.json`.
- Reproduction and verification: `docs/performance/fixture-corpus.md`.
- Generator and spec: `scripts/performance_fixture_corpus.py` and
  `docs/performance/fixture-corpus-spec.json`.
- External corpus root:
  `/Users/yann.jy/Library/Application Support/InsightKit/BenchmarkFixtures/v1`.
- Durable proof:
  `logs/diagnostics/2026-08-01/performance-fixture-corpus/proof.json`.
- Focused tests pass 8/8; generator coverage is 88%.
- Corpus verification passes 6/6 media assets and 1,100/1,100 Record Folders.
- Swift Foundation independently parses 1,100/1,100 Record Folders.
- Full Swift suite passes 264/264; normalization reports 0 findings.
- Full Python suite reports 234 passed and the same 18 pre-existing failures
  recorded on the preceding benchmark-protocol baseline.
- All implementation and Spec review findings were fixed before closure.
- Process caveat: the external issue was claimed before its local `.scratch`
  mirror existed. The mirror and proof were added during review; future tickets
  must be promoted locally before implementation starts.

No baseline measurement or optimization was performed.
