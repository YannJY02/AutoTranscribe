---
tracker:
  kind: github
  provider:
    repo: YannJY02/AutoTranscribe
    token: $GITHUB_TOKEN
  required_labels:
    - ready-for-agent
  active_states:
    - open
  terminal_states:
    - closed
polling:
  interval_ms: 30000
observability:
  # The HTTP dashboard and structured logs remain available; the terminal renderer is not needed under launchd.
  dashboard_enabled: false
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  timeout_ms: 300000
  after_create: |
    unset SYMPHONY_AGENT_GITHUB_TOKEN SYMPHONY_GITHUB_TOKEN GITHUB_TOKEN GH_TOKEN OPENAI_API_KEY
    repo_source="${SYMPHONY_REPO_SOURCE:-https://github.com/YannJY02/AutoTranscribe.git}"
    git clone --depth 1 --no-local "$repo_source" .
    git remote set-url origin https://github.com/YannJY02/AutoTranscribe.git
    if [ -n "${SYMPHONY_BOOTSTRAP_REF:-}" ]; then
      git fetch --depth 1 origin "$SYMPHONY_BOOTSTRAP_REF"
      git checkout --detach FETCH_HEAD
    fi
    ./scripts/agent_bootstrap.sh
  before_run: |
    "$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/symphony_issue_gate.sh"
  after_run: |
    "$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/symphony_after_run.sh"
agent:
  # ponytail: two isolated workspaces; exclusive native commands still serialize through the resource lock.
  max_concurrent_agents: 2
  max_turns: 30
codex:
  # GitHub preflight and claim run in before_run; Codex receives no tracker or agent credential.
  command: env -u SYMPHONY_AGENT_GITHUB_TOKEN -u SYMPHONY_GITHUB_TOKEN -u GITHUB_TOKEN -u GH_TOKEN -u OPENAI_API_KEY -u SYMPHONY_CONTROLLER_REPO_ROOT -u SYMPHONY_PREFLIGHT_EVIDENCE_ROOT -u SYMPHONY_PYTHON3 -u SYMPHONY_REAL_GH -u SYMPHONY_SECURITY "$SYMPHONY_CONTROLLER_REPO_ROOT/scripts/symphony-bin/codex" --config shell_environment_policy.inherit=core app-server
  read_timeout_ms: 120000
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are working autonomously on GitHub issue `{{ issue.identifier }}`.

{% if attempt %}
This is continuation attempt {{ attempt }}. Resume from the existing workspace and issue comments. Do not repeat verified work.
{% endif %}

Issue:

- Title: {{ issue.title }}
- State: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:

{% if issue.description %}
{{ issue.description }}
{% else %}
No description was provided.
{% endif %}

Work only inside this repository copy. This is unattended: do not ask the user questions and do not touch paths outside the workspace.

1. The mandatory GitHub/Linear issue preflight and GitHub claim completed in the fatal `before_run` hook. If either had failed, this agent would not have started. Do not repeat that network check inside the Codex sandbox.
2. Read `AGENTS.md`, `docs/agents/harness.md`, `docs/agents/tool-boundaries.md`, `CONTEXT-MAP.md`, relevant context docs and ADRs, and repository skills that match the task. The synchronized issue description above is the unattended execution contract; do not assume access to Linear-only project, priority, or detailed-status fields.
3. Do not make GitHub writes from the Codex sandbox. The controller owns duplicate-PR checks, branch creation, GitHub evidence, labels, comments, and human handoff.
4. Work only in the prepared issue workspace; do not create temporary Git metadata or GitHub commit objects.
5. Reproduce the problem or establish the requested baseline. For visible macOS bugs, use the `native-app-proof` skill and preserve before evidence before editing. Implement the smallest root-cause change and the smallest regression test first for non-trivial behavior.
6. Run `python3.11 scripts/agent_harness.py verify --issue "{{ issue.identifier }}" --mode full`. Run issue-specific acceptance checks too. For `exclusive-macos`, wrap installed-app, GUI, capture, or performance commands with `agent_harness.py lock --resource installed-app -- ...`; visible behavior requires after evidence and `proof.json`.
7. Review the diff for correctness, secrets, unrelated changes, architecture conflicts, and missing evidence. If code changed, request one independent agent review and resolve every blocking finding.
8. After a passed full Harness manifest and independent review, write the bounded controller handoff with `python3.11 scripts/agent_harness.py handoff --issue "{{ issue.identifier }}" --manifest <manifest-path> --summary "<one-line result>" --review-status clear --human-gate "Review and merge the pull request."`. The host treats worker results as advisory: it copies only the manifest-bound regular files into a protected clone based on the immutable preflight revision, never executes worker code or Git metadata, and creates or refreshes the `codex/*` branch and PR. Isolated current-head GitHub CI supplies the authoritative recheck before human handoff. For an investigation with no changed files, use `--review-status not-required --no-change`; the report still requires human acceptance. Do not put command output or secrets in the handoff.
9. If the issue is an investigation or canary and no repository change is needed, do not manufacture a commit or PR; hand the exact evidence to the controller.
10. Never merge a PR or close an issue. Do not claim a detailed Linear status change unless it is verified on Linear. The controller owns the synchronized GitHub and Linear handoff after validating your evidence.
11. If a true external blocker remains after safe fallbacks, report its exact evidence to the controller. Never present incomplete work as complete.

Your final response must contain completed actions, verification results, and blockers only.
