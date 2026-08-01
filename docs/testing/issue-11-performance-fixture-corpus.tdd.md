# Issue 11 Performance Fixture Corpus TDD Evidence

## Source and journeys

Source: [GitHub issue #11](https://github.com/YannJY02/AutoTranscribe/issues/11)
and the canonical installed-app benchmark protocol.

- A later baseline task can replay pinned synthetic media and interaction inputs.
- A later Records Workspace task can open deterministic collections without private data.
- A verifier can detect any content, duration, format, inventory, or safety drift before measurement.

## RED and GREEN checkpoints

| Behavior | RED evidence | GREEN evidence |
| --- | --- | --- |
| Corpus generator contract | `ab79259`; targeted pytest failed because `scripts.performance_fixture_corpus` did not exist | `1d5e19a`; 5 targeted tests passed |
| TTS span fitting | `437d6eb`; targeted pytest failed because `tempo_filter` did not exist after a real overrun | `8b1163d`; 6 targeted tests passed |
| Tool provenance | Not a logic branch; environment pins added after real materialization | `6dff252`; generator revision frozen in the manifest |

## Test specification

| Guarantee | Test or command | Type | Result |
| --- | --- | --- | --- |
| Repeated transcript segments keep deterministic offsets | `test_expand_segments_repeats_with_stable_offsets` | unit | PASS |
| Synthetic references reject private email and Record Folder text | `test_validate_reference_rejects_private_or_unbounded_content` | unit | PASS |
| Inventory hashes are root-independent and detect content drift | `test_inventory_is_root_independent_and_detects_drift` | unit | PASS |
| Generated Record Folders are deterministic, complete, and parseable | `test_record_collections_are_deterministic_complete_and_parseable` | integration | PASS |
| Every replay trace receives an absolute path, byte size, and SHA-256 | `test_scenario_parameters_pin_every_replay_input` | unit | PASS |
| Overlong TTS is fitted without truncating words | `test_tempo_filter_fits_speech_without_truncating_words` | unit | PASS |
| All frozen media, references, traces, inventories, and 1,100 Record Folders still match | `scripts/performance_fixture_corpus.py verify` | corpus integration | PASS |

## Coverage and scope

Real materialization under coverage reported 90% line coverage for
`scripts/performance_fixture_corpus.py`. The targeted suite passed 6/6. No
installed-app baseline or optimization was run; those are deliberately outside
issue #11.
