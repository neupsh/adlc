#!/usr/bin/env bash
# Appends the "address review feedback" task section to $PROMPT_FILE.
# Reads env vars: PROMPT_FILE, PR_NUMBER, ISSUE_NUMBER, PR_BRANCH, REPO, FEEDBACK_FILE
# Selected by build-prompt.sh when ISSUE_TYPE=revise (combined with _common.sh).

set -euo pipefail

OUT="${PROMPT_FILE:-/tmp/agent-prompt.txt}"

cat >> "$OUT" << EOF

## Your task (address review feedback)

You previously opened PR #${PR_NUMBER} (branch \`${PR_BRANCH}\`) for issue #${ISSUE_NUMBER}.
This worktree is that branch, already checked out with your earlier work. A human
reviewer left the feedback below — address ALL of it.

1. Read each point of feedback and the relevant code before changing anything
2. Make the minimal correct changes it asks for — no unrelated refactoring
3. Run the build check (0 warnings) then the tests
4. Commit (signed): \`git commit -S -m '<type>(<scope>): address review feedback'\`
5. Push to the SAME branch — this updates the existing PR, do NOT open a new one:
   \`git push origin ${PR_BRANCH}\`
6. Comment on the PR summarizing what you changed:
   \`gh pr comment ${PR_NUMBER} --body "..." --repo ${REPO}\`

If a point is unclear or you disagree, say so in the PR comment instead of guessing.
If a point was already handled in your earlier work, note that rather than redoing it.

## Reviewer feedback

EOF

# Append the gathered feedback verbatim (kept in a file to avoid env-var quoting
# issues with arbitrary review text).
cat "${FEEDBACK_FILE:-/dev/null}" >> "$OUT"
