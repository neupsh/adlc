#!/usr/bin/env bash
# Install the adlc runner + dispatcher in a target project.
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/neupsh/adlc/main/scripts/install.sh | bash -s -- \
#     --repo neupsh/iteratrade \
#     --label ibkr \
#     --token <RUNNER_REG_TOKEN>
#
#   Or clone adlc and run locally:
#     ./scripts/install.sh --repo neupsh/iteratrade --label ibkr --token <TOKEN>

set -euo pipefail

RUNNER_VERSION="2.323.0"
ADLC_REPO="neupsh/adlc"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Arg parsing ──────────────────────────────────────────────────────────────
REPO=""
LABEL="linux"
TOKEN=""
INSTALL_SERVICE=false
RUNNERS=1   # max agent jobs this repo runs concurrently on the machine; keep it
            # low to leave headroom for other repos' runners on the same box

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2";    shift 2 ;;
    --label)   LABEL="$2";   shift 2 ;;
    --token)   TOKEN="$2";   shift 2 ;;
    --runners) RUNNERS="$2"; shift 2 ;;
    --service) INSTALL_SERVICE=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO" || -z "$TOKEN" ]]; then
  echo "Usage: $0 --repo <owner/name> --label <label> --token <runner-reg-token> [--runners N] [--service]"
  echo ""
  echo "  --runners N   Number of self-hosted runner instances to register on this"
  echo "                machine (default 1 — one job at a time). This is the"
  echo "                concurrency cap: GitHub runs one job per runner, so at most N"
  echo "                agent jobs run at once and extras queue until a runner frees."
  echo "                Keep it low to leave machine resources for other repos."
  echo ""
  echo "Get runner token: https://github.com/<owner>/<name>/settings/actions/runners/new"
  exit 1
fi

if ! [[ "$RUNNERS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --runners must be a positive integer (got: $RUNNERS)"
  exit 1
fi

REPO_URL="https://github.com/$REPO"

# ── Helper: drop dispatcher workflow (defined before first use) ───────────────
install_dispatcher() {
  local repo_path="$1"
  local label="$2"
  local wf_dir="$repo_path/.github/workflows"
  mkdir -p "$wf_dir"
  local out="$wf_dir/agent-dispatch.yml"
  if [[ -f "$out" ]]; then
    echo "    $out already exists — skipping (delete to regenerate)."
    return
  fi
  cat > "$out" << DISPATCH_EOF
name: Agentic Issue Dispatch

on:
  issues:
    types: [labeled]
  pull_request_review:
    types: [submitted]

jobs:
  dispatch:
    if: github.event_name == 'issues' && github.event.label.name == 'agent-ready'
    permissions:
      contents: write
      issues: write
      pull-requests: write
    uses: neupsh/adlc/.github/workflows/agent-issue.yml@main
    with:
      issue_number: \${{ github.event.issue.number }}
      issue_title:  \${{ github.event.issue.title }}
      runner_labels: '["self-hosted","linux","${label}"]'
      # build_check_cmd: ""   # override here or use .adlc/conventions.md
      # build_test_cmd:  ""
    secrets: inherit

  # A "Request changes" review sends the PR back to the agent to fix, in place.
  revise:
    if: github.event_name == 'pull_request_review' && github.event.review.state == 'changes_requested'
    permissions:
      contents: write
      issues: write
      pull-requests: write
    uses: neupsh/adlc/.github/workflows/agent-revise.yml@main
    with:
      pr_number: \${{ github.event.pull_request.number }}
      runner_labels: '["self-hosted","linux","${label}"]'
      # build_check_cmd / build_test_cmd: keep in sync with the dispatch job above
    secrets: inherit

  # Opt-in: merges an approved PR only if it carries the 'auto-merge' label.
  auto-merge:
    if: github.event_name == 'pull_request_review' && github.event.review.state == 'approved'
    permissions:
      contents: write
      pull-requests: write
    uses: neupsh/adlc/.github/workflows/agent-automerge.yml@main
    with:
      pr_number: \${{ github.event.pull_request.number }}
DISPATCH_EOF
  echo "    Created: $out"
}

echo "==> Setting up adlc runner for $REPO (label: $LABEL)"

# ── Install prerequisites ────────────────────────────────────────────────────
if command -v apt-get &>/dev/null; then
  sudo apt-get install -y --no-install-recommends \
    libicu-dev libssl-dev git curl gnupg2 gh jq 2>/dev/null || true
fi

# ── Install Claude Code ──────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo "==> Installing Claude Code..."
  npm install -g @anthropic-ai/claude-code || {
    echo "ERROR: Could not install Claude Code. Run manually: npm install -g @anthropic-ai/claude-code"
    exit 1
  }
fi

# ── Download GH Actions runner (cached once, extracted per instance) ──────────
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  RUNNER_ARCH="x64" ;;
  aarch64) RUNNER_ARCH="arm64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
CACHE_DIR="$HOME/.cache/adlc-runner"
mkdir -p "$CACHE_DIR"
if [[ ! -f "$CACHE_DIR/$TARBALL" ]]; then
  echo "==> Downloading runner v${RUNNER_VERSION}..."
  curl -sSfL \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}" \
    -o "$CACHE_DIR/$TARBALL"
fi

HOSTNAME="$(hostname -s)"

# ── Register N runner instances ──────────────────────────────────────────────
# Instance count == machine concurrency cap. GitHub dispatches one job per
# runner and holds the rest in its job queue, so no more than $RUNNERS agent
# jobs ever run at once and no labeled issue is dropped. Each instance gets its
# own directory + _work checkout, so concurrent jobs never share git state.
echo "==> Registering $RUNNERS runner instance(s) (max $RUNNERS concurrent agent jobs)"
for i in $(seq 1 "$RUNNERS"); do
  INSTANCE_DIR="$HOME/actions-runner-${REPO//\//-}-${i}"
  INSTANCE_NAME="${HOSTNAME}-${LABEL//,/-}-${i}"
  mkdir -p "$INSTANCE_DIR"

  if [[ -f "$INSTANCE_DIR/.runner" ]]; then
    echo "==> Runner #$i already configured ($INSTANCE_DIR) — skipping (delete .runner to re-register)."
  else
    tar xzf "$CACHE_DIR/$TARBALL" -C "$INSTANCE_DIR"
    ( cd "$INSTANCE_DIR" && ./config.sh \
        --url "$REPO_URL" \
        --token "$TOKEN" \
        --name "$INSTANCE_NAME" \
        --labels "self-hosted,linux,${LABEL}" \
        --work "_work" \
        --unattended \
        --replace )
    echo "==> Runner #$i registered as $INSTANCE_NAME."
  fi

  # ── Install as user-level systemd service ─────────────────────────────────
  if $INSTALL_SERVICE; then
    SERVICE_NAME="agentic-runner-${REPO//\//-}-${i}"
    SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
    mkdir -p "$HOME/.config/systemd/user"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=GitHub Actions Runner for $REPO ($LABEL) #$i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTANCE_DIR
ExecStart=$INSTANCE_DIR/run.sh
Restart=always
RestartSec=10
KillMode=process

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME"
    systemctl --user start  "$SERVICE_NAME"
    echo "==> Service installed: $SERVICE_NAME"
  fi
done

if $INSTALL_SERVICE; then
  # Allow services to keep running after the user logs out
  loginctl enable-linger "$USER" 2>/dev/null || \
    echo "WARN: loginctl enable-linger failed (may need sudo). Run: sudo loginctl enable-linger $USER"
  echo "    Manage with: systemctl --user {status,stop,start,restart} agentic-runner-${REPO//\//-}-<1..$RUNNERS>"
fi

# ── Reconcile stale instances so concurrency never exceeds the cap ────────────
# Older versions registered a single un-suffixed runner, and lowering --runners
# (e.g. 3→1) leaves higher-numbered instances behind. Either keeps extra runners
# alive past $RUNNERS, defeating the cap, so stop+disable any service for this
# repo outside 1..$RUNNERS. The numeric-suffix glob is anchored (-+([0-9]), never
# -2-1) so a sibling repo's services are untouched. We can't deregister from
# GitHub without a remove token — those runners just go offline; run uninstall.sh
# with a remove token (or delete them in repo settings) to fully clean up.
SLUG="${REPO//\//-}"
SVC_DIR="$HOME/.config/systemd/user"
shopt -s nullglob
STALE_SVCS=()
[[ -f "$SVC_DIR/agentic-runner-${SLUG}.service" ]] && STALE_SVCS+=( "agentic-runner-${SLUG}" )  # legacy
for f in "$SVC_DIR/agentic-runner-${SLUG}"-[0-9]*.service; do
  name="$(basename "$f" .service)"
  idx="${name#agentic-runner-${SLUG}-}"
  [[ "$idx" =~ ^[0-9]+$ ]] || continue   # skip a sibling repo's services (e.g. -2-1)
  (( idx > RUNNERS )) && STALE_SVCS+=( "$name" )
done
if (( ${#STALE_SVCS[@]} > 0 )); then
  echo "==> Disabling ${#STALE_SVCS[@]} stale runner service(s) above the cap of $RUNNERS:"
  for name in "${STALE_SVCS[@]}"; do
    systemctl --user disable --now "$name" 2>/dev/null || true
    rm -f "$SVC_DIR/${name}.service"
    echo "    disabled $name (its runner stays registered in GitHub as offline)"
  done
  systemctl --user daemon-reload 2>/dev/null || true
  echo "    To fully deregister: ./scripts/uninstall.sh --repo $REPO --token <remove-token>"
  echo "    or remove offline runners at https://github.com/$REPO/settings/actions/runners"
fi

# ── Drop dispatcher workflow into caller repo ─────────────────────────────────
if [[ -d "$HOME/Projects" || -d "$(pwd)" ]]; then
  # Try to find the caller repo local path
  REPO_NAME="${REPO##*/}"
  SEARCH_PATHS=("$HOME/Projects" "$HOME/Projects/ai" "$HOME/code" "$HOME/dev" "$(pwd)")
  LOCAL_REPO=""
  for p in "${SEARCH_PATHS[@]}"; do
    if [[ -d "$p/$REPO_NAME/.git" ]]; then
      LOCAL_REPO="$p/$REPO_NAME"
      break
    fi
  done

  if [[ -n "$LOCAL_REPO" ]]; then
    echo "==> Found local repo at $LOCAL_REPO — installing dispatcher workflow..."
    install_dispatcher "$LOCAL_REPO" "$LABEL"
  else
    echo "==> Could not find local repo for $REPO. Run install-dispatcher.sh manually:"
    echo "    $SCRIPT_DIR/install-dispatcher.sh --repo-path /path/to/$REPO_NAME --label $LABEL"
  fi
fi

echo ""
echo "==> Required GitHub secrets (Settings → Secrets → Actions in $REPO):"
echo "    GPG_PRIVATE_KEY  — gpg --armor --export-secret-keys <KEY_ID>"
echo "    GPG_KEY_ID       — your signing key ID"
echo "    GPG_PASSPHRASE   — GPG key passphrase"
echo ""
echo "==> Required GitHub labels (create in $REPO Issues):"
echo "    agent-ready, agent-coding, agent-review, agent-failed"
echo ""
echo "==> Claude auth (subscription, not API key — run once):"
echo "    claude auth login"
