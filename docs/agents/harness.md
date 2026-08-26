# InsightKit Agent Harness

The repository supplies missing capabilities around Codex's built-in thread persistence, sandbox, tools, and skills. Linear owns project and task truth; synchronized GitHub Issues are the execution mirror polled by local Symphony; Codex executes through the operator's ChatGPT subscription; ordinary Actions verify deterministically.

## Entry points

```bash
./scripts/agent_bootstrap.sh
python3.11 scripts/agent_harness.py doctor
python3.11 scripts/agent_harness.py doctor --profile app-proof
python3.11 scripts/agent_harness.py issue-preflight --issue <number>
python3.11 scripts/agent_harness.py verify --issue <number> --mode full
python3.11 scripts/harness_maintenance.py plan --task due
python3.11 scripts/harness_maintenance.py enqueue --task due
python3.11 scripts/harness_maintenance.py install-launch-agent --repo-root <canonical-main-checkout>
python3.11 scripts/harness_maintenance.py install-symphony-launch-agent --repo-root <canonical-main-checkout>
./scripts/run_symphony.sh
```

`agent_harness.py` is the single Interface for local harness checks. Its implementation reuses existing tests and verifiers rather than duplicating release logic.

Before starting Symphony, create a dedicated fine-grained token limited to this repository with read-only Issues and metadata access. Supply it as `SYMPHONY_GITHUB_TOKEN` or store it in macOS Keychain under service `com.autotranscribe.symphony.github-token` and account `symphony`. The launcher does not reuse the operator's broad `gh` token, and Codex inherits only the native core shell environment. It explicitly removes `OPENAI_API_KEY`, so Codex uses the operator's ChatGPT login. Codex's own GitHub writes use its separately authenticated `gh` session.

## Control and feedback flow

1. A human or Codex creates and prioritizes the task in the canonical Linear project; native sync creates the GitHub execution mirror.
2. Deterministic preflight validates the synchronized GitHub body and authorizes only complete, unblocked `ready-for-agent` work.
3. Symphony creates an isolated clone from the locally synchronized canonical `main`, resets `origin` to GitHub, and resumes the Codex App Server thread on retry.
4. Codex implements or investigates using repository Context, ADRs, skills, and tools.
5. Visible macOS work records XCUITest screenshots, optional video, unified logs, JSON metrics, optional Instruments trace, and `proof.json`.
6. Harness verification records commands and results in `logs/harness/<run>/manifest.json`; an independent local Codex review examines code changes.
7. GitHub Actions reruns deterministic build, test, UI, package, and release checks only.
8. The shared label moves to `ready-for-human`. A linked PR may update detailed status through configured native PR automation; otherwise a human updates Linear during handoff, accepts, and merges. Do not claim a detailed Linear status change unless it is verified on Linear.

## Resource isolation

Symphony runs at two concurrent isolated workspaces. `exclusive-macos` commands share the installed app, TCC, canonical Records, sockets, capture devices, or performance environment and must serialize through:

```bash
python3.11 scripts/agent_harness.py lock \
  --resource installed-app --timeout 1800 -- \
  bash scripts/sync_insightkit_app.sh
```

The standard-library file lock is released automatically if the process exits.

## Evidence contract

Every handoff names the issue, commit, changed files, gate commands and results, CI checks, PR or no-change conclusion, and unresolved human-only acceptance. Manifests never include environment variables, credentials, or full process environments.

## Native application legibility

`scripts/run_uitests.sh` creates a per-run proof directory next to its `.xcresult`. It contains kept XCTest screenshots, bounded macOS Unified Logging output, test-duration metrics, and `proof.json`. CI also opts into a main-display journey video because the runner is isolated. Local video recording is opt-in because it can capture unrelated screen content. Instruments capture is opt-in for evidenced performance work.

For this native macOS app, these are the application-legibility equivalents:

- CDP and DOM snapshots → XCUITest, Accessibility identifiers, XCTest screenshots, optional journey video.
- LogQL → bounded Unified Logging NDJSON queried with `rg` or `jq`.
- PromQL → per-run `metrics.json` queried with `jq` and enforced by test thresholds.
- OpenTelemetry traces → Instruments `.trace` recorded with `xctrace` for an explicit performance question.

Use the `native-app-proof` skill for the exact before/after workflow. Xcode is required for XCUITest, `xcresulttool`, and `xctrace`; a Mac without full Xcode cannot claim local app proof.

## Local recurring agents

`scripts/harness_maintenance.py` replaces hosted Agentic Workflows. One macOS LaunchAgent runs it daily at 09:00; another keeps Symphony running across login and process failure. The maintenance schedule catches up every current-week task due by that weekday, and a period marker prevents duplicates. Monday gardens documentation, Tuesday promotes one repeated feedback invariant, and Friday repairs one golden-principle deviation. Each generated GitHub Issue is an allowed machine-ingress exception: native sync creates the Linear Backlog task, which must be assigned to the canonical project during triage.

Preview or enqueue manually:

```bash
python3.11 scripts/harness_maintenance.py plan --task due
python3.11 scripts/harness_maintenance.py enqueue --task due
```

Ordinary CI remains intentionally non-agentic. It provides Python and shell syntax lint, Python and Swift unit tests, XCUITest proof, local release packaging, and release preflight. Developer ID, notarization, App Store signing, deployment, Linear/GitHub integration changes, and product acceptance remain explicit human gates when credentials or judgment are required.

## Autonomy ceiling

Agents may create branches, commits, PRs, comments, and evidence within the linked task. They do not merge, close issues, publish releases, use Apple credentials, or approve their own work.
