#!/usr/bin/env bash
# Appends the bug task section to $PROMPT_FILE.
# Reads env vars: PROMPT_FILE, ISSUE_NUMBER, ISSUE_TITLE, BRANCH, REPO, ISSUE_BODY

set -euo pipefail

OUT="${PROMPT_FILE:-/tmp/agent-prompt.txt}"

cat >> "$OUT" << EOF

## Your task (bug fix)

Issue: #${ISSUE_NUMBER} — ${ISSUE_TITLE}

1. **Diagnose first** — read the relevant code, understand the root cause fully before touching anything
2. Post a comment on the issue explaining the diagnosis: \`gh issue comment ${ISSUE_NUMBER} --body "Diagnosis: ..." --repo ${REPO}\`
3. Implement the **minimal correct fix** — do not refactor beyond what is necessary
4. Add a regression test that would have caught this bug
5. Run build check (0 warnings) then tests
6. Commit: \`git commit -S -m 'fix(<scope>): <description>'\`
7. Push: \`git push --force-with-lease origin ${BRANCH}\` (the branch is yours; a re-run may need to overwrite a prior push)
8. Open PR: \`gh pr create --title 'fix: ...' --body 'Closes #${ISSUE_NUMBER}. Root cause: ...'\`
   (Use 'Closes #${ISSUE_NUMBER}' when this fully fixes the bug — the usual case. If it's
   only a partial step needing more PRs, write 'Part of #${ISSUE_NUMBER}' so the issue stays open.)
9. Label: \`gh issue edit ${ISSUE_NUMBER} --remove-label agent-coding --add-label agent-review --repo ${REPO}\`

## Issue Body

${ISSUE_BODY}
EOF
