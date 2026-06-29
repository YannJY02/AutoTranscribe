# Provider non-JSON payload is shown as a realtime summary error

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

During a Live Workspace session, the realtime speech-summary banner showed a raw provider parsing error:

`Insight 侧车错误: provider returned non-JSON payload: Expecting ',' delimiter: line 42 column 32 (char 1169)`

This appeared while Transcript Segments and Smart Minutes were still visible. The same error remained visible around the post-session choice to generate Smart Minutes, and the session later reached review state with usable Smart Minutes content.

The user-facing problem is that a provider response-format failure is shown as a severe realtime speech-summary exception with raw JSON parser details, even though existing transcript and Smart Minutes evidence can still be useful.

## What I expected

When a Provider returns a non-JSON payload for Insight Refresh or Final Insight Generation, the app should preserve existing Smart Minutes and Transcript Segments, explain that the analysis provider returned an invalid response, and offer a clear retry or Settings Workspace path.

The user should not need to understand JSON parser line and column details during a live recording.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open the Live Workspace.
3. Start a live recording session and speak long enough for Transcript Segments and Smart Minutes to appear.
4. Continue recording or stop into the post-session Smart Minutes choice.
5. Observe that the realtime speech-summary banner can show a raw `provider returned non-JSON payload` error while useful transcript or Smart Minutes content is still present.

## Additional context

Reported during owner-led manual QA against installed InsightKit build `20260625103254`.

Visible session context:
- meeting ID: `live-37056EA5-F6A0-44D6-9701-7E500A5935AE`
- the error appeared during the running Session Phase around `02:48`
- the same error was still visible during the post-session Smart Minutes choice at about `3:27`
- Smart Minutes summary text remained visible
- the session later entered review state with chapter entries, transcript rows, and Smart Minutes content

This is separate from issue 09. Issue 09 tracks `insight.refresh_live` timeout recovery; this issue tracks Provider response-format failures and raw parser errors.

## Comments

### 2026-06-25 - Manual QA

The owner reported a realtime speech-summary exception with `provider returned non-JSON payload`. The screenshot sequence shows the app still had useful meeting evidence, so this should be triaged as Provider response validation and recoverable analysis error handling rather than total Live Workspace failure.

### 2026-06-25 - Focused triage

Promoted to `ready-for-agent`.

Code triage found a user-facing error sanitization gap. Raw Provider response-format failures can bubble from the Insight Sidecar through the live pipeline into `LiveSessionViewModel.publishError`, then `ContentView` renders them as realtime-summary exceptions. The raw JSON parser details are useful for logs, but not appropriate as the main live-session banner.

Bounded implementation target:

- classify Provider non-JSON payload errors as recoverable analysis response-format failures when transcript/capture evidence remains usable;
- replace parser line/column details with a clear user-facing message such as "分析服务返回格式异常，转写继续，可稍后重试或检查设置";
- preserve raw parser details in diagnostics or debug logs, not in the main banner;
- keep the Settings Workspace or retry path available.

Suggested regression loop:

- add a pipeline or view-model test where the Provider error contains `provider returned non-JSON payload`;
- assert that the user-facing message is sanitized;
- assert that existing transcript and Smart Minutes state are preserved.

Dependency note: this is related to issue 09 through a shared analysis-error classifier, but it should remain a separate issue because it covers Provider response validation rather than timeout behavior.

### 2026-06-25 - Diagnosing-bugs implementation pass

Code fix installed in build `20260625132851`; owner retest required.

Root cause:

- `LiveTranscriptPipeline.refreshLiveInsight` did not classify Provider response-format failures, so `provider returned non-JSON payload` errors were thrown upward with raw parser details.
- `LiveSessionViewModel.publishError` also lacked a fallback sanitizer, so the same raw error could appear from post-session Final Insight Generation paths.
- `ContentView.userFacingProviderMessage` did not have a last-resort mapping for this error family.

Implemented:

- added a shared Provider error presentation helper for invalid response payloads;
- classified `provider returned non-JSON payload` as a recoverable analysis response-format failure in the Live Transcript Pipeline;
- preserved Transcript Segments and existing Smart Minutes evidence when live refresh hits this error;
- replaced line/column/character parser details with: `分析服务返回格式异常，转写和已有纪要已保留。请稍后重试，或打开设置检查 Provider 配置。`;
- added a ViewModel fallback so Final Insight Generation and other `publishError` callers also show the sanitized message;
- added a ContentView fallback mapping as a final guard against raw Provider parser details reaching the banner.

Verification:

- red loop first failed as expected:
  - `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests/testProviderNonJSONPayloadDegradesWithSanitizedMessageWhileKeepingTranscript --filter LiveSessionViewModelTests/testPublishErrorSanitizesProviderNonJSONPayloadError`
- target green loop passed: same command, 2 tests, 0 failures
- related green loop passed: `swift test --package-path macos/InsightKitApp --filter LiveTranscriptPipelineTests --filter LiveSessionViewModelTests`, 37 tests, 0 failures
- full Swift gate passed: `swift test --package-path macos/InsightKitApp`, 143 tests, 0 failures
- standard sync passed Swift and Python gates; Python reported `Ran 136 tests ... OK`

Installed proof:

- installed app: `/Users/yann.jy/Applications/InsightKit.app`
- installed build: `20260625132851`
- proof: `logs/workflow/latest_sync.json`

Owner retest should confirm:

- a Provider non-JSON payload failure no longer shows raw text like `provider returned non-JSON payload`, `line 42`, or `char 1169` in the realtime summary banner;
- the banner instead says the analysis service returned an invalid format and suggests retrying or checking Provider settings;
- transcript rows and existing Smart Minutes remain visible;
- the `打开设置` action remains usable.

### 2026-06-25 - Owner retest passed

The owner confirmed issue 10 is resolved.

Provider non-JSON payload sanitization is no longer an active blocker for continuing manual QA.
