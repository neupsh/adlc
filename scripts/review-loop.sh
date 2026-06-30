#!/usr/bin/env bash
# Inline AI review loop. Runs in the PR worktree AFTER the coder opened the PR.
# Up to $REVIEW_ROUNDS rounds: an AI reviewer (opus) judges the diff; if it requests
# changes, the coder agent addresses them and pushes; then the reviewer looks again.
# On approval, if the issue carries the auto-merge label, the PR is squash-merged —
# otherwise it's left for a human. If the loop never converges, it stops for a human.
# If a human merges/closes the PR mid-review, the loop stops without posting an
# approval/merge/no-converge verdict (the verdict would be misleading — see #97).
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

# A human can merge or close the PR while this loop runs — the reviewer call alone
# takes minutes (iteratrade #97: merged during round 1, verdict posted ~3 min later).
# Posting any verdict — worst of all "leaving this for human approval" — on a PR
# that's already settled is misleading. Re-check at each step and bail the moment
# it's confirmed MERGED/CLOSED. Fail OPEN: a transient gh error (empty/unknown
# state) is NOT treated as settled, so a network blip never skips a real review.
exit_if_pr_settled() {
  local state
  state=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
  case "$state" in
    MERGED|CLOSED)
      echo "review-loop: PR #$PR_NUMBER is now $state (settled by a human mid-review) — stopping without a verdict."
      exit 0 ;;
  esac
}

for r in $(seq 1 "$ROUNDS"); do
  echo "== AI review round $r/$ROUNDS =="
  exit_if_pr_settled   # a merge/close during the previous round ends the loop before we spend another reviewer call
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
    { printf '**🔍 Reviewer** — round %s/%s (model `%s` · effort `%s`)\n\n' \
        "$r" "$ROUNDS" "$REVIEWER_MODEL" "$REVIEWER_EFFORT"
      cat "$REVIEW_FILE"
      printf '\n<sub>— adlc</sub>\n'; } > "$CFILE"
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file "$CFILE" || true
  fi

  # If the human merged during the reviewer call, the findings above are preserved
  # as a record, but skip the coder round and the outcome verdict below.
  exit_if_pr_settled

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

# A human may have merged during the final round's reviewer pass or a coder push.
# This is the load-bearing guard: it kills the misleading "leaving this for human
# approval" / "did not converge" comment on a PR that's already settled (#97).
exit_if_pr_settled

# ── Outcome ───────────────────────────────────────────────────────────────────
# The auto-merge label may sit on the PR or the originating issue — check both.
# Fetch via the REST API (reliable under GITHUB_TOKEN), capture, then match in-shell
# — and log what we actually found so a "no label" outcome is self-diagnosing.
has_label() {
  local labels
  labels=$( { gh api "repos/$REPO/issues/$PR_NUMBER/labels" --jq '.[].name' 2>/dev/null
              [ -n "$ISSUE_NUMBER" ] && gh api "repos/$REPO/issues/$ISSUE_NUMBER/labels" --jq '.[].name' 2>/dev/null
            } || true )
  echo "review-loop: looking for '$LABEL' among labels: [$(printf '%s' "$labels" | tr '\n' ' ')]" >&2
  case $'\n'"$labels"$'\n' in
    *$'\n'"$LABEL"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

if $approved; then
  if has_label; then
    echo "review-loop: AI approved + '$LABEL' label → merging PR #$PR_NUMBER (--$METHOD)."
    # Issues this PR is set to close (from Closes/Fixes/Resolves keywords). A
    # 'Part of #N' reference is deliberately NOT here, so multi-PR issues stay open.
    CLOSES=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json closingIssuesReferences --jq '.closingIssuesReferences[].number' 2>/dev/null || true)
    if gh pr merge "$PR_NUMBER" --repo "$REPO" --"$METHOD" --delete-branch; then
      gh pr comment "$PR_NUMBER" --repo "$REPO" \
        --body "**🔍 Reviewer** approved and auto-merged (opt-in label \`$LABEL\`). <sub>— adlc</sub>" || true
      # GITHUB_TOKEN merges don't trigger GitHub's native auto-close, so close them
      # ourselves — but only if still OPEN, so we never double-comment when an
      # App-token merge already triggered the native close.
      for iss in $CLOSES; do
        ISTATE=$(gh issue view "$iss" --repo "$REPO" --json state -q .state 2>/dev/null || echo "")
        if [ "$ISTATE" = "OPEN" ]; then
          echo "review-loop: closing issue #$iss (resolved by PR #$PR_NUMBER)"
          gh issue close "$iss" --repo "$REPO" --reason completed \
            --comment "**✅ Resolved** by merged PR #$PR_NUMBER. <sub>— adlc</sub>" || true
        else
          echo "review-loop: issue #$iss already ${ISTATE:-unknown} — skipping close."
        fi
      done
    else
      gh pr comment "$PR_NUMBER" --repo "$REPO" \
        --body "**🔍 Reviewer** approved, but the merge failed — needs a human. <sub>— adlc</sub>" || true
    fi
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "**🔍 Reviewer** approved. No \`$LABEL\` label, so leaving this for human approval. <sub>— adlc</sub>" || true
  fi
else
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "**🔍 Reviewer** did not converge after $ROUNDS round(s) — handing off to a human reviewer. <sub>— adlc</sub>" || true
fi
