#!/usr/bin/env bash
# Test: Error logging system — verify _log_error(), _log_block(), _log_lint_error(), _log_error_wd()
set -euo pipefail

PASS=0; FAIL=0
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

_test() {
  local desc="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
  fi
}

HOOKS_DIR="$(cd "$(dirname "$0")/../.claude/hooks" && pwd)"

echo "=== Test: _log_error() in common.sh ==="

# Set up mock environment
export RUNTIME_DIR="$TEST_DIR/runtime"
export DOEY_PANE_ID="test-w1"
export DOEY_ROLE="worker"
export DOEY_RUNTIME="$RUNTIME_DIR"
export _DOEY_HOOK_NAME="test-hook"
export _DOEY_TOOL_NAME="Bash"
mkdir -p "$RUNTIME_DIR"/{errors,logs,status,research,reports,results,messages}

# Source common.sh components we need
# We can't call init_hook (needs tmux), so manually set required vars
export PANE="test:1.1"
export PANE_SAFE="test_1_1"
export SESSION_NAME="test"
export PANE_INDEX="1"
export WINDOW_INDEX="1"
export NOW=$(date +%s)

# Source only the functions from common.sh
. "$HOOKS_DIR/common.sh" 2>/dev/null <<< '{}' || true

# Test _log_error exists
_test "function _log_error exists" type _log_error >/dev/null 2>&1

# Call _log_error
_log_error "TOOL_BLOCKED" "test block message" "detail=test"

# Check errors.log
_test "errors.log created" test -f "$RUNTIME_DIR/errors/errors.log"
_test "errors.log has TOOL_BLOCKED" grep -q "TOOL_BLOCKED" "$RUNTIME_DIR/errors/errors.log"
_test "errors.log has pane_id" grep -q "test-w1" "$RUNTIME_DIR/errors/errors.log"
_test "errors.log has role" grep -q "worker" "$RUNTIME_DIR/errors/errors.log"
_test "errors.log has hook name" grep -q "test-hook" "$RUNTIME_DIR/errors/errors.log"
_test "errors.log has tool name" grep -q "Bash" "$RUNTIME_DIR/errors/errors.log"

# Check .err file
ERR_COUNT=$(find "$RUNTIME_DIR/errors" -name '*.err' | wc -l | tr -d ' ')
_test ".err file created" test "$ERR_COUNT" -ge 1
if [ "$ERR_COUNT" -ge 1 ]; then
  ERR_FILE=$(find "$RUNTIME_DIR/errors" -name '*.err' | head -1)
  _test ".err has CATEGORY" grep -q "CATEGORY=TOOL_BLOCKED" "$ERR_FILE"
  _test ".err has PANE_ID" grep -q "PANE_ID=test-w1" "$ERR_FILE"
  _test ".err has ROLE" grep -q "ROLE=worker" "$ERR_FILE"
  _test ".err has MESSAGE" grep -q "MESSAGE=test block message" "$ERR_FILE"
fi

# Check per-pane log
_test "per-pane log has ERROR prefix" grep -q "ERROR \[TOOL_BLOCKED\]" "$RUNTIME_DIR/logs/test-w1.log"

echo ""
echo "=== Test: _log_block() in on-pre-tool-use.sh ==="

# Reset error log
: > "$RUNTIME_DIR/errors/errors.log"

# Source and test _log_block from on-pre-tool-use
export TOOL_NAME="Bash"
export _DOEY_ROLE="worker"

# Extract and eval just the _log_block function
eval "$(sed -n '/_log_block()/,/^}/p' "$HOOKS_DIR/on-pre-tool-use.sh")"

_test "function _log_block exists" type _log_block >/dev/null 2>&1

_log_block "TOOL_BLOCKED" "test worker block" "detail=cmd"
_test "_log_block wrote to errors.log" grep -q "TOOL_BLOCKED" "$RUNTIME_DIR/errors/errors.log"
_test "_log_block includes on-pre-tool-use" grep -q "on-pre-tool-use" "$RUNTIME_DIR/errors/errors.log"

echo ""
echo "=== Test: _log_lint_error() in post-tool-lint.sh ==="

: > "$RUNTIME_DIR/errors/errors.log"
eval "$(sed -n '/_log_lint_error()/,/^}/p' "$HOOKS_DIR/post-tool-lint.sh")"
_test "function _log_lint_error exists" type _log_lint_error >/dev/null 2>&1

_log_lint_error "test lint violation" "bash4_syntax_found"
_test "_log_lint_error wrote to errors.log" grep -q "LINT_ERROR" "$RUNTIME_DIR/errors/errors.log"
_test "_log_lint_error includes post-tool-lint" grep -q "post-tool-lint" "$RUNTIME_DIR/errors/errors.log"

echo ""
echo "=== Test: Error log format ==="

: > "$RUNTIME_DIR/errors/errors.log"
_log_error "DELIVERY_FAILED" "notification dropped" "target=doey:1.0"
LINE=$(cat "$RUNTIME_DIR/errors/errors.log")
_test "log line has 7 pipe-delimited fields" test "$(echo "$LINE" | tr '|' '\n' | wc -l | tr -d ' ')" -eq 7
_test "log line starts with timestamp" echo "$LINE" | grep -qE '^\[20[0-9]{2}-'

echo ""
echo "=== Test: Error categories ==="

: > "$RUNTIME_DIR/errors/errors.log"
for cat in TOOL_BLOCKED LINT_ERROR ANOMALY HOOK_ERROR DELIVERY_FAILED; do
  _log_error "$cat" "test $cat"
done
for cat in TOOL_BLOCKED LINT_ERROR ANOMALY HOOK_ERROR DELIVERY_FAILED; do
  _test "category $cat logged" grep -q "$cat" "$RUNTIME_DIR/errors/errors.log"
done

echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$FAIL"
