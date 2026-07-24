# InsightKit Release Verification Checklist - 2026-05-24

This checklist is the reproducible gate for moving InsightKit toward the personal Feishu/Lark Minutes replacement goal in `docs/Legacy/overview.md`.

## Artifact Policy

- Keep intermediate packages, logs, exports, screenshots, result bundles, and proof files until the end of a phase.
- Only delete artifacts during a final cleanup pass, or when a stale artifact directly blocks a build, install, or verification.
- The canonical locally installed app is `/Users/yann.jy/Applications/InsightKit.app`.

## Build And Test Gates

Run from `/Users/yann.jy/Developer/Projects/transcription`.

Development loop, before packaging:

```bash
swift test --package-path macos/InsightKitApp --quiet
python3 scripts/smoke_test_rpc.py
python3 scripts/run_real_import_e2e.py
scripts/dev_build_xcode_debug_app.sh
scripts/dev_open_xcode_debug_app.sh
scripts/dev_check_insightkit_processes.sh
scripts/dev_quit_insightkit_processes.sh
scripts/dev_capture_insightkit_logs.sh --last 10m --output /private/tmp/insightkit-dev-latest.log
```

Release loop, after the product path is ready:

```bash
./scripts/run_python_tests.sh
swift test --package-path macos/InsightKitApp --quiet
python3 scripts/smoke_test_rpc.py
python3 scripts/run_real_import_e2e.py
./scripts/package_insightkit_app.sh --output-dir /private/tmp/insightkit-package --install-dir /Users/yann.jy/Applications
codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app
python3 scripts/run_packaged_app_url_import_smoke.py
scripts/release_preflight.sh /Users/yann.jy/Applications/InsightKit.app
python3 scripts/verify_release_readiness.py
python3 scripts/verify_secret_hygiene.py
python3 scripts/verify_ui_hygiene.py
python3 scripts/verify_goal_evidence.py
./scripts/release_build.sh --version 0.1.0
scripts/notarize_insightkit_release.sh --help
```

Current evidence:

- Current post-runtime-signature proof on installed build `20260526113744`: `python3 scripts/run_packaged_app_url_import_smoke.py` passed and wrote `logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/proof.json`; record `/Users/yann.jy/Documents/InsightKit/Records/file-013cc112-3e96-431b-a5bd-9cdba71d5bfc`; Markdown `/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/exports/file-013cc112-3e96-431b-a5bd-9cdba71d5bfc_1779766734.md`; PDF `/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/exports/file-013cc112-3e96-431b-a5bd-9cdba71d5bfc_1779766744.pdf`. The smoke validated app/sidecar build match, DeepSeek final analysis provenance, 11 timestamped `spk0`/`spk1` transcript rows, schema-valid `insight_package.json`, SQLite/FTS query `left`, required Markdown sections, PDF header, and clean quit. After the smoke, `find /Users/yann.jy/Applications/InsightKit.app/Contents/Resources/insightkit_runtime -name __pycache__ -type d -print` returned no output, `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed, and `scripts/release_preflight.sh /Users/yann.jy/Applications/InsightKit.app` exited `0` with only expected local-channel warnings.
- Current visual GUI proof on the same installed build `20260526113744`: `logs/diagnostics/2026-05-26/current-build-visual-gui-proof-20260526-113744.json`; screenshot `logs/diagnostics/2026-05-26/current-build-visual-gui-proof-20260526-113744.png`. Computer Use verified the home screen, latest recent record, Records search count changing from `34` to `3`, restored detail for `file-013cc112-3e96-431b-a5bd-9cdba71d5bfc`, all six smart-minutes sections, media surface, export buttons, timestamped transcript, persisted time-bound note, and visible seek statuses after chapter (`00:11`), transcript (`00:20`), and note (`00:05`) clicks.
- Current release-readiness status table: `docs/plans/2026-05-26-insightkit-release-readiness-status.md`. It is the compact audit surface for local readiness, overview capability coverage, personal-local degradations, Developer ID blockers, App Store blockers, and owner-controlled inputs.
- Current repeatable release-readiness verifier: `python3 scripts/verify_release_readiness.py` passed with `status=passed_with_external_blockers` and wrote `logs/diagnostics/2026-05-26/release-readiness-status-20260526-120328/proof.json`. The verifier links the current URL import smoke and visual GUI proof, reruns local/Developer ID/App Store preflight gates, records signing identities, confirms no process/socket residue, and keeps local readiness separate from Apple-owned distribution blockers.
- Current secret hygiene verifier: `python3 scripts/verify_secret_hygiene.py` passed and wrote `logs/diagnostics/2026-05-26/secret-hygiene-20260526-121300/proof.json`; it scanned `267` release-relevant text files and found `0` high-confidence hardcoded API keys or private keys.
- Current UI hygiene verifier: `python3 scripts/verify_ui_hygiene.py` passed and wrote `logs/diagnostics/2026-05-26/ui-hygiene-20260526-121736/proof.json`; it scanned `75` Swift app source files and found `0` release-blocking placeholder controls, empty button actions, or permanently disabled controls.
- Current goal-level evidence verifier: `python3 scripts/verify_goal_evidence.py` passed with `status=local_personal_loop_verified_with_external_distribution_blockers` and wrote `logs/diagnostics/2026-05-26/goal-evidence-status-20260526-121834/proof.json`. It maps the current proof set back to `docs/Legacy/overview.md` and reports `25` verified requirements, `1` personal-local degradation, `2` external distribution blockers, and no missing local personal-loop requirements.
- Current regressions after URL import, Python-runtime signature hardening, release-readiness verifier coverage, goal-evidence verifier coverage, secret-hygiene verifier coverage, and UI-hygiene verifier coverage: `swift test --package-path macos/InsightKitApp` passed `115 tests, 0 failures`; `./scripts/run_python_tests.sh` passed `172 passed, 1 warning`; focused `swift test --package-path macos/InsightKitApp --filter SidecarBuildMismatchRecoveryTests` passed `4 tests, 0 failures`; focused `python3 -m pytest tests/test_verify_goal_evidence_script.py tests/test_verify_ui_hygiene_script.py tests/test_verify_secret_hygiene_script.py -q` passed `17 passed`.
- Development scripts now provide fixed approval-friendly entrypoints for Xcode-beta Debug builds, app launch, bounded process inspection, quit cleanup, and unified-log capture. `bash -n scripts/dev_build_xcode_debug_app.sh scripts/dev_open_xcode_debug_app.sh scripts/dev_check_insightkit_processes.sh scripts/dev_quit_insightkit_processes.sh scripts/dev_capture_insightkit_logs.sh` passed. `scripts/dev_build_xcode_debug_app.sh` generated the XcodeGen project, built `/private/tmp/insightkit-xcode-dev/Build/Products/Debug/InsightKitApp.app`, and passed strict codesign verification. `scripts/dev_open_xcode_debug_app.sh` launched that app; `scripts/dev_check_insightkit_processes.sh` confirmed the Debug app process at `/private/tmp/insightkit-xcode-dev/Build/Products/Debug/InsightKitApp.app/Contents/MacOS/InsightKitApp`; `scripts/dev_quit_insightkit_processes.sh` returned `InsightKit quit cleanly.` and then showed no app process, no sidecar process, and no `/tmp/insightkit-app-501.sock`. `scripts/dev_capture_insightkit_logs.sh --last 1m --output /private/tmp/insightkit-dev-log-check.txt` wrote a bounded log file. These scripts are development gates only; they do not replace canonical release packaging.
- Python: latest `./scripts/run_python_tests.sh` passed with `172 passed, 1 warning`; earlier sandboxed runs failed only because AF_UNIX socket bind was denied in persistent-connection tests.
- Swift: latest `swift test --package-path macos/InsightKitApp` passed `115 tests, 0 failures`.
- Latest shutdown/recovery Swift regression: `swift test --package-path macos/InsightKitApp` passed `87 tests, 0 failures` after adding explicit app/view-model shutdown hooks and tightening the quit script.
- Latest post-relaunch linkage Swift regression: `swift test --package-path macos/InsightKitApp` passed `89 tests, 0 failures` after adding visible record-detail seek status and stable record smart-minutes/transcript row accessibility ids.
- Fresh smart-minutes UI proof: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests` passed after adding historical-record speaker-summary fallback coverage; the current full Swift suite is `87 tests, 0 failures`.
- Focused missing-media error-state proof: `swift test --package-path macos/InsightKitApp --filter RecordsIndexServiceTests` passed `3 tests, 0 failures`; `testRecordReviewShowsVisibleMissingMediaStatus` verifies a historical record without `recording.*` still loads transcript entries and exposes a visible `媒体文件缺失` status. The review UI renders this through accessibility id `record_media_missing_status`.
- Focused import error-state proof: `swift test --package-path macos/InsightKitApp --filter ImportSessionViewModelRecordFallbackTests` passed in the current `9 tests, 0 failures` suite; `testVisibleImportErrorStatusMessageIgnoresEmptyValues` verifies real import errors produce a visible status message while empty values are hidden. The import UI renders this through accessibility id `import_error_status`.
- Focused long-import feedback proof: `swift test --package-path macos/InsightKitApp --filter ImportSessionViewModelRecordFallbackTests` now passes `9 tests, 0 failures`; new coverage verifies import-stage status text, sidecar cancellation through `transcription.cancel_job`, visible cancellation success, visible cancellation failure, and visible provider/API-key fallback. Proof index: `logs/diagnostics/2026-05-24/import-cancel-progress-proof.json`. The import UI renders this through accessibility ids `import_processing_status`, `import_cancel_button`, and `import_analysis_status`.
- Focused ASR model error-state proof: `swift test --package-path macos/InsightKitApp --filter ASRRuntimeStatusPresentationTests` passed `3 tests, 0 failures`; `testMissingModelProducesActionableSettingsWarning` verifies `modelExists=false` becomes an actionable settings warning. The settings UI renders this through accessibility id `settings_asr_model_missing_status`.
- Focused live-recording media proof: `swift test --package-path macos/InsightKitApp --filter ChunkAssemblerTests` passed `1 test, 0 failures`; `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` passed `15 tests, 0 failures`; `logs/diagnostics/2026-05-24/live-recording-media-proof.json` indexes the implementation evidence for combining live WAV chunks and short pending audio into `recording.wav`, exposing that file to playback, sending it through `records.save` with duration and timestamped notes, and surfacing a visible no-audio status.
- Focused export related-link proof: `python3 -m pytest tests/test_insight_coord.py` passed `8 tests, 0 failures`; `logs/diagnostics/2026-05-24/export-related-links-proof.json` indexes the proof that export retains `原始记录`, `文字记录`, and `媒体回放` references even when direct `source_path` is unavailable.
- Sidecar smoke: latest default `python3 scripts/smoke_test_rpc.py` now auto-starts a temporary sidecar when no reachable socket exists, waits with a bounded startup timeout, runs `12 passed, 0 failed`, shuts the owned sidecar down, and leaves no `insight_sidecar.py` process. Proof: `logs/diagnostics/2026-05-25/noninteractive-sidecar-smoke-proof.json`.
- Non-interactive real import E2E: `python3 scripts/run_real_import_e2e.py` passed using the real 30s sample `logs/diagnostics/e2e/real_sample_2026_5_11_en_1_30s.m4a`. It used an isolated socket, DB, records root, and exports root; completed `transcription.import_file`; produced 5 timestamped transcript rows with `SPEAKER_00`/`SPEAKER_01`; validated `insight_package.json` schema; wrote a time-bound note; verified SQLite/FTS search; exported overview-aligned Markdown/PDF; and stopped the temporary sidecar. Proof: `logs/diagnostics/2026-05-25/real-import-e2e-20260525-105950/proof.json`.
- Computer Use record-review E2E: build `20260525104413` passed a real app pass through home, Records, search, smart-minutes review, chapter/transcript/note media seeking, time-bound note creation, Markdown/PDF export, bounded quit, relaunch, and recovery of media, smart minutes, timestamped transcript, and both notes. Export artifacts: `/Users/yann.jy/Documents/InsightKit/Records/file-a45e1e78-6d60-420d-a80b-56490e2d9788/exports/file-a45e1e78-6d60-420d-a80b-56490e2d9788-20260525-112043.md` and `/Users/yann.jy/Documents/InsightKit/Records/file-a45e1e78-6d60-420d-a80b-56490e2d9788/exports/file-a45e1e78-6d60-420d-a80b-56490e2d9788-20260525-112050.pdf`. Proof: `logs/diagnostics/2026-05-25/cua-record-review-export-recovery-proof.json`.
- Computer Use import-picker E2E: build `20260525114436` opened the real import workspace, selected `InsightKit-GUI-E2E-30s.m4a` through the native open panel after removing brittle system-level UTType filtering, completed `transcription.import_file`, restored a new persisted record `file-77c31083-0dc5-4b43-80d1-91029c9f61c9`, created a time-bound note, exported Markdown/PDF, quit/relaunched cleanly, and reopened the new record. The same pass verified legacy AI chapter timestamp `01:13` on a 30s clip is normalized to `00:13` in review UI and seeks media to `00:13`. Proof: `logs/diagnostics/2026-05-25/cua-import-picker-timestamp-normalization-proof.json`.
- Package: latest canonical `/Users/yann.jy/Applications/InsightKit.app` was cleanly replaced from `/private/tmp/insightkit-release-0.1.0-local.ZHnide/app/InsightKit.app`; local `Apple Development` signing, strict code-sign verification, and local release preflight passed.
- Release zip: `./scripts/release_build.sh --version 0.1.0` passed and produced local/internal QA archive `dist/releases/InsightKit-0.1.0-macos-local-20260524221747.zip` plus preflight log `dist/releases/InsightKit-0.1.0-local-20260524221747-preflight.txt`.
- Notarization script help: `scripts/notarize_insightkit_release.sh --help` passed and documents the Developer ID preflight, notarytool credential options, stapling, validation, and final public zip output path.
- Persisted-record app exports use native Swift/AppKit PDF generation through `RecordDocumentExporter`; live/transcription/import export paths now prefer persisted-record native export before falling back to RPC `document.export`.
- RPC `document.export` now renders the shareable document with `会议信封`, `长文版结构化总结`, `会议金句`, `发言人总结`, `关键决策`, `待办事项`, `智能章节`, and `相关链接`; the old `交互占位提示` section is removed.
- RPC PDF export now uses WeasyPrint when available and falls back to a built-in Unicode text PDF writer when WeasyPrint is missing.
- RPC `document.export` now honors caller-provided relative `output_dir` values by resolving them against the sidecar working directory instead of silently falling back to `~/Documents/InsightKit/exports`; old client calls that pass `output_dir="txt"` remain mapped to the default export root. Proof: `logs/diagnostics/2026-05-24/export-output-dir-proof/proof.json`.
- RPC `document.export` now keeps related links populated from meeting/source fallback: no-source-path exports still include original record, transcript, and media playback references instead of the empty-link fallback. Proof: `logs/diagnostics/2026-05-24/export-related-links-proof.json`.
- Historical record review now surfaces missing media files as an explicit warning instead of silently leaving playback blank.
- Import/transcription failures now surface in the import page as an explicit error state instead of only resetting to the file picker.
- Settings now surfaces missing local ASR model files as an explicit actionable warning instead of only showing raw runtime fields.
- Historical record details now expose the full `overview.md` smart-minutes surface in the main review pane: `总结`, `会议金句`, `发言人总结`, `关键决策`, `待办事项`, and `智能章节`.
- Local live sessions now have a defensible recording fallback: retained WAV chunks and short pending audio are combined into `recording.wav` when recording stops, attached to review playback, and saved as the live record media asset before chunk cleanup. Sessions with no saveable audio now expose `live_recording_status` in the live center instead of silently showing an empty player.
- Live post-session smart minutes are now persisted back to the record folder after `生成纪要`, including the no-transcript fallback summary. Computer Use verified restart recovery and Markdown/PDF export for `live-9034A7A6-E74E-4335-B8C9-ADFF05B4A337`; proof: `logs/diagnostics/2026-05-25/live-final-minutes-persistence-proof.json`.
- Current app-side provider/quit proof: installed app `CFBundleVersion=20260526092324` was opened with Computer Use, Settings showed DeepSeek + saved Keychain API key, `检查可用性` returned `连接通过 ... 连接成功。`, and `sidecar.version.build=20260526092324` matched the app build. `python3 scripts/verify_app_side_provider.py --probe-timeout-sec 30 --final-timeout-sec 120` then used the GUI-started sidecar and real transcript sample to produce `logs/diagnostics/2026-05-26/app-side-provider-validation-proof.json` with `outcome=verified_app_side_cloud_final_build`, provider `deepseek`, model `deepseek-v4-flash`, and schema-valid final minutes. Current verification commands passed: `python3 -m pytest tests/test_verify_app_side_provider_script.py tests/test_verify_current_provider_script.py -q` with `4 passed`, and `swift test --package-path macos/InsightKitApp` with `108 tests, 0 failures`. Quit hardening evidence: after the provider run, `/usr/bin/time -p scripts/quit_insightkit_app.sh` returned `InsightKit quit cleanly.` in `real 1.07`, and follow-up checks found no `InsightKitApp`, no `insight_sidecar.py`, and no `/tmp/insightkit-app-501.sock`.
- Current full-flow Computer Use proof on the same installed build `20260526092324`: `logs/diagnostics/2026-05-26/cua-latest-build-import-recovery-proof.json`. It imported the real 30s sample through the app, generated record `file-c21bf809-d079-4234-ae51-1397739f13a0`, created time-bound note `00:29 Latest build E2E note`, verified pre-relaunch chapter/transcript/note media seeks, exported Markdown/PDF, confirmed SQLite/FTS persistence, quit cleanly, relaunched, restored the record from Home/Records, and narrowed Records search to one result for `Latest build E2E`. The proof is intentionally marked partial because a post-relaunch restored-chapter click caused Computer Use state capture to time out; no crash report was produced, but the following bounded quit needed TERM after the 3s AppleEvent timeout.
- Follow-up canonical stability proof on installed build `20260526102135`: `logs/diagnostics/2026-05-26/canonical-media-teardown-recovery-proof.json`. After the media teardown fix was packaged into `/Users/yann.jy/Applications/InsightKit.app`, `swift test --package-path macos/InsightKitApp --filter MediaSeekRequestTests` passed `7 tests, 0 failures`, full `swift test --package-path macos/InsightKitApp` passed `110 tests, 0 failures`, `python3 scripts/smoke_test_rpc.py` passed `12 passed, 0 failed`, strict codesign verification passed, and local `scripts/release_preflight.sh /Users/yann.jy/Applications/InsightKit.app` exited `0`. Computer Use restored record `file-c21bf809-d079-4234-ae51-1397739f13a0` from the installed app, clicked restored smart-minutes chapter, transcript, and note rows without timeout, and surfaced `record_media_seek_status` values for `00:11`, `00:12`, and `00:29`. `scripts/dev_quit_insightkit_processes.sh` returned `InsightKit quit cleanly.` and confirmed no app process, no sidecar process, and no sidecar socket. This closes the previous post-relaunch click-to-seek and quit-responsiveness residual for the canonical local app.
- Current canonical import/search/recovery proof on installed build `20260526104223`: `logs/diagnostics/2026-05-26/canonical-gui-import-search-recovery-proof.json`. A follow-up real GUI import created record `file-c1b3311a-9e9c-4ab6-b4f1-0c2632709fab` from `logs/diagnostics/e2e/real_sample_2026_5_11_en_1_30s.m4a`, verified schema-valid DeepSeek final minutes, SQLite/FTS persistence, a time-bound note, and Markdown/PDF exports. The previously observed Records search hang was traced to query-time disk reads in `RecordsIndexService.searchRecords`; the service now caches content during refresh and `RecordsIndexServiceTests` includes `testSearchRecordsUsesRefreshTimeContentIndex`. After packaging the fix, Computer Use searched `Canonical GUI E2E` to `全部记录 (1)`, restored media/smart-minutes/transcript/notes/export controls, clicked chapter/transcript/note rows with visible seek statuses at `00:02`, `00:20`, and `00:22`, and `scripts/dev_quit_insightkit_processes.sh` returned `InsightKit quit cleanly.` with no residual process or socket. Current regressions: `RecordsIndexServiceTests` `8 tests, 0 failures`, `MediaSeekRequestTests` `7 tests, 0 failures`, full Swift `111 tests, 0 failures`, sidecar smoke `12 passed, 0 failed`, and full Python unit suite `148 passed, 1 warning`. Local release preflight passed on this installed app; Developer ID, hardened runtime, App Sandbox, clean Gatekeeper distribution proof, and privacy policy URL remain warnings/release-owner items.
- Current repeatable installed-app URL import smoke on build `20260526113744`: `logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/proof.json`. The installed `Info.plist` registers `CFBundleURLTypes` with scheme `insightkit`; `open -b com.yannjy.insightkit insightkit://import?path=<encoded real sample>` triggered the app-owned sidecar on `/tmp/insightkit-app-501.sock`, whose `sidecar.version.build` matched the app build. The smoke imported `logs/diagnostics/e2e/real_sample_2026_5_11_en_1_30s.m4a`, discovered job `02fd85f0-2d85-4ae0-87d9-5bf93ff3e25d`, completed record `file-013cc112-3e96-431b-a5bd-9cdba71d5bfc`, validated DeepSeek final analysis provenance, 11 timestamped `spk0`/`spk1` rows, `insight_package.json` schema, SQLite/FTS query `left`, Markdown required sections, a two-page PDF, and clean quit with no app/sidecar/socket residue. Running this smoke no longer creates Python `__pycache__` inside the signed app bundle, so strict codesign and local release preflight still pass after runtime use. This is a repeatable packaged-app import smoke path; bounded Computer Use remains the visual GUI evidence layer while XCUITest is locally blocked.

## Bundle Metadata Gate

```bash
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIconFile' \
  -c 'Print :CFBundleIdentifier' \
  -c 'Print :CFBundleShortVersionString' \
  -c 'Print :CFBundleVersion' \
  /Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist
file /Users/yann.jy/Applications/InsightKit.app/Contents/Resources/InsightKit.icns
plutil -lint macos/InsightKitApp/InsightKitApp-Info.plist /Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist
codesign -d --entitlements - /Users/yann.jy/Applications/InsightKit.app
```

Current evidence:

- `CFBundleIconFile=InsightKit.icns`.
- `CFBundleIdentifier=com.yannjy.insightkit`.
- `CFBundleShortVersionString=0.1.0`.
- `CFBundleURLTypes` includes scheme `insightkit` for installed-app URL import smoke.
- Latest verified canonical installed app `CFBundleVersion=20260526113744`.
- Recent historical proof builds include `20260526092324` for app-side provider validation, `20260526102135` for media teardown closure, `20260526104223` for Records search/import recovery closure, `20260526112542` for the first repeatable URL import smoke, and `20260526113744` for runtime signature preservation after URL import smoke.
- Earlier GUI/linkage evidence used builds `20260524183227`, `20260524185320`, and `20260524190413`; those are retained as historical proof artifacts, not the current canonical build.
- Installed icon file exists and is identified as a Mac OS X icon.
- Both source and installed plist files pass `plutil -lint`.
- Manual SwiftPM package currently has no embedded entitlements; this is acceptable for local machine validation, but not a release-complete App Store state.

## GUI User Flow Gate

Use Computer Use against `/Users/yann.jy/Applications/InsightKit.app`.

Development-first rule:

- The main development loop is Swift tests, Python tests, sidecar smoke tests, real media/sample artifacts, SQLite/export proofs, and bounded Computer Use E2E.
- Xcode-beta Debug app validation should use `scripts/dev_build_xcode_debug_app.sh` plus `/private/tmp/insightkit-xcode-dev/Build/Products/Debug/InsightKitApp.app`, not `./scripts/package_insightkit_app.sh`, unless the change specifically needs packaging verification.
- Repeatable installed-app import smoke should use `python3 scripts/run_packaged_app_url_import_smoke.py` after packaging/installing. It exercises the installed app's `insightkit://import?path=...` entrypoint and app-owned sidecar, but does not replace visual Computer Use checks.
- `./scripts/run_uitests.sh` is a useful automation evidence layer, but a local macOS UI automation initialization failure must not block product development when the same flow can be verified by bounded Computer Use and artifacts.
- `scripts/release_build.sh`, Developer ID signing, notarization, App Store sandbox checks, and App Store metadata remain release gates. They should be revisited after the product loop is complete, unless a packaging/signing defect directly breaks local app execution.

Required flow:

1. Open app and verify the home screen shows `InsightKit`, live/import/records cards, and recent records.
2. Import a real local audio or video file.
3. Wait with bounded polling only; if UI state stalls, verify sidecar/job state and logs instead of waiting indefinitely.
4. Verify completed import shows smart chapters, media player, timestamped transcript, smart minutes, and notes.
5. Create a time-bound note and verify it persists in the record folder `notes.md`.
6. Export Markdown and PDF from the app and verify files exist and are readable.
7. Quit and reopen the app; verify the recent record can be reopened with media, transcript, insight, notes, and export controls restored.
8. Click a chapter, transcript row, and note; each must visibly seek the player to the corresponding time.

Current packaged-app evidence:

- Repeatable URL import smoke: `python3 scripts/run_packaged_app_url_import_smoke.py` passed on installed build `20260526113744`; proof `logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/proof.json`; record `/Users/yann.jy/Documents/InsightKit/Records/file-013cc112-3e96-431b-a5bd-9cdba71d5bfc`; Markdown `/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/exports/file-013cc112-3e96-431b-a5bd-9cdba71d5bfc_1779766734.md`; PDF `/Users/yann.jy/Developer/Projects/transcription/logs/diagnostics/2026-05-26/packaged-app-url-import-smoke-20260526-113806/exports/file-013cc112-3e96-431b-a5bd-9cdba71d5bfc_1779766744.pdf`.
- Current-build visual GUI proof: `logs/diagnostics/2026-05-26/current-build-visual-gui-proof-20260526-113744.json`; screenshot `logs/diagnostics/2026-05-26/current-build-visual-gui-proof-20260526-113744.png`.
- Real GUI import record: `/Users/yann.jy/Documents/InsightKit/Records/file-a0d91361-e00c-424f-a6aa-b5c9896fd437`.
- Verified artifacts: `metadata.json`, `recording.m4a`, `transcript.json`, `notes.md`, `minutes.json`, `insight_package.json`, and `exports/`.
- Time-bound note: `00:29 GUI import note at playback time`.
- Markdown export: `/Users/yann.jy/Documents/InsightKit/Records/file-a0d91361-e00c-424f-a6aa-b5c9896fd437/exports/file-a0d91361-e00c-424f-a6aa-b5c9896fd437-20260523-213836.md`.
- PDF export: `/Users/yann.jy/Documents/InsightKit/Records/file-a0d91361-e00c-424f-a6aa-b5c9896fd437/exports/file-a0d91361-e00c-424f-a6aa-b5c9896fd437-20260523-213851.pdf`.
- RPC export rendering proof: `logs/diagnostics/2026-05-24/rpc-export-rendering-proof/proof.json`; Markdown `logs/diagnostics/2026-05-24/rpc-export-rendering-proof/real-sample-rpc-export_1779630809.md` and PDF `logs/diagnostics/2026-05-24/rpc-export-rendering-proof/real-sample-rpc-export_1779630809.pdf` were generated from the real timestamped E2E transcript sample and include the release header, AI disclaimer, structured summary, related links, media `file://` link, no `交互占位提示`, and a `%PDF-` PDF header.
- RPC export output-dir proof: `logs/diagnostics/2026-05-24/export-output-dir-proof/proof.json`; Markdown exports generated from the same real timestamped E2E transcript sample prove relative `output_dir` resolves under the current working directory, legacy `output_dir="txt"` still resolves to the default export root, and both exports retain the release document sections.
- Export related-link fallback proof: `logs/diagnostics/2026-05-24/export-related-links-proof.json`; Markdown export keeps `原始记录`, `文字记录`, and `媒体回放` references even when a direct media `source_path` is unavailable.
- Built-in PDF fallback proof: `logs/diagnostics/2026-05-24/pdf-fallback-proof/proof.json`; PDF `logs/diagnostics/2026-05-24/pdf-fallback-proof/real-sample-pdf-fallback_1779631272.pdf` was generated from the same real timestamped transcript sample while WeasyPrint was forced missing, and has a `%PDF-` header plus the built-in CJK font marker.
- Reopen/recovery works through the home recent record list.
- Media linkage works after reinstall:
  - Chapter `00:12` seek shows elapsed time `00:12`.
  - Transcript `00:19` seek shows elapsed time around `00:20`.
  - Note `00:29` seek shows elapsed time `00:29`.
- Fresh canonical-app GUI proof on build `20260524183227`: Computer Use bound to `/Users/yann.jy/Applications/InsightKit.app` with bundle id `com.yannjy.insightkit`; the home screen exposed `home_card_live`, `home_card_import`, `home_card_records`, recent records, and status text.
- Records page proof: selecting `home_card_records` exposed `records_search_field`, `records_list`, tag filters, and `20` records; setting query `注册` filtered the count to `2`.
- Record detail proof: selecting `record_list_item_file-a0d91361-e00c-424f-a6aa-b5c9896fd437` restored chapters, media controls, timestamped speaker transcript rows, smart minutes summary, note panel, and export buttons `record_export_markdown_button` / `record_export_pdf_button`.
- Fresh linkage proof on the same installed app: clicking chapter `live_chapter_row_1` jumped the player to `00:12` (`timeline ~= 11.99s`); clicking transcript row `00:19` jumped to `00:20` (`timeline ~= 19.63s`).
- Screenshot artifacts: `logs/diagnostics/2026-05-24/insightkit-gui-record-linkage-20260524-1850-w32851.png` and `logs/diagnostics/2026-05-24/insightkit-gui-record-linkage-20260524-1850-w32914.png`.
- Fresh smart-minutes overview proof on installed build `20260524185320`: opening `record_list_item_file-a0d91361-e00c-424f-a6aa-b5c9896fd437` exposed `record_smart_minutes_overview` with `总结`, `会议金句`, `发言人总结`, `关键决策`, `待办事项`, `智能章节`, followed by `record_transcript_title`.
- Smart-minutes chapter linkage proof: clicking the overview chapter button `00:12 提出方案` jumped the media player to elapsed `00:12` (`timeline ~= 11.9888s`).
- Smart-minutes screenshot artifact: `logs/diagnostics/2026-05-24/insightkit-smart-minutes-overview-20260524-1856.png`.
- Structured proof JSON: `logs/diagnostics/2026-05-24/smart-minutes-overview-proof.json`.
- Latest canonical launch smoke on build `20260524221829`: Computer Use bound to `/Users/yann.jy/Applications/InsightKit.app` with bundle id `com.yannjy.insightkit`, pid `40215`, and window title `InsightKit`; the home screen exposed `home_title`, `home_card_live`, `home_card_import`, `home_card_records`, `home_recent_title`, recent records, and status text.
- Latest canonical release/install proof JSON: `logs/diagnostics/2026-05-24/latest-release-install-proof.json`.
- Latest development-first GUI import/recovery proof on build `20260525102729`: `logs/diagnostics/2026-05-25/latest-dev-gui-import-recovery-proof.json`.
  - Real imported sample: `/Users/yann.jy/Downloads/TencentMeeting/2025-09-12 13.30.50 變的快速会议 270371583/InsightKit-GUI-E2E-30s.m4a`.
  - Persisted record folder: `/Users/yann.jy/Documents/InsightKit/Records/file-a45e1e78-6d60-420d-a80b-56490e2d9788`.
  - Sidecar job completed with `segments_count=11`, `progress=100`, and `stage=completed`.
  - Markdown export: `/Users/yann.jy/Documents/InsightKit/Records/file-a45e1e78-6d60-420d-a80b-56490e2d9788/exports/file-a45e1e78-6d60-420d-a80b-56490e2d9788-20260524-231850.md`; verified sections include title, meeting topic/time, participants, AI disclaimer, structured summary, highlights, speaker summary, decisions, actions, chapters, related links, time-bound notes, and timestamped transcript.
  - PDF export: `/Users/yann.jy/Documents/InsightKit/Records/file-a45e1e78-6d60-420d-a80b-56490e2d9788/exports/file-a45e1e78-6d60-420d-a80b-56490e2d9788-20260525-095356.pdf`; `file` reports `PDF document, version 1.3, 2 pages`, and Quick Look rendered `/private/tmp/insightkit-pdf-preview/file-a45e1e78-6d60-420d-a80b-56490e2d9788-20260525-095356.pdf.png`.
  - Reopen/recovery: after reinstall/relaunch, Computer Use observed the latest record on the home screen, opened it through Records, and restored `record_smart_minutes_overview`, timestamped transcript, media duration `00:30`, note `00:30 GUI latest build note`, and export controls.
  - Linkage status: the same import-review session verified chapter, transcript, and note seek. Post-relaunch record detail restored media and smart-minutes state, but a post-relaunch smart-chapter click caused Computer Use state capture to time out; this is tracked as weaker evidence and not treated as completed post-relaunch click-to-seek proof.
- Latest post-relaunch record linkage proof on build `20260525104413`: `logs/diagnostics/2026-05-25/post-relaunch-record-linkage-proof.json`.
  - Source record: `/Users/yann.jy/Documents/InsightKit/Records/file-a45e1e78-6d60-420d-a80b-56490e2d9788`.
  - Record detail now exposes stable ids for `record_smart_minutes_overview`, `record_minutes_chapter_row_1`, `record_transcript_row_6`, and `live_note_row_0`.
  - Clicking smart-minutes chapter `record_minutes_chapter_row_1` jumped the player to elapsed `00:11` with visible status `已跳转到 00:11 · 章节：提出解决方案`.
  - Clicking transcript row `record_transcript_row_6` jumped the player to elapsed `00:12` with visible status `已跳转到 00:12 · 逐字稿：spk1`.
  - Clicking note row `live_note_row_0` jumped the player to elapsed `00:29` with visible status `已跳转到 00:29 · 笔记：00:30 GUI latest build note`.
  - The previous post-relaunch click-to-seek evidence gap is closed for chapter, transcript, and note interactions.
- Bounded XCUITest proof: `logs/diagnostics/2026-05-24/bounded-uitest-proof.json`; `./scripts/run_uitests.sh` regenerated the Xcode project, reached the Xcode runner, and exited `124` after the configured 90 second timeout with `Timed out while enabling automation mode.` The failure is classified as local UI automation initialization, not an InsightKit app-flow failure.

## Crash / Wait Discipline Gate

```bash
pgrep -fl 'InsightKitApp|insight_sidecar|python.*InsightKit|python.*insight'
zsh -lc 'ls -lt ~/Library/Logs/DiagnosticReports/InsightKitApp*.ips(N) | head -8'
scripts/quit_insightkit_app.sh
scripts/dev_check_insightkit_processes.sh
scripts/dev_quit_insightkit_processes.sh
scripts/dev_capture_insightkit_logs.sh --last 10m --output /private/tmp/insightkit-dev-latest.log
```

Rules:

- Use bounded waits, normally 2-5 seconds for GUI state checks.
- If Computer Use times out or activation fails, switch to process, crash report, sidecar socket, SQLite, logs, and artifact evidence.
- Do not wait indefinitely for a stalled GUI state.
- Prefer the fixed `scripts/dev_*` wrappers for repeated local validation so sandbox approval can be granted once per narrow workflow instead of once per ad hoc `xcodebuild`, `open`, `pgrep`, `log show`, or `kill` command.

Current evidence:

- Crash report root cause was the programmatic media seek feedback loop in `MediaPlayerView`.
- Post-fix chapter, transcript, and note seek clicks did not create a new `InsightKitApp*.ips`; the only observed crash report remains `/Users/yann.jy/Library/Logs/DiagnosticReports/InsightKitApp-2026-05-23-214926.ips`.
- The previous automation hang came from using `tell application "InsightKit" to quit` when the app was not already running; AppleScript can cold-launch the app and wait on startup. `SidecarManager` no longer ranks Python binaries synchronously during app initialization, and `scripts/quit_insightkit_app.sh` first checks for an existing process, then uses bounded AppleEvent/TERM/KILL fallback.
- Running-state quit evidence: `/usr/bin/time -p scripts/quit_insightkit_app.sh` returned `InsightKit quit cleanly.` in `real 0.55`; unified log showed `Checking whether app should terminate` and `terminate:`.
- Fresh canonical-app quit evidence on build `20260524183227`: `/usr/bin/time -p scripts/quit_insightkit_app.sh` returned `InsightKit quit cleanly.` in `real 0.70`, and a follow-up `pgrep -fl InsightKit` found no residual InsightKit process.
- Fresh crash-report check: `find /Users/yann.jy/Library/Logs/DiagnosticReports -maxdepth 1 -name 'InsightKitApp*' -print` returned no matching current crash reports.
- Do not use the raw executable path `.../InsightKit.app/Contents/MacOS/InsightKitApp` from the Codex sandbox as GUI launch proof. It created `/Users/yann.jy/Library/Logs/DiagnosticReports/InsightKitApp-2026-05-24-185447.ips` with `parentProc=codex` and an AppKit registration abort. Normal launch evidence must use `open /Users/yann.jy/Applications/InsightKit.app` plus Computer Use or process/window evidence.
- Fresh smart-minutes UI quit evidence on build `20260524185320`: `/usr/bin/time -p scripts/quit_insightkit_app.sh` returned `InsightKit quit cleanly.` in `real 0.82`, and a follow-up `pgrep -fl InsightKit` found no residual InsightKit process.
- Latest canonical quit evidence on build `20260524221829`: `/usr/bin/time -p scripts/quit_insightkit_app.sh` returned `InsightKit quit cleanly.` in `real 0.56`, and a follow-up `pgrep -fl InsightKit` found no residual InsightKit process.
- Latest quit/wait hardening proof on build `20260525102729`: `logs/diagnostics/2026-05-25/latest-dev-gui-import-recovery-proof.json`.
  - A stale sidecar residue was reproduced: the old script could report `InsightKit quit cleanly.` while an app-bundled `insight_sidecar.py` process remained.
  - The app now calls `WorkflowCoordinator.shutdown()` on `NSApplication.willTerminateNotification`; live/transcription/import view models explicitly stop their `SidecarManager`.
  - `scripts/quit_insightkit_app.sh` now checks and cleans sidecar processes, uses bounded sidecar shutdown/TERM/KILL fallback, and prefers AppleScript by bundle id `com.yannjy.insightkit` before falling back to app name.
  - Final minimal quit check returned `InsightKit quit cleanly.` in `real 0.59`; follow-up `pgrep -xfl InsightKitApp` and `pgrep -fl insight_sidecar.py` returned no output.
  - Tool stalls were handled without indefinite waiting: Computer Use and screenshot-helper timeouts were abandoned in favor of process/log/artifact checks, and the hung screenshot helper process was killed.
- Latest post-linkage quit proof on build `20260525104413`: after the post-relaunch chapter/transcript/note click checks, `/usr/bin/time -p scripts/quit_insightkit_app.sh` returned `InsightKit quit cleanly.` in `real 0.57`; follow-up `pgrep -xfl InsightKitApp` and `pgrep -fl insight_sidecar.py` returned no output.
- Previous residual on build `20260526092324`: after a restored record detail had loaded successfully, a restored smart-chapter click attempt caused Computer Use state capture to time out. `pgrep` showed the app still running, `find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'InsightKitApp*.ips'` found no current crash reports, and `/usr/bin/time -p scripts/quit_insightkit_app.sh` stopped the app only after sending TERM at the 3s AppleEvent timeout (`real 6.83`).
- Closure evidence on build `20260526102135`: the same restored record path now returns Computer Use state after smart-chapter, transcript, and note clicks, exposes visible seek statuses at `00:11`, `00:12`, and `00:29`, creates no `InsightKitApp*.ips` crash report, and `scripts/dev_quit_insightkit_processes.sh` exits cleanly with no app/sidecar/socket residue. Proof: `logs/diagnostics/2026-05-26/canonical-media-teardown-recovery-proof.json`.
- `./scripts/run_uitests.sh` is now bounded by `INSIGHTKIT_UITEST_TIMEOUT_SEC` and records log/result bundle paths. The latest run exited after 90 seconds instead of hanging: log `/tmp/insightkit_uitest.log`, result bundle `/tmp/insightkit_uitest_20260524225458.xcresult`.

## Signing And Distribution Gate

Local validation and distribution are separate gates.

Apple references used for this gate:

- Developer ID requirements: <https://developer.apple.com/support/developer-id/>
- Gatekeeper signing, notarytool, and stapler workflow: <https://developer.apple.com/developer-id/>
- Notarizing macOS software before distribution: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Custom command-line notarization workflow: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow>
- App Sandbox and protected user data: <https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox>
- Sandboxed file access and security-scoped bookmarks: <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>
- App privacy details: <https://developer.apple.com/app-store/app-privacy-details/>
- App Store privacy policy URL requirement: <https://developer.apple.com/help/app-store-connect/reference/app-information/app-information>

```bash
security find-identity -v -p codesigning
./scripts/package_insightkit_app.sh --output-dir /private/tmp/insightkit-package
./scripts/package_insightkit_app.sh --developer-id --output-dir /private/tmp/insightkit-developer-id-check
./scripts/release_build.sh --version 0.1.0 --developer-id
scripts/notarize_insightkit_release.sh --app /private/tmp/insightkit-release-0.1.0-local.aWlXHr/app/InsightKit.app --keychain-profile insightkit-notary
scripts/release_preflight.sh /private/tmp/insightkit-release-0.1.0-local.aWlXHr/app/InsightKit.app
scripts/release_preflight.sh --developer-id /private/tmp/insightkit-release-0.1.0-local.aWlXHr/app/InsightKit.app
scripts/release_preflight.sh --app-store /private/tmp/insightkit-release-0.1.0-local.aWlXHr/app/InsightKit.app
codesign -dvvv --entitlements :- /Users/yann.jy/Applications/InsightKit.app
spctl -a -vv /Users/yann.jy/Applications/InsightKit.app
scripts/release_preflight.sh /Users/yann.jy/Applications/InsightKit.app
```

Current evidence:

- `security find-identity -v -p codesigning` currently shows Apple Development identities, but no `Developer ID Application` identity.
- Local package mode works and signs with `Apple Development: yann.jy@icloud.com (LMWQNG6538)`.
- Local package mode now preserves strict codesign after runtime use: app-owned Python processes set `PYTHONDONTWRITEBYTECODE=1`, packaging removes pre-existing pycache before signing, and stage/install copies recursively clear xattrs before verification. This prevents the sidecar from adding sealed resources under `Contents/Resources/insightkit_runtime` after signing.
- Developer ID mode fails fast as intended: `Developer ID distribution requires a valid 'Developer ID Application' signing identity.`
- `scripts/release_build.sh` now separates `local` and `developer-id` distribution modes. Local output is named `macos-local-*` and prints that it is an internal QA archive; Developer ID output is named `macos-developer-id-unnotarized-*` and still requires a later notarization/stapling gate.
- Latest local release staging app `/private/tmp/insightkit-release-0.1.0-local.ZHnide/app/InsightKit.app` passed `codesign --verify --deep --strict --verbose=2`; its verified installed `CFBundleVersion` is `20260524221829`, and `unzip -l dist/releases/InsightKit-0.1.0-macos-local-20260524221747.zip` confirmed `InsightKit.app/Contents/MacOS/InsightKitApp`, `InsightKit.icns`, bundled `insightkit_runtime/`, updated RPC export renderer/coordination code, sidecar/schema files, and `Info.plist`.
- `scripts/release_preflight.sh` now has strict channels: local mode exits `0` with distribution issues as `WARN`; `--developer-id` exits `1` on this app because Developer ID identity, Developer ID app signature, hardened runtime, and clean Gatekeeper evidence are missing; `--app-store` exits `1` because App Sandbox is disabled.
- `scripts/notarize_insightkit_release.sh` now provides the final direct-distribution gate: it refuses to contact Apple unless `scripts/release_preflight.sh --developer-id <app>` passes, creates a notary submission zip, runs `xcrun notarytool submit --wait`, staples with `xcrun stapler`, validates codesign/Gatekeeper/preflight, and emits a `macos-developer-id-notarized-stapled-*` public zip.
- Current notarization attempt with the latest local QA app exits before upload at Developer ID preflight, as intended. No notarization is claimed without a Developer ID signed app and notary credentials.
- `scripts/release_preflight.sh` now checks packaged `Info.plist` usage descriptions, the privacy/sandbox release note, and the App Store privacy policy URL gate. Local mode records missing privacy policy URL as `WARN`; `--app-store` records it as `FAIL`.
- `scripts/release_preflight.sh` now also checks `docs/release-privacy-policy-draft.md` and `docs/release-app-store-privacy-answers.md`. Local and App Store preflight both report these two release-owner inputs as `PASS`.
- `scripts/release_preflight.sh --app-store /Users/yann.jy/Applications/InsightKit.app` exits `1` because the canonical local app is not signed with a Mac App Store distribution identity, does not embed sandbox/user-selected/bookmark entitlements, and `INSIGHTKIT_PRIVACY_POLICY_URL` is not configured.
- App Store entitlements draft exists at `macos/InsightKitApp/InsightKitApp.AppStore.entitlements` and passes `plutil -lint`; it enables App Sandbox, audio input, camera, user-selected read/write files, app-scoped bookmarks, and network client for optional BYOK providers.
- `scripts/package_insightkit_app.sh` now accepts `--entitlements <path>` and verifies embedded true entitlements after signing; `scripts/release_preflight.sh --app-store` checks source entitlements, packaged embedded entitlements, Mac App Store distribution signing identity/signature, and privacy policy URL.
- App Store sandbox evidence: `logs/diagnostics/2026-05-24/app-store-sandbox-preflight-proof.json`. An ad-hoc sandbox-entitlements packaging probe passes the embedded-entitlements gate but is explicitly not a distributable App Store build.
- Sandbox records-root preparation evidence: `logs/diagnostics/2026-05-24/sandbox-records-root-proof.json`. `RecordsIndexService` now defaults to `~/Library/Application Support/InsightKit/Records` when sandboxed or test-forced, persists custom roots with app-scoped security-scoped bookmarks, wraps record I/O with access tokens, and passes the selected root to the Python sidecar via `INSIGHTKIT_RECORDS_ROOT`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` reports `valid on disk` and `satisfies its Designated Requirement`.
- Smart-minutes UI build package `/private/tmp/insightkit-package-smart-minutes-202605241853/InsightKit.app` was installed to `/Users/yann.jy/Applications/InsightKit.app`; installed build `20260524185320` passed strict codesign and local release preflight.
- Latest canonical app was replaced from `/private/tmp/insightkit-release-0.1.0-local.ZHnide/app/InsightKit.app`; installed build `20260524221829` passed strict codesign and local release preflight.
- `spctl -a -vv /Users/yann.jy/Applications/InsightKit.app` is accepted only with `override=security disabled`; this is local-machine evidence, not clean Gatekeeper distribution evidence.
- `/private/tmp/insightkit-package/InsightKit.app` is the reliable packaging verification path. `dist/macos/InsightKit.app` can receive Desktop/FileProvider `FinderInfo` or `fileprovider` xattrs, so it is retained as an intermediate artifact but is not the strict distribution proof path.
- `scripts/release_preflight.sh` records the current state: Developer ID missing, local Apple Development identity present, strict codesign passed, hardened runtime absent, `notarytool` available, App Sandbox disabled.
- `security find-identity -v -p codesigning` currently shows two `Apple Development` identities only. Based on Apple's membership and Developer ID documentation, direct public distribution and App Store submission require user/account-holder intervention: paid/active Apple Developer Program access, distribution signing identity creation, notarization/App Store metadata, and privacy policy URL.

## Release Readiness Gate

Checked:

- App icon present in source and installed bundle.
- Bundle ID, version, and build number present.
- Microphone, camera, and screen-capture usage descriptions present.
- Secret pattern scan over source did not find common hardcoded API key or private-key patterns.
- Canonical installed app path verified.
- Local package and installed app strict code-sign verification passed.
- Release preflight script exists and distinguishes local validation from Developer ID / App Store distribution readiness.
- Release zip script exists and no longer presents local QA zips as public GitHub Releases.
- Notarization/stapling script exists and has a failing pre-upload gate in the current no-Developer-ID environment.
- Privacy/sandbox release note exists at `docs/release-privacy-sandbox.md`, and README no longer claims the InsightKit-capable project is always fully offline.
- Privacy policy draft exists at `docs/release-privacy-policy-draft.md`, and App Store privacy answer draft exists at `docs/release-app-store-privacy-answers.md`.
- Missing media in a persisted record is now a visible app state covered by Swift tests.
- Import failure / transcription failure in the import page is now a visible app state covered by Swift tests.
- Long import processing now has visible progress-stage text, user cancellation, and visible cancellation-failure feedback covered by Swift tests.
- Import provider/API-key missing or unavailable state now has a visible local-fallback notice covered by Swift tests.
- Missing ASR model files are now a visible Settings state covered by Swift tests.

Still not release-complete:

- Direct distribution requires paid/active Apple Developer Program access, a `Developer ID Application` certificate, hardened runtime, notarization, stapling, and a notarized/stapled public archive.
- Direct distribution also requires a notarytool credential path, preferably a keychain profile created by `xcrun notarytool store-credentials insightkit-notary`.
- Mac App Store distribution requires App Sandbox enabled, security-scoped file access/bookmarks, entitlements review, App Review metadata, and privacy details.
- App Store owner still needs to publish a real privacy policy URL and enter final privacy answers in App Store Connect; the repo now contains drafts, not a public URL or submitted metadata.
- Current local SwiftPM package has no embedded entitlements.
- Desktop/FileProvider-backed output paths can attach xattrs that make strict code-sign verification fail; use `/private/tmp/insightkit-package` or the canonical installed app for packaging verification.
- PDF dependency consolidation is now resilient: persisted record exports are native Swift PDF; RPC fallback uses WeasyPrint when present and a built-in sidecar text PDF writer when WeasyPrint is absent. Remaining work is quality hardening of the fallback layout, not a hard dependency blocker.
- Real configured cloud provider verification is not complete; no-key/local fallback behavior remains the defensible default.
- XCUITest automation is blocked in this environment by macOS LocalAuthentication cancellation, even though manual Computer Use E2E passed.

## Mentioned Proof File

The user mentioned `026-05-24/native-settings-import-proof.json` / `native-settings-import-proof.json`. The originally mentioned path was absent, so the current bounded GUI/import/recovery/release-setting pass was captured in `logs/diagnostics/2026-05-24/native-settings-import-proof.json`. It validates with `python3 -m json.tool` and references the canonical app build, Computer Use observations, screenshot artifacts, persisted record/export paths, quit proof, crash-report check, and Developer ID distribution blocker.
