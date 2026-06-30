# adlc

Reusable GitHub Actions workflow for autonomous AI-driven issue resolution.

Label any GitHub issue `agent-ready` → an agent clones the repo in a worktree, reads the issue, writes a fix, passes CI, opens a PR, and labels it `agent-review`. Zero human intervention required.

## How it works

```
Issue labeled "agent-ready"
  → caller repo's agent-dispatch.yml fires
    → calls neupsh/adlc/.github/workflows/agent-issue.yml
      → self-hosted runner picks up the job
        → claude agent works in an isolated worktree
          → commits (GPG-signed), pushes, opens PR
            → issue labeled "agent-review"
```

## Quick start (new project)

**Prerequisites**

- A Linux machine to host the self-hosted runner (kept on; `--service` enables lingering so it survives logout).
- A GitHub repo you can add Actions secrets and a self-hosted runner to.
- A GPG key for signed commits — the agent signs every commit. Create one with `gpg --full-generate-key`; get its ID via `gpg --list-secret-keys --keyid-format=long`.
- A Claude subscription (the agent runs the `claude` CLI, not the metered API).
- `git` and Node.js on the runner box. `install.sh` installs Claude Code, `gh`, and `jq` where it can.

### 1. Register a runner on your machine

```bash
# Get a runner registration token from:
# https://github.com/<owner>/<repo>/settings/actions/runners/new

git clone https://github.com/neupsh/adlc
cd adlc

# Register + install as a persistent user-level systemd service.
# Defaults to 1 runner (one job at a time). Add e.g. --runners 2 to allow more
# concurrency — but each runner is a concurrent agent job, so leave headroom if
# other repos share this machine.
./scripts/install.sh \
  --repo your-org/your-repo \
  --label linux \
  --token <RUNNER_REG_TOKEN> \
  --service
```

For IBKR-dependent tests, use `--label ibkr` and run on the machine with IB Gateway.

### Concurrency & isolation

`--runners N` is the concurrency cap for this repo on the machine: GitHub dispatches
**one job per runner instance** and queues the rest, so no more than `N` agent jobs
ever run at once and **no labeled issue is dropped** — extras wait for a free runner.
It defaults to `1` (one job at a time). Bump it only if the box has spare capacity;
each extra runner is another concurrent agent process competing for CPU/RAM, and if
other repos register their own runners here, total machine load is the sum across all
of them.

Re-running `install.sh` reconciles to the requested count: lowering `--runners` (or
upgrading from an older single-runner install) **disables** the now-stale services so
concurrency never exceeds the cap. Those runners stay registered in GitHub as offline
— run `uninstall.sh --repo … --token <remove-token>` to fully deregister them.

Concurrent jobs never collide on disk — this holds across repos too, since two repos'
runners on one machine can fire jobs at the same time:

- Each runner instance has its own directory and `_work` checkout.
- Each job runs the agent in a **per-issue git worktree** under `RUNNER_TEMP`
  (`agent/issue-<n>` branch), created at job start and removed at the end.
- The generated prompt and run log also live under `RUNNER_TEMP`, which is unique
  per runner and wiped each job — so two jobs on the same box can't clobber them.
- A per-issue `concurrency` group ensures the same issue never runs twice at once.

### 2. Drop the dispatcher workflow into your repo

```bash
./scripts/install-dispatcher.sh \
  --repo-path /path/to/your-repo \
  --label linux    # must match the runner label above
```

Commit and push `.github/workflows/agent-dispatch.yml`.

### 3. Add GitHub secrets to your repo

Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `GPG_PRIVATE_KEY` | `gpg --armor --export-secret-keys <KEY_ID>` |
| `GPG_KEY_ID` | Your signing key ID |
| `GPG_PASSPHRASE` | GPG passphrase |

### 4. Create issue labels

Two groups: **lifecycle** labels (required — the workflow moves issues through them) and
**taxonomy** labels (optional — they pick the prompt and model). Create all of them
(run inside your repo clone, or add `--repo your-org/your-repo` to each):

```bash
gh label create agent-ready     -c 0075ca -d "Ready for agentic pickup"
gh label create agent-coding    -c e4e669 -d "Agent is actively coding"
gh label create agent-review    -c d93f0b -d "Agent PR is in review"
gh label create agent-failed    -c b60205 -d "Agent run failed"
gh label create type:initiative -c 0075ca -d "Decompose into epics (architect, no code)"
gh label create type:epic       -c 7057ff -d "Spec + break into stories (architect, no code)"
gh label create type:story      -c d4c5f9 -d "Implement the change + open a PR (default)"
gh label create type:bug        -c d73a4a -d "Diagnose + minimal fix + regression test"
gh label create model:opus      -c e4e669 -d "Force Opus for this issue"
gh label create model:sonnet    -c cfd3d7 -d "Force Sonnet for this issue"
gh label create auto-merge      -c 0e8a16 -d "Merge the PR automatically once a review approves it"
```

**How the taxonomy routes a run** (resolved at job start from the issue's labels):

| Label | What the agent does | Model |
|-------|---------------------|-------|
| _(no `type:` label)_ → `type:story` | Implement the change, open a PR | `model` input (default `claude-sonnet-4-6`) |
| `type:bug` | Diagnose → minimal fix + regression test → PR | same default |
| `type:epic` | Architect mode: write a spec, open `type:story` issues. No code | `claude-opus-4-8` |
| `type:initiative` | Architect mode: propose an ordered list of epics. No code | `claude-opus-4-8` |
| `model:opus` / `model:sonnet` | (any type) override the model for this issue | per label |

### 5. Authenticate Claude (once per machine)

```bash
claude auth login   # uses your subscription, not API pricing
```

### 6. Trigger an agent run

Label any issue `agent-ready`. The agent fires within seconds. Add a `type:` label
to route it (default is `type:story`); add `model:opus`/`model:sonnet` to override the
model. The issue moves `agent-ready` → `agent-coding` → `agent-review` (PR opened) or
`agent-failed`.

---

## Review loop (you review, the agent fixes)

When you review an agent PR and submit a **"Request changes"** review, the coder agent
picks up **all** your feedback — the review body, inline comments, and PR conversation
comments — and revises the PR **in place** (same branch, no new PR). Then you review
again. Repeat until you **Approve**.

- The trigger is a formal **Request changes** review. A plain PR comment on its own does
  **not** fire a revise — leave your comments, then submit the review as "Request
  changes". (Once submitted, the agent reads the conversation comments too.)
- Each revise round commits (signed) and pushes to the PR branch.
- With the `auto-merge` label, your **Approve** then merges the PR (see below).

---

## Auto-merge (opt-in)

By default every PR stops at `agent-review` and waits for a human — that gate is the
safe default and stays the default. To let a specific PR finish the loop on its own,
opt it in with the **`auto-merge`** label:

- Add `auto-merge` to the **issue** (alongside `agent-ready`) and it's copied onto the
  PR when the agent opens it. To opt in *after* the PR exists, add `auto-merge` directly
  to the **PR**.
- When someone **approves** the PR, it merges automatically (squash, branch deleted).
  Unlabeled PRs are never touched.

The merge runs on a GitHub-hosted runner — no agent or self-hosted runner involved.

> **Note:** the approval must come from a human (or a token that isn't the default
> `GITHUB_TOKEN`). GitHub does not re-trigger workflows for events authored by
> `GITHUB_TOKEN`, so a future reviewer-agent that approves with the built-in token
> won't trip auto-merge — it would need a PAT or GitHub App token.

---

## Project-specific configuration

### Option A — `.adlc/conventions.md`

Create this file in your repo root. The agent reads it automatically:

```markdown
## Build
- `cargo check` must show 0 warnings, 0 errors
- `cargo test -p <affected-crate>` must pass

## Commit scopes
core, api, cli, web, data

## Never touch
.env, secrets/, credentials/
```

### Option B — workflow inputs

Override in your `agent-dispatch.yml`:

```yaml
with:
  build_check_cmd: "npm run lint && npm run build"
  build_test_cmd:  "npm test"
  project_conventions: |
    - TypeScript strict mode, no `any`
    - Run `npm run lint` before committing
```

### Option C — `.adlc/build.sh`

```bash
#!/usr/bin/env bash
# .adlc/build.sh check|test
case "$1" in
  check) cargo check ;;
  test)  cargo test -p affected-crate ;;
esac
```

---

## Runner management

Services are named `agentic-runner-<org>-<repo>-<N>`, one per instance:

```bash
# Check status of all instances for a repo
systemctl --user list-units 'agentic-runner-your-org-your-repo-*'

# Restart instance #2
systemctl --user restart agentic-runner-your-org-your-repo-2

# Uninstall — auto-discovers and removes every instance (and any legacy install)
./scripts/uninstall.sh --repo your-org/your-repo --token <REMOVE_TOKEN>
# Remove token: https://github.com/<owner>/<repo>/settings/actions/runners
```

---

## Runner routing

Use different runner labels to route jobs to the right machine:

| Label | Use case |
|-------|----------|
| `linux` | General coding tasks (default) |
| `ibkr` | Tests that need IB Gateway running locally |
| `prod` | Deploy jobs on the production server |

Register multiple runners on the same machine with different labels:

```bash
./scripts/install.sh --repo your-org/your-repo --label ibkr --token <TOKEN> --service
```

---

## Scaling to multiple projects

Register a runner per repo on the same machine. Each gets its own service:

```bash
./scripts/install.sh --repo your-org/project-a --label linux --token <TOKEN_A> --service
./scripts/install.sh --repo your-org/project-b --label linux --token <TOKEN_B> --service
```

For org-level runners (share one runner across all repos), create a GitHub Organization and register at the org level — the install script's `--repo` can accept `<org>` directly once you have an org runner token.
