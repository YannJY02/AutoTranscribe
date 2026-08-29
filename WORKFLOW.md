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
  root: ~/Developer/Workspaces/AutoTranscribe
hooks:
  timeout_ms: 300000
  after_create: |
    repo_source="${SYMPHONY_REPO_SOURCE:-https://github.com/YannJY02/AutoTranscribe.git}"
    git clone --depth 1 --no-local "$repo_source" .
    git remote set-url origin https://github.com/YannJY02/AutoTranscribe.git
    if [ -n "${SYMPHONY_BOOTSTRAP_REF:-}" ]; then
      git fetch --depth 1 origin "$SYMPHONY_BOOTSTRAP_REF"
      git checkout --detach FETCH_HEAD
    fi
    ./scripts/agent_bootstrap.sh
agent:
  # ponytail: two isolated workspaces; exclusive native commands still serialize through the resource lock.
  max_concurrent_agents: 2
  max_turns: 30
codex:
  # The tracker token stays in Symphony; Codex receives only its native core environment.
  command: env -u SYMPHONY_AGENT_GITHUB_TOKEN -u SYMPHONY_GITHUB_TOKEN -u GITHUB_TOKEN -u GH_TOKEN -u OPENAI_API_KEY codex --config shell_environment_policy.inherit=core app-server
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

1. Run `python3.11 scripts/agent_harness.py issue-preflight --json --issue "{{ issue.identifier }}"{% if attempt %} --resume{% endif %}` and retain its `linear_issue` value. Stop without writes if preflight fails, including when the verified Linear linkback is absent.
2. Read `AGENTS.md`, `docs/agents/harness.md`, `docs/agents/tool-boundaries.md`, `CONTEXT-MAP.md`, relevant context docs and ADRs, repository skills that match the task, and every issue comment. The synchronized GitHub projection is the unattended execution contract; do not assume access to Linear-only project, priority, or detailed-status fields.
3. Claim the issue by assigning it to yourself. Reconfirm it is open and still labelled `ready-for-agent` immediately before the first code or GitHub write.
4. Inspect existing branches and pull requests for the issue. Continue valid work; otherwise create `codex/<lowercase-linear_issue>` from the current default branch.
5. Reproduce the problem or establish the requested baseline. For visible macOS bugs, use the `native-app-proof` skill and preserve before evidence before editing. Implement the smallest root-cause change and the smallest regression test first for non-trivial behavior.
6. Run `python3.11 scripts/agent_harness.py verify --issue "{{ issue.identifier }}" --mode full`. Run issue-specific acceptance checks too. For `exclusive-macos`, wrap installed-app, GUI, capture, or performance commands with `agent_harness.py lock --resource installed-app -- ...`; visible behavior requires after evidence and `proof.json`.
7. Review the diff for correctness, secrets, unrelated changes, architecture conflicts, and missing evidence. If code changed, request one independent agent review and resolve every blocking finding.
8. If changes are needed and `.git` is writable, commit only this issue's files, push, and create or update a PR against `main`, prefixing its title with `linear_issue` so Linear attaches it. If the workspace sandbox keeps `.git` read-only, do not create temporary Git metadata or GitHub commit objects. Stop with a controller handoff containing the exact changed files, verification commands and results, Harness manifest, and independent-review result; the controller will create the branch, commit, PR, and CI handoff from that verified tree. Include the synchronized GitHub issue and any human-only acceptance step.
9. If the issue is an investigation or canary and no repository change is needed, do not manufacture a commit or PR; comment with the exact evidence instead.
10. On success, post one concise issue comment with the PR or no-change result and verification evidence, remove `ready-for-agent`, and add `ready-for-human`. Detailed Linear status remains owned by Linear; use configured native PR automation or update it during human handoff. Do not claim a detailed Linear status change unless it is verified on Linear. Never merge the PR or close the issue.
11. If a true external blocker remains after safe fallbacks, comment with evidence, remove `ready-for-agent`, and add `needs-info`. Never present incomplete work as complete.

Your final response must contain completed actions, verification results, and blockers only.
