---
name: native-app-proof
description: Capture before/after proof for visible InsightKit macOS behavior using XCUITest, screenshots, screen recording, unified logs, metrics, and optional Instruments traces.
---

# Native app proof

Use this for installed-app bugs, visible behavior, critical journeys, or performance claims.

1. Put each run under the shared `installed-app` resource lock.
2. For a bug, capture the failing state before editing and the repaired state afterward. Use separate `INSIGHTKIT_UITEST_PROOF_ROOT` directories.
3. Run `scripts/run_uitests.sh`; it exports kept XCTest screenshots, unified logs, test metrics, the `.xcresult`, and `proof.json`.
4. Set `INSIGHTKIT_UITEST_RECORD_VIDEO=1` only on an isolated runner or when full-main-display capture is explicitly acceptable. Set `INSIGHTKIT_UITEST_RECORD_TRACE=1` only for a performance or trace question.
5. Read `proof.json`, then inspect only the relevant screenshot, log matches, metric, or trace. A zero exit code without required screenshots is not valid UI proof.

Example:

```bash
python3.11 scripts/agent_harness.py lock \
  --resource installed-app --timeout 1800 -- \
  env INSIGHTKIT_UITEST_PROOF_ROOT="logs/harness/$ISSUE/after" \
      INSIGHTKIT_UITEST_RECORD_VIDEO=1 \
      ./scripts/run_uitests.sh
```

Do not claim local UI verification when Xcode, Accessibility, Screen Recording, or the required test route is unavailable. Record the missing capability as a human gate; CI evidence may verify the code path but does not prove this Mac's installed-app state.
