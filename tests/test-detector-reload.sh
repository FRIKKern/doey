#!/usr/bin/env bash
# tests/test-detector-reload.sh — auto-reload-on-mtime via exec preserves PID.
set -euo pipefail

SRC="/home/doey/doey/shell/silent-fail-detector.sh"
[ -x "$SRC" ] || { echo "FAIL: detector source not executable"; exit 1; }

PASS=0
FAIL=0

assert_pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
assert_fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }

ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t detector-reload)
DETECTOR_COPY="$ROOT/silent-fail-detector.sh"
cp "$SRC" "$DETECTOR_COPY"
chmod +x "$DETECTOR_COPY"

PID_FILE="$ROOT/runtime/silent-fail-detector.pid"
LOG_FILE="$ROOT/runtime/findings/detector.log"

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

# Tick fast (1s) and reload-check every 2 ticks for a deterministic test.
# Sandbox the project dir + disable expensive detectors so each tick is cheap.
RUNTIME_DIR="$ROOT/runtime" \
  DOEY_DETECTOR_TICK=1 \
  DOEY_DETECTOR_RELOAD_EVERY=2 \
  DOEY_PROJECT_DIR="$ROOT" \
  DOEY_DETECTOR_DISABLE="R-14 R-15 R-16 R-17" \
  bash "$DETECTOR_COPY" start

# Wait for PID to land.
i=0
while [ "$i" -lt 30 ]; do
  [ -f "$PID_FILE" ] && break
  sleep 0.1
  i=$((i + 1))
done
[ -f "$PID_FILE" ] || { assert_fail "pid_file_present" "never appeared"; exit 1; }
assert_pass "pid_file_present"

INITIAL_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
INITIAL_PID="${INITIAL_PID%%[!0-9]*}"
[ -n "$INITIAL_PID" ] || { assert_fail "initial_pid_nonempty" ""; exit 1; }
assert_pass "initial_pid_nonempty"

# Capture initial mtime line count to know "before".
sleep 1.5  # let one tick run + log a line
INITIAL_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)

# Bump mtime on the source script — set forward by 5s to defeat 1s mtime granularity.
new_mtime=$(($(stat -c %Y "$DETECTOR_COPY" 2>/dev/null || stat -f %m "$DETECTOR_COPY") + 5))
if ! touch -d "@$new_mtime" "$DETECTOR_COPY" 2>/dev/null; then
  if ! touch -t "$(date -r "$new_mtime" +%Y%m%d%H%M.%S 2>/dev/null)" "$DETECTOR_COPY" 2>/dev/null; then
    sleep 1
    touch "$DETECTOR_COPY"
  fi
fi

# Wait for the daemon to detect mtime bump and exec — up to ~5s.
RELOADED=0
i=0
while [ "$i" -lt 50 ]; do
  if grep -Fq "source mtime changed" "$LOG_FILE" 2>/dev/null; then
    RELOADED=1
    break
  fi
  sleep 0.1
  i=$((i + 1))
done

if [ "$RELOADED" = "1" ]; then
  assert_pass "reload_log_line_seen"
else
  assert_fail "reload_log_line_seen" "no 'source mtime changed' in log after 5s"
  echo "    DEBUG log dump:"
  sed 's/^/      /' "$LOG_FILE" 2>/dev/null
  echo "    DEBUG mtime: $(stat -c %Y "$DETECTOR_COPY" 2>/dev/null)"
fi

# After exec, PID must be preserved.
sleep 1
CURRENT_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
CURRENT_PID="${CURRENT_PID%%[!0-9]*}"
if [ "$CURRENT_PID" = "$INITIAL_PID" ]; then
  assert_pass "pid_preserved_across_exec"
else
  assert_fail "pid_preserved_across_exec" "before=$INITIAL_PID after=$CURRENT_PID"
fi

# A new "DAEMON start" line must appear post-reload (proves child re-entered main loop).
NEW_DAEMON_LINES=$(grep -c "DAEMON start" "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$NEW_DAEMON_LINES" -ge 2 ]; then
  assert_pass "second_daemon_start_logged"
else
  assert_fail "second_daemon_start_logged" "DAEMON start count=$NEW_DAEMON_LINES expected >=2"
fi

echo "─────────────────────────────────"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
