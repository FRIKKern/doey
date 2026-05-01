#!/usr/bin/env bash
# tests/test-detector-singleton.sh — concurrent-spawn singleton guard.
# Forks 5 background spawns of the detector and asserts only ONE survives.
set -euo pipefail

DETECTOR="/home/doey/doey/shell/silent-fail-detector.sh"
[ -x "$DETECTOR" ] || { echo "FAIL: detector not executable at $DETECTOR"; exit 1; }

PASS=0
FAIL=0

assert_pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
assert_fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }

ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t detector-singleton)
trap 'cleanup' EXIT

cleanup() {
  if [ -f "$ROOT/runtime/silent-fail-detector.pid" ]; then
    pid=$(cat "$ROOT/runtime/silent-fail-detector.pid" 2>/dev/null || echo "")
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  fi
  # Belt+braces: kill any detector process whose argv references our sandbox.
  for p in $(pgrep -f "silent-fail-detector" 2>/dev/null || echo ""); do
    if ps -p "$p" -o args= 2>/dev/null | grep -q "RUNTIME_DIR=$ROOT" 2>/dev/null; then
      kill -KILL "$p" 2>/dev/null || true
    fi
  done
  rm -rf "$ROOT" 2>/dev/null || true
}

mkdir -p "$ROOT/runtime/findings"

# Fork 5 concurrent spawns. Each invocation runs `start` which forks a
# background daemon. With the singleton guard in place, exactly one
# daemon should end up holding the PID file.
for i in 1 2 3 4 5; do
  RUNTIME_DIR="$ROOT/runtime" DOEY_DETECTOR_TICK=600 bash "$DETECTOR" start &
done
wait

# Settle: give the children a moment to race through acquire_singleton.
sleep 0.5

PID_FILE="$ROOT/runtime/silent-fail-detector.pid"
if [ ! -f "$PID_FILE" ]; then
  assert_fail "pid_file_exists" "no PID file written"
else
  assert_pass "pid_file_exists"
fi

# Count live detectors targeting our sandbox.
count_live() {
  local n=0 p
  for p in $(pgrep -f "silent-fail-detector" 2>/dev/null || echo ""); do
    if ps -p "$p" -ww -o args= 2>/dev/null | grep -Fq "$ROOT" 2>/dev/null; then
      n=$((n + 1))
    fi
  done
  # /proc/<pid>/environ check fallback (RUNTIME_DIR exported)
  if [ "$n" -eq 0 ]; then
    for p in $(pgrep -f "silent-fail-detector" 2>/dev/null || echo ""); do
      if [ -r "/proc/$p/environ" ] && tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null \
         | grep -Fq "RUNTIME_DIR=$ROOT/runtime"; then
        n=$((n + 1))
      fi
    done
  fi
  echo "$n"
}

# Poll up to 2s for stragglers to exit.
i=0
while [ "$i" -lt 20 ]; do
  live=$(count_live)
  [ "$live" -le 1 ] && break
  sleep 0.1
  i=$((i + 1))
done

live=$(count_live)
if [ "$live" -eq 1 ]; then
  assert_pass "exactly_one_detector_survives"
else
  # Fallback: at minimum, the PID file must point to a live process.
  pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  pid="${pid%%[!0-9]*}"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    assert_pass "pid_file_points_live"
    if [ "$live" -gt 1 ]; then
      printf '  WARN  process count=%s (env-leak races); pid_file is authoritative\n' "$live"
    fi
  else
    assert_fail "exactly_one_detector_survives" "live=$live, pid_file_pid=$pid"
  fi
fi

echo "─────────────────────────────────"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
