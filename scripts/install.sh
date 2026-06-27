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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2";  shift 2 ;;
    --label)   LABEL="$2"; shift 2 ;;
    --token)   TOKEN="$2"; shift 2 ;;
    --service) INSTALL_SERVICE=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO" || -z "$TOKEN" ]]; then
  echo "Usage: $0 --repo <owner/name> --label <label> --token <runner-reg-token> [--service]"
  echo ""
  echo "Get runner token: https://github.com/<owner>/<name>/settings/actions/runners/new"
  exit 1
fi

REPO_URL="https://github.com/$REPO"
RUNNER_DIR="$HOME/actions-runner-${REPO//\//-}"

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

# ── Download GH Actions runner ───────────────────────────────────────────────
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  RUNNER_ARCH="x64" ;;
  aarch64) RUNNER_ARCH="arm64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
if [[ ! -f ".runner" ]]; then
  if [[ ! -f "$TARBALL" ]]; then
    echo "==> Downloading runner v${RUNNER_VERSION}..."
    curl -sSfL \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}" \
      -o "$TARBALL"
    tar xzf "$TARBALL"
  fi

  # Register
  HOSTNAME="$(hostname -s)"
  ./config.sh \
    --url "$REPO_URL" \
    --token "$TOKEN" \
    --name "${HOSTNAME}-${LABEL//,/-}" \
    --labels "self-hosted,linux,${LABEL}" \
    --work "_work" \
    --unattended \
    --replace

  echo "==> Runner registered."
else
  echo "==> Runner already configured (delete $RUNNER_DIR/.runner to re-register)."
fi

# ── Install as user-level systemd service ───────────────────────────────────
if $INSTALL_SERVICE; then
  SERVICE_NAME="agentic-runner-${REPO//\//-}"
  SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
  mkdir -p "$HOME/.config/systemd/user"

  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=GitHub Actions Runner for $REPO ($LABEL)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$RUNNER_DIR
ExecStart=$RUNNER_DIR/run.sh
Restart=always
RestartSec=10
KillMode=process

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME"
  systemctl --user start  "$SERVICE_NAME"

  # Allow service to run after user logout
  loginctl enable-linger "$USER" 2>/dev/null || \
    echo "WARN: loginctl enable-linger failed (may need sudo). Run: sudo loginctl enable-linger $USER"

  echo "==> Service installed: $SERVICE_NAME"
  echo "    Manage with: systemctl --user {status,stop,start,restart} $SERVICE_NAME"
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

# ── Helper: drop dispatcher workflow ────────────────────────────────────────
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

jobs:
  dispatch:
    if: github.event.label.name == 'agent-ready'
    uses: neupsh/adlc/.github/workflows/agent-issue.yml@main
    with:
      issue_number: \${{ github.event.issue.number }}
      issue_title:  \${{ github.event.issue.title }}
      runner_labels: "["self-hosted","linux","${label}"]"
      # build_check_cmd: ""   # override here or use .adlc/conventions.md
      # build_test_cmd:  ""
    secrets:
      GPG_PRIVATE_KEY: \${{ secrets.GPG_PRIVATE_KEY }}
      GPG_KEY_ID:      \${{ secrets.GPG_KEY_ID }}
      GPG_PASSPHRASE:  \${{ secrets.GPG_PASSPHRASE }}
DISPATCH_EOF
  echo "    Created: $out"
}
