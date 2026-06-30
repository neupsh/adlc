#!/usr/bin/env bash
# Smoke test for the prompt builder.
#
# Regression guard: build-prompt.sh must produce a non-empty prompt and exit 0
# for EVERY issue type, including when the consumer repo has no .agentic/build.sh
# (and no .agentic/ at all). A trailing `[ -f .agentic/build.sh ] && ...` once
# returned exit 1 there, silently failing dispatch for epic/story/initiative
# before any agent ran. This test runs from a CWD without those files so that
# failure mode can never come back unnoticed.
#
# Usage: scripts/test-prompts.sh   (no secrets, no network — safe in CI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_PROMPT="$SCRIPT_DIR/build-prompt.sh"
TYPES=(bug story epic initiative revise)
FAILS=0

# revise.sh reads its feedback from $FEEDBACK_FILE.
FB="$(mktemp)"; printf '### Comment by @reviewer\nUn-scope the .report-meta CSS rule.\n' > "$FB"
trap 'rm -f "$FB"' EXIT

run_case() {
  local desc="$1" cwd="$2" t pf err code
  for t in "${TYPES[@]}"; do
    pf="$(mktemp)"
    err="$(mktemp)"
    code=0
    (
      cd "$cwd"
      PROMPT_FILE="$pf" ISSUE_TYPE="$t" \
      ISSUE_NUMBER=123 ISSUE_TITLE="Test $t issue" BRANCH="agent/issue-123" \
      REPO="acme/widget" ISSUE_BODY="Representative body for a $t." \
      BUILD_CHECK="cargo check" BUILD_TEST="cargo test" CONVENTIONS="" \
      AGENT_EMAIL="agent-coder@agents.bot" \
      PR_NUMBER=83 PR_BRANCH="agent/issue-123" FEEDBACK_FILE="$FB" \
      bash "$BUILD_PROMPT"
    ) >/dev/null 2>"$err" || code=$?

    if [ "$code" -ne 0 ]; then
      echo "FAIL [$desc] type=$t: build-prompt.sh exited $code"
      sed 's/^/      /' "$err"
      FAILS=$((FAILS + 1))
    elif [ ! -s "$pf" ]; then
      echo "FAIL [$desc] type=$t: prompt file is empty"
      FAILS=$((FAILS + 1))
    elif ! grep -q "issue #123" "$pf"; then
      echo "FAIL [$desc] type=$t: prompt missing expected issue marker"
      FAILS=$((FAILS + 1))
    else
      echo "ok   [$desc] type=$t ($(wc -l < "$pf") lines)"
    fi
    rm -f "$pf" "$err"
  done
}

# Case A: bare consumer checkout — no .agentic/ at all (this is the regression).
A="$(mktemp -d)"
run_case "no .agentic" "$A"
rm -rf "$A"

# Case B: conventions present, build.sh absent (the exact failing repo state).
B="$(mktemp -d)"; mkdir -p "$B/.agentic"; printf -- '- house rule\n' > "$B/.agentic/conventions.md"
run_case "conventions, no build.sh" "$B"
rm -rf "$B"

# Case C: full .agentic present (both conventions + build.sh).
C="$(mktemp -d)"; mkdir -p "$C/.agentic"
printf -- '- rule\n' > "$C/.agentic/conventions.md"; printf '#!/bin/sh\n' > "$C/.agentic/build.sh"
run_case "full .agentic" "$C"
rm -rf "$C"

# Unknown type must fail loudly (clear message + non-zero), not silently.
UNK="$(mktemp)"; code=0
PROMPT_FILE="$UNK" ISSUE_TYPE="bogus" ISSUE_NUMBER=1 ISSUE_TITLE=x BRANCH=b \
  REPO=a/b ISSUE_BODY=y AGENT_EMAIL=z bash "$BUILD_PROMPT" >/dev/null 2>&1 || code=$?
if [ "$code" -eq 0 ]; then
  echo "FAIL [unknown type] expected non-zero exit, got 0"
  FAILS=$((FAILS + 1))
else
  echo "ok   [unknown type] rejected (exit $code)"
fi
rm -f "$UNK"

if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "All prompt smoke tests passed."
