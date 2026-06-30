#!/usr/bin/env bash
# Inline AI review loop. Runs in the PR worktree AFTER the coder opened the PR.
# Up to $REVIEW_ROUNDS rounds: an AI reviewer (opus) judges the diff; if it requests
# changes, the coder agent addresses them and pushes; then the reviewer looks again.
# On approval, if the issue carries the auto-merge label, the PR is squash-merged —
# otherwise it's left for a human. If the loop never converges, it stops for a human.
#
# A GITHUB_TOKEN-authored review/push never triggers another workflow, which is why
# this runs inline (one job) instead of as event-chained workflows.
#
# Reads env: REPO, ISSUE_NUMBER, BRANCH (the PR branch), MODEL, REVIEWER_MODEL,
#   REVIEW_ROUNDS, AUTO_MERGE_LABEL, MERGE_METHOD, DEFAULT_BRANCH, AGENT_EMAIL,
#   CONVENTIONS, BUILD_CHECK, BUILD_TEST, RUNNER_TEMP, RUN_LOG, ADLC_DIR, GH_TOKEN

set -Eeuo pipefail

ADLC="${ADLC_DIR:?ADLC_DIR (path to adlc scripts) is required}"
ROUNDS="${REVIEW_ROUNDS:-3}"
REVIEWER_MODEL="${REVIEWER_MODEL:-claude-sonnet-4-6}"
REVIEWER_EFFORT="${REVIEWER_EFFORT:-high}"
EFFORT="${EFFORT:-medium}"
LABEL="${AUTO_MERGE_LABEL:-auto-merge}"
METHOD="${MERGE_METHOD:-squash}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
RUN_LOG="${RUN_LOG:-$RUNNER_TEMP/agent-run.log}"

PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number -q '.[0].number' --repo "$REPO" 2>/dev/null || echo "")
if [ -z "$PR_NUMBER" ]; then
  echo "review-loop: no open PR for $BRANCH — nothing to review."
  exit 0
fi
echo "review-loop: reviewing PR #$PR_NUMBER (issue #$ISSUE_NUMBER), up to $ROUNDS round(s)."

REVIEW_FILE="$RUNNER_TEMP/agent-review.md"
PROMPT_FILE="$RUNNER_TEMP/agent-prompt.txt"
export PROMPT_FILE
approved=false

for r in $(seq 1 "$ROUNDS"); do
  echo "== AI review round $r/$ROUNDS =="
  rm -f "$REVIEW_FILE"

  # 1) Reviewer writes its verdict to $REVIEW_FILE (does not touch code).
  PROMPT_FILE="$PROMPT_FILE" REVIEW_FILE="$REVIEW_FILE" PR_NUMBER="$PR_NUMBER" \
    ISSUE_NUMBER="$ISSUE_NUMBER" DEFAULT_BRANCH="$DEFAULT_BRANCH" REPO="$REPO" \
    CONVENTIONS="${CONVENTIONS:-}" bash "$ADLC/prompts/review.sh"
  claude -p "$(cat "$PROMPT_FILE")" --model "$REVIEWER_MODEL" --effort "$REVIEWER_EFFORT" \
    --dangerously-skip-permissions 2>&1 | tee "$RUN_LOG" || true

  verdict=$(head -n1 "$REVIEW_FILE" 2>/dev/null | tr -d '\r' || true)
  echo "review-loop: verdict = '${verdict:-<none>}'"

  # Surface the reviewer's full findings on the PR (not just the final outcome),
  # so non-blocking nits and rationale are visible without digging in the run log.
  if [ -s "$REVIEW_FILE" ]; then
    CFILE="$RUNNER_TEMP/review-comment.md"
    { printf '🤖 **AI review** — round %s/%s (`%s`)\n\n' "$r" "$ROUNDS" "$REVIEWER_MODEL"
      cat "$REVIEW_FILE"; } > "$CFILE"
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file "$CFILE" || true
  fi

  # Approve only on an explicit APPROVE. Anything else (request changes, or an
  # unparseable/missing verdict) is treated as "needs work" — fail safe.
  if printf '%s' "$verdict" | grep -qiE 'VERDICT:[[:space:]]*APPROVE'; then
    approved=true
    break
  fi
  if [ "$r" -eq "$ROUNDS" ]; then
    break   # don't spend a coder round we won't re-review
  fi

  # 2) Coder addresses the reviewer's feedback (reuses the revise prompt) and pushes.
  PROMPT_FILE="$PROMPT_FILE" ISSUE_TYPE=revise PR_NUMBER="$PR_NUMBER" \
    ISSUE_NUMBER="$ISSUE_NUMBER" PR_BRANCH="$BRANCH" BRANCH="$BRANCH" REPO="$REPO" \
    FEEDBACK_FILE="$REVIEW_FILE" AGENT_EMAIL="${AGENT_EMAIL:-agent-coder@agents.bot}" \
    CONVENTIONS="${CONVENTIONS:-}" BUILD_CHECK="${BUILD_CHECK:-}" BUILD_TEST="${BUILD_TEST:-}" \
    bash "$ADLC/build-prompt.sh"
  claude -p "$(cat "$PROMPT_FILE")" --model "$MODEL" --effort "$EFFORT" \
    --dangerously-skip-permissions 2>&1 | tee "$RUN_LOG" || true
done

# ── Outcome ───────────────────────────────────────────────────────────────────
# The auto-merge label may sit on the PR or the originating issue — check both.
has_label() {
  {
    gh pr view "$PR_NUMBER" --repo "$REPO" --json labels -q '.labels[].name' 2>/dev/null
    [ -n "$ISSUE_NUMBER" ] && gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels -q '.labels[].name' 2>/dev/null
  } | grep -Fqx "$LABEL"
}

if $approved; then
  if has_label; then
    echo "review-loop: AI approved + '$LABEL' label → merging PR #$PR_NUMBER (--$METHOD)."
    if gh pr merge "$PR_NUMBER" --repo "$REPO" --"$METHOD" --delete-branch; then
      gh pr comment "$PR_NUMBER" --repo "$REPO" \
        --body "AI review approved and auto-merged (opt-in label \`$LABEL\`)." || true
    else
      gh pr comment "$PR_NUMBER" --repo "$REPO" \
        --body "AI review approved but the merge failed — needs a human." || true
    fi
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "AI review approved. No \`$LABEL\` label, so leaving this for human approval." || true
  fi
else
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "AI review did not converge after $ROUNDS round(s) — handing off to a human reviewer." || true
fi
