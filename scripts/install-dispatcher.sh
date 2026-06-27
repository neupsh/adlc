#!/usr/bin/env bash
# Drop the agent-dispatch.yml caller workflow into an existing repo.
# Run from anywhere; does not require the runner to be set up.
#
# Usage:
#   ./scripts/install-dispatcher.sh --repo-path /path/to/myproject --label ibkr

set -euo pipefail

REPO_PATH=""
LABEL="linux"
SDLC_REF="main"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-path) REPO_PATH="$2"; shift 2 ;;
    --label)     LABEL="$2";     shift 2 ;;
    --ref)       SDLC_REF="$2";  shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO_PATH" ]]; then
  echo "Usage: $0 --repo-path <path> [--label <label>] [--ref <branch/tag>]"
  exit 1
fi

if [[ ! -d "$REPO_PATH/.git" ]]; then
  echo "ERROR: $REPO_PATH is not a git repository."
  exit 1
fi

WF_DIR="$REPO_PATH/.github/workflows"
mkdir -p "$WF_DIR"
OUT="$WF_DIR/agent-dispatch.yml"

if [[ -f "$OUT" ]]; then
  echo "WARN: $OUT already exists. Delete it first to regenerate."
  exit 0
fi

cat > "$OUT" << EOF
name: Agentic Issue Dispatch

on:
  issues:
    types: [labeled]

jobs:
  dispatch:
    if: github.event.label.name == 'agent-ready'
    permissions:
      contents: write
      issues: write
      pull-requests: write
    uses: neupsh/agentic-sdlc/.github/workflows/agent-issue.yml@${SDLC_REF}
    with:
      issue_number: "\${{ github.event.issue.number }}"
      issue_title:  \${{ github.event.issue.title }}
      runner_labels: '["self-hosted","linux","${LABEL}"]'
      # Uncomment and set project-specific build commands:
      # build_check_cmd: "cargo check"
      # build_test_cmd:  "cargo test"
    secrets: inherit
EOF

echo "Created: $OUT"
echo ""
echo "Next steps:"
echo "  1. Commit and push $OUT to your repo"
echo "  2. Ensure these GitHub secrets exist in your repo:"
echo "       GPG_PRIVATE_KEY, GPG_KEY_ID, GPG_PASSPHRASE"
echo "  3. Ensure these labels exist in your repo's Issues:"
echo "       agent-ready, agent-coding, agent-review, agent-failed"
echo "  4. (Optional) Add .agentic/conventions.md for project-specific rules"
echo "  5. (Optional) Add .agentic/build.sh for project-specific build steps"
echo "  6. Label any issue 'agent-ready' to trigger the agent"
