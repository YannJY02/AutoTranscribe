# macOS product-proof pyramid

[`claim-matrix.json`](./claim-matrix.json) is the runnable claim-to-rung contract. Use the first valid rung: deterministic Swift/Python checks, runtime integration, packaged-app smoke, XCUITest for uniquely visible claims, then a bounded manual-only observation. Deterministic commands must not launch or install the app, use the pointer, capture a display, open a socket, touch canonical Records, or take the installed-app lock.

## Fresh visible proof command

Run this repository command from a clean output name. It runs only the selected uniquely visible claims, serializes the exclusive leg, records the source/build/scenario, and retains the first result without retrying:

```bash
proof_root="logs/harness/GH-69/product-proof-$(date +%Y%m%d-%H%M%S)"
python3.11 scripts/agent_harness.py lock --resource installed-app --timeout 1800 -- \
  env INSIGHTKIT_UITEST_PROOF_ROOT="$proof_root" \
      INSIGHTKIT_UITEST_SCENARIO="product-proof-visible-claims" \
      INSIGHTKIT_UITEST_SELECTED_TESTS="HomeViewTests/testHomeScreenShowsThreeCards,LiveWorkspaceTests/testSingleEntryGeneratedReviewFlowCoversPrimaryInteractions,ImportWorkspaceTests/testThreePanelLayoutVisible,RecordsPersistenceUITests/testRecentRecordSearchAndRelaunchPersistence" \
      INSIGHTKIT_UITEST_EXPECTED_SCREENSHOTS="target-window" \
      ./scripts/run_uitests.sh
```

Do not set `INSIGHTKIT_UITEST_RECORD_VIDEO=1` locally: that records the main display and marks the proof non-privacy-safe. Kept XCTest attachments come from `app.windows.firstMatch.screenshot()`, retain the target window's original pixels, and exclude the cursor, desktop, and other applications. Synthetic UI-test records are isolated from canonical Records. The raw `.xcresult` is required while the proof is finalized but must stay outside the privacy-safe proof root; target-window attachments and any exported test summary are retained and sanitized instead.

Inspect `proof.json` first. A passing process is rejected unless its status is `passed`, every selected test passed, an `.xcresult` exists, bounded unified-log JSON exists, and at least one expected target-window screenshot exists. `manifest.json` records the source revision, the generated UI-test app's exact `CFBundleVersion`, scenario, result, and SHA-256 of every file. Text logs redact personal home prefixes, bearer tokens, and high-confidence API keys. Automatic classification recognizes toolchain/test defects and macOS authorization/capture failures; it does not assume that an XCTest assertion proves an app defect. After inspecting retained evidence, pass `--failure-classification app-defect` to `native_app_proof.py` only when the failure demonstrates product behavior (or `test-defect` when it demonstrates test behavior), then re-finalize into another fresh root without rerunning the UI. Do not retry until a changed repair is evidenced.

## Manual-only record

Copy the matching matrix item and replace its build with the exact `CFBundleVersion`. Record the exact scenario, expected observation, actual observation, and remaining uncertainty. Leave `result` as `unobserved` until the observation occurs; an unobserved item is never a pass. Do not change TCC, record the main display, use canonical Records, or make subjective readability/media judgments during unattended proof.
