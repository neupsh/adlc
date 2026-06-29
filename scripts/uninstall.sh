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

# install.sh registers one or more instances suffixed -1..-N. Discover them all
# by glob (plus any legacy un-suffixed install from older script versions) so we
# never orphan a runner. The numeric-suffix glob avoids matching a sibling repo
# whose name merely starts with this one.
PREFIX_DIR="$HOME/actions-runner-${REPO//\//-}"
PREFIX_SVC="agentic-runner-${REPO//\//-}"
SVC_DIR="$HOME/.config/systemd/user"

shopt -s nullglob

# Match instances of THIS repo only. A bare -[0-9]* glob also matches a sibling
# repo's instances (org/app's glob eats org/app-2's actions-runner-org-app-2-1),
# so keep only hits whose suffix after "<prefix>-" is all digits. Avoids extglob
# so the script also passes `bash -n`.
RUNNER_DIRS=()
for d in "$PREFIX_DIR"-[0-9]*; do
  suffix="${d#"$PREFIX_DIR"-}"
  [[ "$suffix" =~ ^[0-9]+$ ]] && RUNNER_DIRS+=( "$d" )
done
[[ -d "$PREFIX_DIR" ]] && RUNNER_DIRS+=( "$PREFIX_DIR" )          # legacy

SERVICE_FILES=()
for f in "$SVC_DIR/$PREFIX_SVC"-[0-9]*.service; do
  suffix="$(basename "$f" .service)"; suffix="${suffix#"$PREFIX_SVC"-}"
  [[ "$suffix" =~ ^[0-9]+$ ]] && SERVICE_FILES+=( "$f" )
done
[[ -f "$SVC_DIR/$PREFIX_SVC.service" ]] && SERVICE_FILES+=( "$SVC_DIR/$PREFIX_SVC.service" )  # legacy

if [[ ${#RUNNER_DIRS[@]} -eq 0 && ${#SERVICE_FILES[@]} -eq 0 ]]; then
  echo "==> Nothing to remove for $REPO (no runner directories or services found)."
fi

# ── Stop and remove systemd services ─────────────────────────────────────────
for SERVICE_FILE in "${SERVICE_FILES[@]}"; do
  SERVICE_NAME="$(basename "$SERVICE_FILE" .service)"
  if systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
    systemctl --user stop "$SERVICE_NAME"
    echo "==> Stopped $SERVICE_NAME"
  fi
  if systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null; then
    systemctl --user disable "$SERVICE_NAME"
  fi
  rm -f "$SERVICE_FILE"
  echo "==> Removed service file: $SERVICE_NAME"
done
[[ ${#SERVICE_FILES[@]} -gt 0 ]] && systemctl --user daemon-reload

# ── Deregister runners ───────────────────────────────────────────────────────
for RUNNER_DIR in "${RUNNER_DIRS[@]}"; do
  [[ -d "$RUNNER_DIR" ]] || continue
  if [[ -f "$RUNNER_DIR/.runner" ]]; then
    if [[ -n "$TOKEN" ]]; then
      ( cd "$RUNNER_DIR" && ./config.sh remove --token "$TOKEN" --unattended 2>/dev/null || true )
      echo "==> Runner deregistered from GitHub: $(basename "$RUNNER_DIR")"
    else
      echo "WARN: No token provided — $(basename "$RUNNER_DIR") not deregistered from GitHub."
      echo "      Remove it manually at: https://github.com/$REPO/settings/actions/runners"
    fi
  fi
  rm -rf "$RUNNER_DIR"
  echo "==> Removed runner directory: $RUNNER_DIR"
done

echo ""
echo "==> Uninstall complete for $REPO."
echo "    The dispatcher workflow (.github/workflows/agent-dispatch.yml) was NOT"
echo "    removed from the target repo — delete it manually if desired."
