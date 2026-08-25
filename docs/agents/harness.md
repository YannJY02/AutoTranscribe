# InsightKit Agent Harness

The repository supplies missing capabilities around Codex's built-in thread persistence, sandbox, tools, and skills. GitHub is the control plane; Symphony dispatches; deterministic Actions verify; Agentic Workflows advise and write only through safe outputs.

## Entry points

```bash
./scripts/agent_bootstrap.sh
python3.11 scripts/agent_harness.py doctor
python3.11 scripts/agent_harness.py issue-preflight --issue <number>
python3.11 scripts/agent_harness.py verify --issue <number> --mode full
./scripts/run_symphony.sh
```

`agent_harness.py` is the single Interface for local harness checks. Its implementation reuses existing tests and verifiers rather than duplicating release logic.

Before starting Symphony, create a dedicated fine-grained token limited to this repository with read-only Issues and metadata access. Supply it as `SYMPHONY_GITHUB_TOKEN` or store it in macOS Keychain under service `com.autotranscribe.symphony.github-token` and account `symphony`. The launcher does not reuse the operator's broad `gh` token, and Codex inherits only the native core shell environment. Codex's own GitHub writes use its separately authenticated `gh` session.

## Control and feedback flow

1. A human or triage workflow records intent in a GitHub Issue.
2. Deterministic preflight authorizes only complete, unblocked `ready-for-agent` work.
3. Symphony creates an isolated clone and resumes the Codex App Server thread on retry.
4. Codex implements or investigates using repository Context, ADRs, skills, and tools.
5. Harness verification records commands and results in `logs/harness/<run>/manifest.json`.
6. GitHub Actions reruns deterministic checks; an on-demand Agentic Workflow supplies independent review.
7. The issue moves to `ready-for-human`; a human accepts and merges.

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

## GitHub Agentic Workflows

The execution boundary is deliberate: Symphony-started Codex uses the operator's existing local Codex authentication, while GitHub-hosted Agentic Workflows use Copilot with the repository-pinned `gpt-4.1` model. Do not copy Codex's local authentication cache into GitHub secrets. A hosted workflow can instead run the Codex engine with `CODEX_API_KEY` or `OPENAI_API_KEY`, or with GitHub-hosted inference through a `copilot/...` model and `copilot-requests: write`; neither path consumes a personal ChatGPT subscription.

- Issue triage may apply `needs-triage` or `needs-info`, but never `ready-for-agent`.
- `/agent-review` performs an independent PR review and comments through a sanitized safe output.
- Doc gardening and CI failure investigation create at most one deduplicated issue per run.
- Agent jobs remain read-only; GitHub writes happen in separate safe-output jobs.

Ordinary CI provides Python and shell syntax lint, generated-workflow actionlint, Python and Swift unit tests, XCUITest, local release packaging, and release preflight. Developer ID, notarization, App Store signing, and deployment remain explicit human gates because they require owner credentials and channel decisions.

Compile after editing workflow markdown, then run the lock check so CI executes exactly the reviewed source:

```bash
gh aw compile --strict --validate
python3.11 scripts/agent_harness.py agentic-lock-check
```

## Autonomy ceiling

Agents may create branches, commits, PRs, comments, and evidence within the linked task. They do not merge, close issues, publish releases, use Apple credentials, or approve their own work.
