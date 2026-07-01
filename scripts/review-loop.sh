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

# ── Making the review VISIBLE (Reviews tab, merge box, issue) ──────────────────
# The reviewer already writes a branded PR comment (below). On top of that we (a)
# submit a formal PR review so it lands in the Reviews tab + sets reviewDecision,
# (b) post an `adlc/ai-review` commit status for the merge box + Checks tab, and
# (c) move the originating issue to a terminal label with a back-reference. All of
# it is best-effort — a missing token or permission is logged and skipped, never
# fatal (scripts load from adlc @main unpinned and can't be branch-tested).
#
# The formal review is submitted by github-actions[bot] (DEFAULT_TOKEN). GitHub
# forbids approving your OWN PR, so a real APPROVE/REQUEST_CHANGES is only possible
# when github-actions is NOT the PR author. We decide that WITHOUT hard-coding
# github-actions' login string (gh reports bot authors as `app/<slug>`, not
# `<slug>[bot]`, so string-matching is fragile), using two reliable signals:
#   • GH_TOKEN != DEFAULT_TOKEN  → a GitHub App minted GH_TOKEN, so the PR was authored
#     by the app[bot] (or a human) — github-actions is always a distinct identity → OK.
#   • else (no App: GH_TOKEN == DEFAULT_TOKEN == github-actions) → only safe if the PR
#     is human-authored (a /review on someone's PR); a bot-authored PR here is our own
#     github-actions PR → self-review → downgrade to a COMMENT (still shows in Reviews).
DEFAULT_TOKEN="${DEFAULT_TOKEN:-}"
pr_author_is_bot=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json author -q .author.is_bot 2>/dev/null || echo "")
can_approve=false
if [ -n "$DEFAULT_TOKEN" ]; then
  if [ "$GH_TOKEN" != "$DEFAULT_TOKEN" ]; then
    can_approve=true
  elif [ "$pr_author_is_bot" = "false" ]; then
    can_approve=true
  fi
fi
if $can_approve; then
  REVIEW_TOKEN="$DEFAULT_TOKEN"; APPROVE_EVENT="APPROVE"; CHANGES_EVENT="REQUEST_CHANGES"
else
  REVIEW_TOKEN="$GH_TOKEN"; APPROVE_EVENT="COMMENT"; CHANGES_EVENT="COMMENT"
fi
# Commit statuses go through github-actions[bot] (governed by the caller's
# statuses:write grant) when available, else GH_TOKEN. A 403 (grant absent) is
# swallowed, so repos that haven't added statuses:write simply don't get the check.
STATUS_TOKEN="${DEFAULT_TOKEN:-$GH_TOKEN}"

# Create a label if missing (idempotent) so --add-label can't fail on a fresh repo.
ensure_label() { gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force >/dev/null 2>&1 || true; }

# Formal PR review → Reviews tab + reviewDecision. $1=event $2=body-file.
# raw-field (not -F) so the body is always a string, never type-coerced.
submit_review() {
  GH_TOKEN="$REVIEW_TOKEN" gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" \
    -f event="$1" -f body="$(cat "$2")" >/dev/null 2>&1 \
    || echo "review-loop: formal review ($1) not submitted (self-review or perms) — branded comment still posted."
}

# adlc/ai-review commit status on the PR head → merge box + Checks tab.
# $1=state(success|failure) $2=description $3=target_url(may be empty).
set_status() {
  local sha
  sha=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo "")
  [ -z "$sha" ] && return 0
  GH_TOKEN="$STATUS_TOKEN" gh api "repos/$REPO/statuses/$sha" \
    -f state="$1" -f context="adlc/ai-review" -f description="$2" \
    ${3:+-f target_url="$3"} >/dev/null 2>&1 \
    || echo "review-loop: commit status not set (needs statuses:write on the caller) — skipping."
}

# Move the originating ISSUE to a terminal review state + leave a back-reference,
# so someone viewing the issue (not just the PR) sees the review happened.
# $1=new-label $2=comment-body.
reflect_on_issue() {
  [ -z "${ISSUE_NUMBER:-}" ] && return 0
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$1" >/dev/null 2>&1 || true
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "agent-review" >/dev/null 2>&1 || true
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "agent-coding" >/dev/null 2>&1 || true
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$2" >/dev/null 2>&1 || true
}

ensure_label "agent-approved" "0e8a16" "AI reviewer approved — awaiting human/auto merge"
ensure_label "agent-changes-requested" "d93f0b" "AI reviewer requested changes — needs a human"

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
  # Then mirror the verdict as a FORMAL review so it also lands in the Reviews tab.
  review_comment_url=""
  if [ -s "$REVIEW_FILE" ]; then
    CFILE="$RUNNER_TEMP/review-comment.md"
    { printf '**🔍 Reviewer** — round %s/%s (model `%s` · effort `%s`)\n\n' \
        "$r" "$ROUNDS" "$REVIEWER_MODEL" "$REVIEWER_EFFORT"
      cat "$REVIEW_FILE"
      printf '\n<sub>— adlc</sub>\n'; } > "$CFILE"
    review_comment_url=$(gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file "$CFILE" 2>/dev/null || echo "")

    if printf '%s' "$verdict" | grep -qiE 'VERDICT:[[:space:]]*APPROVE'; then
      rev_event="$APPROVE_EVENT"; rev_word="approved"
    else
      rev_event="$CHANGES_EVENT"; rev_word="requested changes"
    fi
    RFILE="$RUNNER_TEMP/review-body.md"
    { printf 'AI reviewer %s this PR (round %s/%s · model `%s` · effort `%s`).' \
        "$rev_word" "$r" "$ROUNDS" "$REVIEWER_MODEL" "$REVIEWER_EFFORT"
      [ -n "$review_comment_url" ] && printf '\n\nFull findings: %s' "$review_comment_url"
      printf '\n\n— adlc\n'; } > "$RFILE"
    submit_review "$rev_event" "$RFILE"
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

# Record the verdict as a commit status (merge box + Checks tab) while the PR head
# still exists — before any merge below deletes the branch.
if $approved; then
  set_status "success" "Approved by AI reviewer (up to $ROUNDS round(s))" ""
else
  set_status "failure" "AI reviewer did not converge after $ROUNDS round(s)" ""
fi

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
    reflect_on_issue "agent-approved" \
      "**🔍 Reviewer** approved PR #$PR_NUMBER — awaiting human merge (no \`$LABEL\` label). <sub>— adlc</sub>"
  fi
else
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "**🔍 Reviewer** did not converge after $ROUNDS round(s) — handing off to a human reviewer. <sub>— adlc</sub>" || true
  reflect_on_issue "agent-changes-requested" \
    "**🔍 Reviewer** could not converge on PR #$PR_NUMBER after $ROUNDS round(s) — needs a human. <sub>— adlc</sub>"
fi
