#!/usr/bin/env bash
# Appends the story task section to $PROMPT_FILE.
# Reads env vars: PROMPT_FILE, ISSUE_NUMBER, BRANCH, ISSUE_BODY

set -euo pipefail

OUT="${PROMPT_FILE:-/tmp/agent-prompt.txt}"

cat >> "$OUT" << EOF

## Your task
1. Read the issue body below and understand the problem fully before touching any file
2. Make the minimal correct fix -- no refactoring beyond what the issue requires
3. Run the build check command (0 warnings) then the test command
4. Commit: git commit -S -m '<type>(<scope>): <description>'
5. Push: git push --force-with-lease origin ${BRANCH}  (the branch is yours; a re-run may need to overwrite a prior push)
6. Open PR against main with: gh pr create --title '...' --body 'Fixes #${ISSUE_NUMBER}. ...'
7. Update issue label: gh issue edit ${ISSUE_NUMBER} --remove-label agent-coding --add-label agent-review

If you hit an ambiguity that blocks you, post a comment on the issue explaining what is unclear, then stop.

## Issue Body

${ISSUE_BODY}
EOF
