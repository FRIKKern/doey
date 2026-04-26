#!/usr/bin/env bash
# test-doey-send-sandbox.sh — Regression test for task 634.
#
# Verifies that pipe-based prompt/activity detection in doey-send.sh continues
# to work even when the shell has shadowed `grep` with a function/alias that
# does NOT correctly handle stdin pipes (mimics the Claude Code worker sandbox
# where `grep` is wrapped to invoke `claude -G ugrep`).
#
# Strategy:
#   1. Define a `grep` shell function that always returns 1 — simulates a
#      pipe-incompatible shadow.
#   2. Export it so child shells inherit it.
#   3. Source doey-send.sh, which captures DOEY_GREP from absolute paths at
#      sourcing time, bypassing the shadow.
#   4. Drive doey_wait_for_prompt's pipe-grep code path against a captured
#      string containing ❯ and assert it returns success.
#
# This test FAILS on the unfixed code (where bare `grep` is used in pipes) and
# PASSES on the fixed code (where DOEY_GREP is used).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEND_SH="$REPO_ROOT/shell/doey-send.sh"

[ -f "$SEND_SH" ] || { echo "FAIL: $SEND_SH not found" >&2; exit 1; }

run_in_subshell() {
  bash <<'INNER_EOF'
set -euo pipefail

# ── Shadow grep with a pipe-broken function (simulates worker sandbox) ──
grep() {
  echo "test-shadow: shadowed grep called — should not be reachable in detection paths" >&2
  return 1
}
export -f grep

# Source the helper. doey-send.sh must capture an absolute grep path into
# DOEY_GREP at source time, bypassing this function shadow.
# shellcheck disable=SC1091
source "${SEND_SH:?SEND_SH unset}"

# Verify DOEY_GREP resolved to an absolute, executable grep — not the shadow.
case "${DOEY_GREP:-}" in
  /*) [ -x "$DOEY_GREP" ] || { echo "FAIL: DOEY_GREP=$DOEY_GREP not executable" >&2; exit 1; } ;;
  *)  echo "FAIL: DOEY_GREP did not resolve to an absolute path: '${DOEY_GREP:-<unset>}'" >&2; exit 1 ;;
esac

# ── Drive the prompt-detection pipe directly (mirrors doey_wait_for_prompt) ──
captured="$(printf 'line1\nclaude prompt ❯ here\nline3\n')"
if ! printf '%s' "$captured" | "$DOEY_GREP" -qF '❯' 2>/dev/null; then
  echo "FAIL: DOEY_GREP failed to detect ❯ in captured pane output" >&2
  exit 1
fi

# ── Drive the activity check too ──
captured_activity="$(printf 'Reading file...\n')"
if ! _doey_send_check_activity "$captured_activity"; then
  echo "FAIL: _doey_send_check_activity could not detect 'Reading' activity marker" >&2
  exit 1
fi

# ── Negative case: bare `grep` IS shadowed — sanity check the simulation ──
if printf '%s' "$captured" | grep -qF '❯' 2>/dev/null; then
  echo "FAIL: shadow not in effect — test setup is wrong" >&2
  exit 1
fi

echo "PASS: prompt + activity detection survive grep shadow"
INNER_EOF
}

export SEND_SH

if run_in_subshell; then
  echo "test-doey-send-sandbox: OK"
  exit 0
fi

echo "test-doey-send-sandbox: FAILED" >&2
exit 1
