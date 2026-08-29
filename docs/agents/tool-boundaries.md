# Agent workflow and tool boundaries

This repository follows the public [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) principles and [Symphony specification](https://github.com/openai/symphony/blob/main/SPEC.md), adapted to a native macOS product. The goal is equivalent agent legibility and feedback loops, not a literal web-service tool stack.

## One linked workflow

| Layer | Role | Tool | Authoritative data | Must not do |
| --- | --- | --- | --- | --- |
| Task and project truth | Choose objectives, scope, priority, detailed status, and review attention | Linear project and issues | Task contract, project membership, priority, relations, detailed status, shared labels | Maintain a second GitHub Project board |
| Execution mirror | Expose runnable tasks to repository automation | Synced GitHub Issues | Repository issue number, coarse open/closed state, synchronized task fields | Override conflicting Linear task state or silently authorize `ready-for-agent` |
| Durable scheduling | Poll, retry, and isolate workspaces | Local Symphony | Runtime state and per-issue workspace | Decide product priority or bypass preflight |
| Implementation | Plan, edit, run tools, review, and open PRs | Codex App Server using the operator's ChatGPT subscription | Current checkout, repository docs, issue, tool results | Receive tracker secrets or treat chat as durable truth |
| Application proof | Drive and inspect the native app | XCUITest, Accessibility, XCTest screenshots, `screencapture` | `.xcresult`, screenshots, optional journey video | Record the user's display without explicit opt-in |
| Logs | Inspect native and sidecar events | macOS Unified Logging, NDJSON, `rg`/`jq` | `unified.ndjson` and bounded app logs | Require Loki merely to query local native logs |
| Metrics | Enforce journey duration and test evidence | `metrics.json`, XCTest durations, `jq` | Per-run proof metrics | Claim production telemetry from test timing |
| Trace | Diagnose an evidenced performance problem | Instruments and `xctrace` | Per-run `.trace` | Trace every task by default |
| Deterministic gates | Re-run build, lint, unit, UI, package, and release checks | Ordinary GitHub Actions | Check conclusions and uploaded artifacts | Run a second hosted coding agent or use Copilot credits |
| Delivery and acceptance | Review the diff and evidence | GitHub PR plus `ready-for-human` | Commit, CI, review comments, proof paths | Treat a green build as product acceptance |

For OpenAI's browser product, CDP, DOM snapshots, LogQL, PromQL, and an ephemeral observability stack make the app legible. InsightKit's native equivalent is XCUITest/Accessibility, Unified Logging, JSON metrics, and Instruments. Add Loki, Prometheus, or OpenTelemetry only when a real multi-process or production query cannot be answered by these native per-run artifacts.

## Linear and GitHub boundary

Project: [InsightKit / AutoTranscribe](https://linear.app/yannjy/project/insightkit-autotranscribe-a2f3a38cd145)

Linear is the canonical planning and task-state cockpit. Native two-way sync supplies the GitHub issue mirror required by the current GitHub-backed Symphony adapter. GitHub remains authoritative only for repository delivery facts: commits, PRs, reviews, checks, merge state, and attached proof.

Native sync does not mirror Linear project membership, priority, cycles, milestones, or detailed workflow states. GitHub-created issues therefore enter the Linear team Backlog without a project and must be admitted to the canonical project in Linear. GitHub comments appear in a dedicated synced Linear thread; reply inside that thread for Linear-to-GitHub publication, while other Linear comments stay private. See ADR 0008.

## Operating entry points

```bash
python3.11 scripts/agent_harness.py doctor --profile symphony
python3.11 scripts/agent_harness.py issue-preflight --issue <number>
python3.11 scripts/agent_harness.py verify --issue <number> --mode full
python3.11 scripts/harness_maintenance.py plan --task due
python3.11 scripts/harness_maintenance.py enqueue --task due
python3.11 scripts/harness_maintenance.py install-symphony-launch-agent --repo-root <canonical-main-checkout>
./scripts/run_symphony.sh
```

For visible behavior, use the repository `native-app-proof` skill. For recurring lessons, use `promote-feedback`.
