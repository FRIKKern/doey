#!/usr/bin/env bash
# tests/test-detector-cleanup.sh — verifies _stop_silent_fail_detector
# (called by doey-session.sh on session stop) terminates the daemon and
# removes the PID file.
set -euo pipefail

DETECTOR="/home/doey/doey/shell/silent-fail-detector.sh"
SESSION_LIB="/home/doey/doey/shell/doey-session.sh"
[ -x "$DETECTOR" ] || { echo "FAIL: detector not executable"; exit 1; }
[ -f "$SESSION_LIB" ] || { echo "FAIL: doey-session.sh missing"; exit 1; }

PASS=0
FAIL=0

assert_pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
assert_fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }

ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t detector-cleanup)
PID_FILE="$ROOT/runtime/silent-fail-detector.pid"

trap 'cleanup' EXIT
cleanup() {
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    pid="${pid%%[!0-9]*}"
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -rf "$ROOT" 2>/dev/null || true
}

mkdir -p "$ROOT/runtime/findings"

RUNTIME_DIR="$ROOT/runtime" DOEY_DETECTOR_TICK=600 bash "$DETECTOR" start

i=0
while [ "$i" -lt 30 ]; do
  [ -f "$PID_FILE" ] && break
  sleep 0.1
  i=$((i + 1))
done
[ -f "$PID_FILE" ] || { assert_fail "daemon_started" ""; exit 1; }
assert_pass "daemon_started"

PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
PID="${PID%%[!0-9]*}"
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  assert_pass "daemon_pid_alive"
else
  assert_fail "daemon_pid_alive" "pid=$PID"
  exit 1
fi

# Source just the cleanup function — full doey-session.sh has many deps.
# We test the function in isolation by extracting it.
extracted=$(awk '
  /^_stop_silent_fail_detector\(\)/ { p=1 }
  p { print }
  p && /^}/ { exit }
' "$SESSION_LIB")

if [ -z "$extracted" ]; then
  assert_fail "extract_stop_function" "function not found in $SESSION_LIB"
  exit 1
fi
assert_pass "extract_stop_function"

# Eval and call.
eval "$extracted"
_stop_silent_fail_detector "$ROOT/runtime"

# PID file should be gone.
if [ -f "$PID_FILE" ]; then
  assert_fail "pid_file_removed" "still present at $PID_FILE"
else
  assert_pass "pid_file_removed"
fi

# Daemon process should be gone.
if kill -0 "$PID" 2>/dev/null; then
  assert_fail "daemon_process_gone" "pid=$PID still alive"
else
  assert_pass "daemon_process_gone"
fi

# Idempotent: second call must not error.
if _stop_silent_fail_detector "$ROOT/runtime" >/dev/null 2>&1; then
  assert_pass "idempotent_second_call"
else
  assert_fail "idempotent_second_call" "exit non-zero on second call"
fi

echo "─────────────────────────────────"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
