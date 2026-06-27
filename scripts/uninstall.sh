#!/usr/bin/env bash
# Uninstall the adlc runner + service for a repo.
#
# Usage: ./scripts/uninstall.sh --repo neupsh/iteratrade --token <RUNNER_REMOVE_TOKEN>

set -euo pipefail

REPO=""
TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="$2";  shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Usage: $0 --repo <owner/name> --token <runner-remove-token>"
  echo ""
  echo "Get remove token: https://github.com/<owner>/<name>/settings/actions/runners"
  exit 1
fi

RUNNER_DIR="$HOME/actions-runner-${REPO//\//-}"
SERVICE_NAME="agentic-runner-${REPO//\//-}"

# ── Stop and remove systemd service ─────────────────────────────────────────
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
if systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
  systemctl --user stop "$SERVICE_NAME"
  echo "==> Stopped $SERVICE_NAME"
fi
if systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null; then
  systemctl --user disable "$SERVICE_NAME"
fi
if [[ -f "$SERVICE_FILE" ]]; then
  rm "$SERVICE_FILE"
  systemctl --user daemon-reload
  echo "==> Removed service file"
fi

# ── Deregister runner ────────────────────────────────────────────────────────
if [[ -d "$RUNNER_DIR" ]]; then
  cd "$RUNNER_DIR"
  if [[ -f ".runner" ]]; then
    if [[ -n "$TOKEN" ]]; then
      ./config.sh remove --token "$TOKEN" --unattended 2>/dev/null || true
      echo "==> Runner deregistered from GitHub"
    else
      echo "WARN: No token provided — runner not deregistered from GitHub."
      echo "      Remove it manually at: https://github.com/$REPO/settings/actions/runners"
    fi
  fi
  cd "$HOME"
  rm -rf "$RUNNER_DIR"
  echo "==> Removed runner directory: $RUNNER_DIR"
fi

echo ""
echo "==> Uninstall complete for $REPO."
echo "    The dispatcher workflow (.github/workflows/agent-dispatch.yml) was NOT"
echo "    removed from the target repo — delete it manually if desired."
