# Saved transcript timestamps must use the final media timeline

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During issue 24 diagnosis, the owner clarified that the user does not care when the app processed a transcript segment. The user cares whether the transcript text, audio, and video line up perfectly in the completed review media.

The current Live Workspace path can save Transcript Segments that were produced from live audio chunks. Those chunk timestamps are useful during recording, but they are not guaranteed to be the same as the final media playback timeline.

## What I expected

For saved Records, Transcript Segment timestamps should be derived from the final `recording.*` media file. A timestamp such as `00:22` should mean "play the saved media at 00:22 and hear this text there."

Live transcript text may remain a draft while recording is active, but saved `transcript.json`, Smart Minutes evidence spans, Timeline Beats, and click-to-seek links should use media-timed transcript data.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open Live Workspace.
3. Capture a session with audio plus camera or screen.
4. Stop the session and let the app save the Record.
5. Reopen the Record or Smart Minutes review.
6. Click transcript rows, Timeline Beats, or Evidence Spans.
7. Compare the clicked timestamp to the actual sound heard in the saved media.

## Additional context

This issue reframes issue 24 from a narrow audio/video synchronization bug into the stronger record rule: final transcript timestamps must be media timestamps.

ADR: `docs/adr/0005-use-final-media-timeline-for-saved-transcript-timestamps.md`.

## Comments

### 2026-06-26 - Code fix implemented for owner retest

Status changed to `ready-for-human`.

Diagnosis:

- Live Transcript Deltas are produced from live audio chunks and use chunk-derived `start_ms` / `end_ms`.
- `saveToRecords` previously serialized the current `transcriptSegments` directly into `records.save`.
- That meant `transcript.json` could preserve live processing timing rather than the final media playback timeline.

Fix:

- Added `asr.transcribe_media` to the Sidecar so the app can ask the runtime to transcribe a completed media file.
- Added `transcript.replace` so the runtime transcript store can be replaced by media-timed Transcript Segments before Final Insight Generation.
- Added Swift RPC support for `asrTranscribeMedia(mediaPath:source:)`.
- Updated Live record saving so, when a final media URL exists, saved Transcript Segments are replaced by the final media transcription result before `records.save`.
- Updated Final Insight Generation so Smart Minutes are generated after the runtime transcript store has been replaced with the final media transcription result.
- Cached the media transcription result by media path so saving again after Final Insight Generation does not repeatedly transcribe the same final media.
- If final media transcription fails, save the Record with media and notes but an empty transcript instead of falling back to live chunk timestamps.

Proof:

- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testSaveToRecordsReplacesLiveChunkTranscriptWithFinalMediaTranscript` failed because `saveToRecords` persisted stale live chunk timestamps.
- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testBuildFinalInsightReplacesRuntimeTranscriptWithFinalMediaTranscriptBeforeGeneratingMinutes` failed because `insight.build_final` ran before replacing the runtime transcript store.
- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testSaveToRecordsDoesNotFallbackToLiveChunkTranscriptWhenFinalMediaTranscriptionFails` failed because a media transcription error blocked Record saving instead of preserving media/notes without stale timestamps.
- RED: `python -m pytest tests/test_session_handler.py -q` failed because `SessionHandler` had no `transcript_replace` operation.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testSaveToRecordsUsesPreparedLiveRecordingAsMediaSource --filter LiveSessionViewModelTests/testSaveToRecordsReplacesLiveChunkTranscriptWithFinalMediaTranscript --filter LiveSessionViewModelTests/testSaveToRecordsDoesNotFallbackToLiveChunkTranscriptWhenFinalMediaTranscriptionFails --filter LiveSessionViewModelTests/testBuildFinalInsightReplacesRuntimeTranscriptWithFinalMediaTranscriptBeforeGeneratingMinutes --filter LiveSessionViewModelTests/testSaveToRecordsPersistsGeneratedLiveInsightPackageForRecovery --filter InsightRPCClientFinalInsightTimeoutTests --filter WorkflowCoordinatorTests`, 11 tests, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testBuildFinalInsightReplacesRuntimeTranscriptWithFinalMediaTranscriptBeforeGeneratingMinutes`, 1 test, 0 failures.
- Sidecar gate: `python -m pytest tests/test_asr_dispatcher.py -q`, 7 tests, 0 failures.
- Runtime transcript gate: `python -m pytest tests/test_session_handler.py -q`, 9 tests, 0 failures.
- Capability gate: `python -m pytest tests/test_sidecar_single_instance.py -q`, 2 tests, 0 failures.
- Full Swift gate: `swift test --package-path macos/InsightKitApp`, 165 tests, 0 failures.
- Full Python gate: `python -m pytest -q`, 222 tests, 0 failures, 1 warning.
- Sync gate: `bash scripts/sync_insightkit_app.sh`, installed build `20260626160503` to `/Users/yann.jy/Applications/InsightKit.app`.

Owner retest:

- Use a new Live Workspace capture with system audio or mixed audio and visual media.
- Stop the session, let the Record save, then generate Smart Minutes if desired.
- Reopen the saved Record and click transcript rows / Timeline Beats.
- Confirm each timestamp points to the matching spoken audio in the saved media.

### 2026-06-26 - Owner retest failed when stopping before final transcription completed

Status changed to `ready-for-agent`.

Observed in installed build `20260626160503`:

- Stopping a Live Workspace session before Final Media Transcription completed could show `最终回看资料转写失败；已保留媒体和笔记，本次转写需要重新生成。`
- The user expectation is that Stop ends capture, but does not abandon already captured audio or the final media transcription pass.
- The app should keep working in the background, then clearly tell the user that it is processing the final transcript.

Diagnosis:

- `stopLiveSession` set `isRunning` to false before draining every queued Live Transcript Delta chunk.
- `pumpChunkQueueIfNeeded` treated `isRunning == false` as a signal to drop queued chunks, even when those chunks had already been captured before Stop.
- `finalTranscriptSegmentsForRecord` treated the first `asr.transcribe_media` error as a terminal failure, so a transient final-media readiness error could save an empty transcript immediately.

Fix:

- Added a stop-drain state so captured queued chunks continue processing after Stop instead of being cleared.
- Added a visible status message: `录制已停止，正在处理剩余音频并生成最终转写，请保持应用打开。`
- Added Final Media Transcription retry delays before the app gives up on a transient `asr.transcribe_media` failure.
- Kept the finalization progress state active until Record saving finishes, so the UI can show that the app is still working.

Proof:

- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testStopLiveSessionDrainsQueuedChunksBeforeSavingRecord` failed because queued chunks were not processed after Stop.
- RED: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testSaveToRecordsRetriesFinalMediaTranscriptionBeforeSavingEmptyTranscript` failed because `LiveSessionViewModel` had no final media transcription retry behavior.
- GREEN: `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests/testStopLiveSessionDrainsQueuedChunksBeforeSavingRecord --filter LiveSessionViewModelTests/testSaveToRecordsRetriesFinalMediaTranscriptionBeforeSavingEmptyTranscript --filter LiveSessionViewModelTests/testSaveToRecordsDoesNotFallbackToLiveChunkTranscriptWhenFinalMediaTranscriptionFails --filter LiveSessionViewModelTests/testSaveToRecordsReplacesLiveChunkTranscriptWithFinalMediaTranscript --filter LiveSessionViewModelTests/testBuildFinalInsightReplacesRuntimeTranscriptWithFinalMediaTranscriptBeforeGeneratingMinutes`, 5 tests, 0 failures.
- GREEN: `swift test --package-path macos/InsightKitApp`, 167 tests, 0 failures.

### 2026-06-26 - Stop-before-final-transcription follow-up installed

Status changed to `ready-for-human`.

Installed build: `20260626163854`.

Additional proof:

- Sync gate: `bash scripts/sync_insightkit_app.sh`, Swift and Python gates passed, installed to `/Users/yann.jy/Applications/InsightKit.app`.
- Latest sync proof: `logs/workflow/latest_sync.json`.

Owner retest:

- Start a new Live Workspace session.
- Speak long enough that live transcription may still be catching up.
- Click Stop before the final media transcription appears fully complete.
- Expected: the app should show that it is processing remaining audio / final transcript in the background, then save a Record whose transcript is based on the final media timeline.
- Not expected: immediate `最终回看资料转写失败；已保留媒体和笔记，本次转写需要重新生成。`

### 2026-06-26 - Owner retest passed

The owner confirmed the stop-before-final-transcription follow-up is resolved in the installed app.

### 2026-06-27 - Owner retest reconfirmed

The owner reconfirmed issue 26 is resolved. No further agent action is required unless a new saved Record shows transcript timestamps drifting away from the final media timeline.
