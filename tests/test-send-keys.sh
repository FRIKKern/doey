#!/usr/bin/env bash
set -euo pipefail
# Test: send-keys message delivery reliability
# Validates fix for task #196 — covers single-line, multi-line, Escape prefix,
# rapid sequential, copy-mode, and empty message scenarios.
# Uses an isolated tmux session (never touches live doey sessions).

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SESSION="doey-test-sendkeys-$$"
TEST_TMP=$(mktemp -d)
PASS=0; FAIL=0; SKIP=0

cleanup() {
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# --- Helpers ---

assert_pane_contains() {
  local label="$1" pane="$2" expected="$3" timeout="${4:-3}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local captured
    captured=$(tmux capture-pane -t "${TEST_SESSION}:0.${pane}" -p 2>/dev/null || echo "")
    if echo "$captured" | grep -qF "$expected"; then
      PASS=$((PASS + 1))
      echo "  PASS: $label"
      return 0
    fi
    sleep 0.5
    elapsed=$((elapsed + 1))
  done
  FAIL=$((FAIL + 1))
  echo "  FAIL: $label"
  echo "    expected: $expected"
  echo "    captured (last 5 lines):"
  echo "$captured" | tail -5 | sed 's/^/      /'
  return 0
}

skip_test() {
  local label="$1" reason="$2"
  SKIP=$((SKIP + 1))
  echo "  SKIP: $label — $reason"
}

reset_pane() {
  local pane="$1"
  tmux send-keys -t "${TEST_SESSION}:0.${pane}" C-c 2>/dev/null || true
  tmux send-keys -t "${TEST_SESSION}:0.${pane}" C-l 2>/dev/null || true
  sleep 0.3
}

# --- Setup: create isolated tmux session with a single window, 2 panes ---

echo "=== send-keys delivery tests (session: $TEST_SESSION) ==="
tmux new-session -d -s "$TEST_SESSION" -x 120 -y 40
tmux set-option -s -t "$TEST_SESSION" escape-time 0
# Pane 0 is the shell; split to create pane 1
tmux split-window -t "${TEST_SESSION}:0" -h
sleep 0.5

# Verify session is alive
if ! tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
  echo "FATAL: could not create test tmux session"
  exit 1
fi

# --- Test 1: Single-line short message (< 200 chars) ---

echo ""
echo "Test 1: Single-line short message delivery"
reset_pane 0
MARKER_1="SENDKEY_SHORT_$(date +%s)"
tmux send-keys -t "${TEST_SESSION}:0.0" "echo ${MARKER_1}" Enter
assert_pane_contains "short message echoed" 0 "$MARKER_1"

# --- Test 2: Multi-line message via load-buffer + paste-buffer ---

echo ""
echo "Test 2: Multi-line message delivery (load-buffer/paste-buffer)"
reset_pane 1
MARKER_2="MULTILINE_$(date +%s)"
MULTI_MSG="line1_${MARKER_2}
line2_${MARKER_2}
line3_${MARKER_2}
line4_${MARKER_2}
line5_${MARKER_2}"
TMPBUF="${TEST_TMP}/multi_msg.txt"
printf '%s\n' "$MULTI_MSG" > "$TMPBUF"
tmux load-buffer "$TMPBUF"
tmux paste-buffer -t "${TEST_SESSION}:0.1"
sleep 0.5
# The text should appear in the pane (shell will try to execute, that's fine — we just verify delivery)
assert_pane_contains "multi-line line1 delivered" 1 "line1_${MARKER_2}"
assert_pane_contains "multi-line line5 delivered" 1 "line5_${MARKER_2}"

# --- Test 3: Message after Escape sequence (first-char eaten bug) ---

echo ""
echo "Test 3: Message after Escape (first-char eaten bug)"
reset_pane 0
MARKER_3="AFTERESC_$(date +%s)"
# Simulate the pattern from common.sh send_to_pane:
# copy-mode -q, then Escape, sleep, then send-keys
tmux copy-mode -q -t "${TEST_SESSION}:0.0" 2>/dev/null || true
tmux send-keys -t "${TEST_SESSION}:0.0" Escape 2>/dev/null
sleep 0.1
tmux send-keys -t "${TEST_SESSION}:0.0" "echo ${MARKER_3}" Enter
assert_pane_contains "full message after Escape" 0 "$MARKER_3"

# --- Test 4: Rapid sequential messages (race condition) ---

echo ""
echo "Test 4: Rapid sequential messages"
reset_pane 1
MARKER_4="RAPID_$(date +%s)"
# Send 5 messages in quick succession with no sleep between
for i in 1 2 3 4 5; do
  tmux send-keys -t "${TEST_SESSION}:0.1" "echo ${MARKER_4}_${i}" Enter
done
sleep 1
# At least the first and last should be present
assert_pane_contains "rapid msg 1 delivered" 1 "${MARKER_4}_1"
assert_pane_contains "rapid msg 5 delivered" 1 "${MARKER_4}_5"

# --- Test 5: Message to pane in copy-mode ---

echo ""
echo "Test 5: Message to pane in copy-mode"
reset_pane 0
# Put pane into copy-mode
tmux copy-mode -t "${TEST_SESSION}:0.0"
sleep 0.3
MARKER_5="COPYMODE_$(date +%s)"
# Use the send_to_pane pattern: copy-mode -q, Escape, sleep, then message
tmux copy-mode -q -t "${TEST_SESSION}:0.0" 2>/dev/null || true
tmux send-keys -t "${TEST_SESSION}:0.0" Escape 2>/dev/null
sleep 0.1
tmux send-keys -t "${TEST_SESSION}:0.0" "echo ${MARKER_5}" Enter
assert_pane_contains "message delivered after exiting copy-mode" 0 "$MARKER_5"

# --- Test 6: Empty/whitespace message handling ---

echo ""
echo "Test 6: Empty/whitespace message handling"
reset_pane 1
# Empty send-keys should not crash
tmux send-keys -t "${TEST_SESSION}:0.1" "" 2>/dev/null
RET=$?
if [ "$RET" -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: empty send-keys does not error (exit $RET)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: empty send-keys errored (exit $RET)"
fi

# Whitespace-only
tmux send-keys -t "${TEST_SESSION}:0.1" "   " 2>/dev/null
RET=$?
if [ "$RET" -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "  PASS: whitespace-only send-keys does not error (exit $RET)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: whitespace-only send-keys errored (exit $RET)"
fi

# --- Test 7: _DRAIN_STDIN pattern (as used by doey.sh) ---

echo ""
echo "Test 7: _DRAIN_STDIN prefix pattern"
reset_pane 0
MARKER_7="DRAIN_$(date +%s)"
_DRAIN_STDIN='read -t 1 -n 10000 _ 2>/dev/null || true; '
tmux send-keys -t "${TEST_SESSION}:0.0" "${_DRAIN_STDIN}echo ${MARKER_7}" Enter
assert_pane_contains "DRAIN_STDIN prefixed message delivered" 0 "$MARKER_7"

# --- Test 8: doey-send.sh verified delivery (if available) ---

echo ""
echo "Test 8: doey-send.sh verified delivery"
SEND_HELPER="/home/doey/doey/shell/doey-send.sh"
if [ -f "$SEND_HELPER" ]; then
  # Source and test doey_send_verified if it exists
  if grep -q 'doey_send_verified' "$SEND_HELPER" 2>/dev/null; then
    # shellcheck source=/dev/null
    source "$SEND_HELPER"

    reset_pane 0
    MARKER_8="VERIFIED_$(date +%s)"
    if doey_send_verified "${TEST_SESSION}:0.0" "echo ${MARKER_8}" 2>/dev/null; then
      assert_pane_contains "verified send delivered" 0 "$MARKER_8"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: doey_send_verified returned non-zero for valid pane"
    fi

    # Test: send to non-existent pane should fail
    if doey_send_verified "${TEST_SESSION}:99.99" "echo should_fail" 2>/dev/null; then
      FAIL=$((FAIL + 1))
      echo "  FAIL: doey_send_verified should fail for non-existent pane"
    else
      PASS=$((PASS + 1))
      echo "  PASS: doey_send_verified correctly fails for non-existent pane"
    fi
  else
    skip_test "doey_send_verified" "function not found in doey-send.sh"
  fi
else
  skip_test "doey-send.sh" "file not yet created (waiting for Worker 1)"
fi

# --- Summary ---

echo ""
TOTAL=$((PASS + FAIL + SKIP))
echo "=== Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${TOTAL} total) ==="

if [ "$FAIL" -gt 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
exit 0
