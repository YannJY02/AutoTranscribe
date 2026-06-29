# Live Workspace can crash when starting microphone capture

Status: ready-for-human

## Parent

- `.scratch/manual-qa-2026-06-25/PRD.md`

## What happened

InsightKit sometimes crashes during owner QA. The owner cannot reproduce it reliably every time.

The attached macOS crash report shows the installed app exited with `EXC_CRASH (SIGABRT)` while starting microphone capture for a Live Workspace session.

## What I expected

Starting a Live Workspace session should never terminate the app.

If microphone capture cannot be started because the audio input is unavailable, already tapped, misconfigured, or in a bad system state, InsightKit should keep running and show a recoverable capture or permission message.

## Steps to reproduce

1. Launch the installed InsightKit app.
2. Open Live Workspace.
3. Start a live session using microphone or mixed audio.
4. Repeat normal QA actions around starting or restarting capture.
5. Observe that the app can occasionally crash instead of showing an in-app error.

## Blocked by

None - can start immediately.

## Additional context

Reported during owner-led QA after issue 26 owner retest passed.

The crash is intermittent, but the crash report is actionable:

- installed build: `20260626163854`;
- exception type: `EXC_CRASH (SIGABRT)`;
- termination: `Abort trap: 6`;
- triggered thread: background cooperative queue;
- crash signature: microphone capture start calls `AVAudioNode.installTap`, which raises an Objective-C exception inside AVFAudio.

This should be diagnosed as an app-stability issue, not as a normal playback UX bug.

## Comments

### 2026-06-26 - Manual QA

The owner reported intermittent app crashes and attached a macOS crash report.

Initial classification: `ready-for-agent`.

Why:

- The crash is not stable enough for exact reproduction steps yet, but the crash report gives a concrete signature.
- App termination is higher priority than the current playback UX bundle because it can interrupt all owner QA.
- The first diagnosing loop should focus on making microphone capture startup exception-safe and repeat-start safe.

### 2026-06-26 - Diagnosing Bugs

Diagnosis:

- The crash report points to `AVAudioNode.installTap` during `MicCaptureService.start()`.
- The most likely app-side cause was repeated or overlapping microphone starts before the previous start had fully marked capture as active.
- `installTap` is not a normal recoverable Swift error surface; if the same audio input is tapped in a bad state, AVFAudio can terminate the process.

Fix:

- Wrapped the concrete `AVAudioEngine` access behind `MicCaptureEngineProviding` so microphone startup can be tested without using real hardware.
- Added a dedicated serial control queue for microphone start/stop graph mutations.
- Kept duplicate `start()` calls idempotent: once capture is active, later starts return without installing another tap.
- On startup failure, the service removes any tap, stops the engine, resets the capture gate, and allows a later retry.
- Added a stricter invalid-input guard for zero-channel or zero-sample-rate input formats.

Verification:

- `swift test --package-path macos/InsightKitApp --filter MicCaptureServiceTests` passed.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` passed.
- `swift test --package-path macos/InsightKitApp` passed: 170 tests, 0 failures.
- `bash scripts/sync_insightkit_app.sh` installed build `20260626172647`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app` passed.

Human retest:

- Run installed build `20260626172647`.
- Start Live Workspace with microphone input.
- Repeatedly start, stop, and restart capture.
- Expected result: the app should not crash; if microphone startup fails, it should remain in-app and recoverable.

### 2026-06-26 - Owner retest pending

The owner has not repeatedly tested this path yet. Keep this issue as a `ready-for-human` retest item until microphone capture startup has been exercised enough times to confirm the intermittent crash is gone.

### 2026-06-27 - Owner retest failed on installed build 20260627145522

Status changed back to `ready-for-agent`.

The owner attached a new macOS crash report from installed build `20260627145522`.

New crash evidence:

- app version: `0.1.0 (20260627145522)`;
- crash time: `2026-06-27 15:10:41 +0200`;
- exception type: `EXC_CRASH (SIGABRT)`;
- termination: `Abort trap: 6`;
- triggered queue: `InsightKit.MicCapture.Control`;
- crash signature: microphone capture startup calls `AVAudioNode.installTap`, which raises an Objective-C exception inside AVFAudio.

Why this reopens the issue:

- The latest crash has the same user-facing boundary as the original issue: starting Live Workspace microphone capture can terminate the app instead of showing a recoverable capture message.
- The previous fix made duplicate starts and normal Swift errors safer, but this report shows AVFAudio can still abort during tap installation in the installed app.

Next fix direction:

- Treat `AVAudioNode.installTap` as an Objective-C exception risk, not only a Swift `throws` boundary.
- Make microphone capture startup exception-safe and recoverable before marking this issue `ready-for-human` again.
- Preserve the user expectation that failed microphone capture never terminates InsightKit.

### 2026-06-27 - Obj-C exception-safe microphone startup fix installed

Status changed back to `ready-for-human`.

Diagnosis:

- The latest crash was not only a duplicate-start or Swift error-path failure.
- `AVAudioNode.installTap` can raise an Objective-C `NSException`; without an Obj-C catch boundary, Swift cannot recover and the process aborts.
- The microphone capture path therefore needed an exception bridge around tap installation, plus the existing serial start/stop gate.

Fix:

- Added `InsightKitObjCShims`, a small Objective-C SwiftPM target that catches `NSException` and returns an `NSError`.
- Added `ObjCExceptionBridge.perform` for Swift callers.
- Wrapped the concrete `AVAudioEngine.inputNode.installTap` call in that bridge.
- Converted caught tap-installation exceptions into a recoverable `MicCaptureEngineError.inputTapInstallationFailed` with a user-facing microphone startup message.
- Kept the prior duplicate-start, cleanup, retry, and invalid-input protections in place.

Verification:

- Red-capable proof: a standalone Swift subprocess raising `NSInvalidArgumentException` exits with `Abort trap: 6`, matching the crash class that a normal XCTest cannot safely host.
- `swift test --package-path macos/InsightKitApp --filter MicCaptureServiceTests`, 5 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp --filter LiveSessionViewModelTests` initially hit one signal-11 runner exit; the named test and a full rerun both passed, 49 tests, 0 failures.
- `swift test --package-path macos/InsightKitApp`, 211 tests, 0 failures.
- `git diff --check`, passed.
- `bash -n scripts/package_insightkit_app.sh`, passed.
- `bash -n scripts/release_preflight.sh`, passed.
- Installed sync: `./scripts/sync_insightkit_app.sh --skip-tests`, build `20260627153026`.
- `plutil -p logs/workflow/latest_sync.json` reports `status = success`, `build_version = 20260627153026`, and install path `/Users/yann.jy/Applications/InsightKit.app`.
- `/Users/yann.jy/Applications/InsightKit.app/Contents/Info.plist` has `CFBundleVersion = 20260627153026`.
- `codesign --verify --deep --strict --verbose=2 /Users/yann.jy/Applications/InsightKit.app`, passed.

Human retest:

- Run installed build `20260627153026`.
- Open Live Workspace.
- Start microphone capture or mixed audio repeatedly, including stop/start cycles.
- Expected result: InsightKit should not crash. If AVFAudio refuses tap installation, the app should remain open and surface a recoverable microphone startup error.
