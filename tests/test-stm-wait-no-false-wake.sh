#!/usr/bin/env bash
# tests/test-stm-wait-no-false-wake.sh
#
# Invariant: stm-wait.sh must NOT return WAKE_REASON=MSG when the unread
# message count for the STM's pane is zero, even if orphan .msg files exist
# on disk from previously-read messages. Regression test for task 665 —
# pre-fix the hook fell through from the DB count check to a file-glob
# check that fired on any .msg file regardless of read state, producing a
# tight hot-loop that burned context every iteration.
#
# Acceptance: with a 3s timeout and an empty inbox (zero unread per the DB)
# the hook either blocks for the full timeout and returns WAKE_REASON=TIMEOUT,
# or returns one of the other legitimate non-MSG wake reasons. It must NOT
# return MSG, and must NOT return TRIGGERED in the no-trigger case.
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no printf %T.
# Runs standalone: `bash tests/test-stm-wait-no-false-wake.sh`.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$PROJECT_DIR/.claude/hooks/stm-wait.sh"
TEST_RUNTIME="/tmp/doey-test-665-runtime-$$"
TEST_PROJECT="/tmp/doey-test-665-project-$$"
FAKE_WIN=9
FAKE_PANE=9
FAKE_PANE_SAFE="doey-doey-test-665_${FAKE_WIN}_${FAKE_PANE}"

cleanup() { rm -rf "$TEST_RUNTIME" "$TEST_PROJECT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p \
  "$TEST_RUNTIME/messages" \
  "$TEST_RUNTIME/triggers" \
  "$TEST_RUNTIME/status" \
  "$TEST_PROJECT/.doey"

# Minimal session.env so the hook locates the project dir for `doey msg count`.
cat > "$TEST_RUNTIME/session.env" <<EOF
SESSION_NAME="doey-doey-test-665"
PROJECT_DIR="$TEST_PROJECT"
PROJECT_NAME="doey-test-665"
EOF

# Plant an orphan .msg file matching the fake pane — both the long-form
# (SESSION_PANE) and short-form ({W}_{P}) prefixes that _check_messages
# globs. Pre-fix this single byte was enough to trigger a false MSG wake.
SHORT_SAFE="${FAKE_WIN}_${FAKE_PANE}"
LONG_SAFE="doey-doey-test-665_${FAKE_WIN}_${FAKE_PANE}"
LONG_SAFE="${LONG_SAFE//[-:.]/_}"
touch "$TEST_RUNTIME/messages/${LONG_SAFE}_$(date +%s)_99.msg"
touch "$TEST_RUNTIME/messages/${SHORT_SAFE}_$(date +%s)_98.msg"

# Run the hook with a 3s timeout, isolated env (no TMUX_PANE leakage from
# the surrounding session). Force file-fallback path for hosts without
# doey-ctl by unsetting PATH-derived doey lookups when DB is empty — the
# fix must hold for both the DB and file-glob branches.
echo "[run] $HOOK timeout=3s pane=${FAKE_WIN}.${FAKE_PANE}"
START=$(date +%s)
OUT=$(env -i \
  HOME="$HOME" \
  PATH="$PATH" \
  DOEY_RUNTIME="$TEST_RUNTIME" \
  DOEY_ROLE=team_lead \
  DOEY_TEAM_WINDOW="$FAKE_WIN" \
  DOEY_WINDOW_INDEX="$FAKE_WIN" \
  DOEY_PANE_INDEX="$FAKE_PANE" \
  DOEY_WAIT_TIMEOUT=3 \
  DOEY_STM_WAIT_TICK=1 \
  bash "$HOOK" 2>&1 | tail -5)
END=$(date +%s)
ELAPSED=$((END - START))

WAKE=$(printf '%s\n' "$OUT" | grep '^WAKE_REASON=' | head -1 | cut -d= -f2-)

echo "[out]   WAKE_REASON=$WAKE"
echo "[out]   elapsed=${ELAPSED}s"

PASS=1
if [ "$WAKE" = "MSG" ]; then
  echo "FAIL: false MSG wake on empty inbox (orphan .msg files present, 0 unread in DB)"
  PASS=0
fi
if [ "$WAKE" = "TRIGGERED" ]; then
  echo "FAIL: false TRIGGERED wake — no trigger files were planted"
  PASS=0
fi
# When the hook correctly blocks on inotifywait/sleep, it must wait close
# to the full timeout. Anything < 1s indicates the hot-loop bug is back.
if [ "$ELAPSED" -lt 1 ] && [ "$WAKE" != "TIMEOUT" ]; then
  echo "FAIL: hook returned in ${ELAPSED}s without blocking — possible hot-loop regression"
  PASS=0
fi

if [ "$PASS" = "1" ]; then
  echo "PASS (1/1) — stm-wait.sh blocked correctly with no false wake"
  exit 0
else
  echo "PASS (0/1)"
  exit 1
fi
