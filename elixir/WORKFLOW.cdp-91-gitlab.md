---
tracker:
  kind: jira
  env_file: ~/.codex/jira-mcp.env
  board_id: "8551"
  project_key: CDP
  assignee: me
  active_states:
    - To Do
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Cancelled
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-gitlab-workspaces
vcs:
  provider: gitlab
  repo: customer-data-tech/monorepos/typescript-monorepo
hooks:
  after_create: |
    set -e
    git clone /Users/feng/Documents/ts-mono .
    git remote set-url origin git@gitlab.corp.paymaya.com:customer-data-tech/monorepos/typescript-monorepo.git
    mkdir -p .codex
    rm -rf .codex/skills
    cp -R /Users/feng/Documents/symphony/.codex/skills .codex/skills
    printf '%s\n' '.codex/skills/' >> .git/info/exclude
    git config rerere.enabled true
    git config rerere.autoupdate true
    if [ -d /Users/feng/Documents/ts-mono/node_modules ] && [ ! -e node_modules ]; then
      ln -s /Users/feng/Documents/ts-mono/node_modules node_modules
    elif command -v pnpm >/dev/null 2>&1 && [ -f package.json ]; then
      pnpm install --frozen-lockfile --offline
    fi
  before_run: |
    set -e
    command -v glab >/dev/null 2>&1
    glab auth status --hostname gitlab.corp.paymaya.com
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" git ls-remote --heads origin main >/dev/null
  before_remove: |
    set -e
    branch="$(git branch --show-current)"
    cd /Users/feng/Documents/symphony/elixir
    mix workspace.before_remove --provider gitlab --repo customer-data-tech/monorepos/typescript-monorepo --branch "$branch"
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on Jira ticket `{{ issue.identifier }}` in the GitLab repository `customer-data-tech/monorepos/typescript-monorepo`.

Use GitLab, not GitHub, for repository handoff:

- Use `glab` for merge requests and GitLab review/check operations.
- Use `.codex/skills/push/SKILL.md` when publishing branch changes; it is provider-aware and must create or update a GitLab MR for this workflow.
- Use `.codex/skills/land/SKILL.md` only if the Jira ticket reaches `Merging`; it is provider-aware and must merge through `glab`.
- Do not run `gh` commands for this ticket.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Required workflow:

1. Work only inside the provided workspace.
2. If the ticket is in `To Do`, transition it to `In Progress` before implementation.
3. Keep exactly one Jira `## Codex Workpad` comment updated with plan, acceptance criteria, validation, and final MR link.
4. Create a branch named for the ticket, for example `codex/cdp-91-gitlab`.
5. Implement the ticket in `ts-mono`, validate the relevant package/app, commit, push, and create a GitLab MR.
6. Attach or comment the GitLab MR URL back to CDP-91.
7. Move CDP-91 to `Human Review` only after the MR exists and validation evidence is recorded.
