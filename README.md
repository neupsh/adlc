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

### 1. Register a runner on your machine

```bash
# Get a runner registration token from:
# https://github.com/<owner>/<repo>/settings/actions/runners/new

git clone https://github.com/neupsh/adlc
cd adlc

# Register + install as a persistent user-level systemd service
./scripts/install.sh \
  --repo your-org/your-repo \
  --label linux \
  --token <RUNNER_REG_TOKEN> \
  --service
```

For IBKR-dependent tests, use `--label ibkr` and run on the machine with IB Gateway.

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

In your repo's Issues, create: `agent-ready`, `agent-coding`, `agent-review`, `agent-failed`

### 5. Authenticate Claude (once per machine)

```bash
claude auth login   # uses your subscription, not API pricing
```

### 6. Trigger an agent run

Label any issue `agent-ready`. The agent fires within seconds.

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

```bash
# Check status
systemctl --user status adlc-runner-your-org-your-repo

# Restart
systemctl --user restart adlc-runner-your-org-your-repo

# Uninstall
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
