# Agent workflow and tool boundaries

This repository follows the public [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) principles and [Symphony specification](https://github.com/openai/symphony/blob/main/SPEC.md), adapted to a native macOS product. The goal is equivalent agent legibility and feedback loops, not a literal web-service tool stack.

## One linked workflow

| Layer | Role | Tool | Authoritative data | Must not do |
| --- | --- | --- | --- | --- |
| Human planning | Choose objectives, priority, and review attention | Linear project | Portfolio status and links | Duplicate acceptance criteria, blockers, or execution labels |
| Execution intake | Define a runnable task contract | GitHub Issues | Goal, Context, Boundary, Acceptance, Verification, blockers, human gates, triage label | Merge code or silently authorize `ready-for-agent` |
| Durable scheduling | Poll, retry, and isolate workspaces | Local Symphony | Runtime state and per-issue workspace | Decide product priority or bypass preflight |
| Implementation | Plan, edit, run tools, review, and open PRs | Codex App Server using the operator's ChatGPT subscription | Current checkout, repository docs, issue, tool results | Receive tracker secrets or treat chat as durable truth |
| Application proof | Drive and inspect the native app | XCUITest, Accessibility, XCTest screenshots, `screencapture` | `.xcresult`, screenshots, optional journey video | Record the user's display without explicit opt-in |
| Logs | Inspect native and sidecar events | macOS Unified Logging, NDJSON, `rg`/`jq` | `unified.ndjson` and bounded app logs | Require Loki merely to query local native logs |
| Metrics | Enforce journey duration and test evidence | `metrics.json`, XCTest durations, `jq` | Per-run proof metrics | Claim production telemetry from test timing |
| Trace | Diagnose an evidenced performance problem | Instruments and `xctrace` | Per-run `.trace` | Trace every task by default |
| Deterministic gates | Re-run build, lint, unit, UI, package, and release checks | Ordinary GitHub Actions | Check conclusions and uploaded artifacts | Run a second hosted coding agent or use Copilot credits |
| Delivery and acceptance | Review the diff and evidence | GitHub PR plus `ready-for-human` | Commit, CI, review comments, proof paths | Treat a green build as product acceptance |

For OpenAI's browser product, CDP, DOM snapshots, LogQL, PromQL, and an ephemeral observability stack make the app legible. InsightKit's native equivalent is XCUITest/Accessibility, Unified Logging, JSON metrics, and Instruments. Add Loki, Prometheus, or OpenTelemetry only when a real multi-process or production query cannot be answered by these native per-run artifacts.

## Linear boundary

The Linear project is the human cockpit. It holds the objective, priority, status summary, and links to the repository, GitHub Issues, PRs, and operating docs. GitHub Issues remain the single machine-dispatch source under ADR 0007.

Project: [InsightKit Agent Harness](https://linear.app/yannjy/project/insightkit-agent-harness-6deb89d380ba)

Do not two-way sync issue status. If the team later chooses the public Symphony specification's native Linear tracker, replace ADR 0007, migrate open work once, and remove GitHub dispatch labels in the same change.

## Operating entry points

```bash
python3.11 scripts/agent_harness.py doctor --profile symphony
python3.11 scripts/agent_harness.py issue-preflight --issue <number>
python3.11 scripts/agent_harness.py verify --issue <number> --mode full
python3.11 scripts/harness_maintenance.py plan --task due
python3.11 scripts/harness_maintenance.py enqueue --task due
./scripts/run_symphony.sh
```

For visible behavior, use the repository `native-app-proof` skill. For recurring lessons, use `promote-feedback`.
