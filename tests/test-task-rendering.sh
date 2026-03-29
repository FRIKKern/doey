#!/usr/bin/env bash
# Test: Task rendering — verify doey-render-task.sh output for v1, v3, width, ASCII, compact modes
set -euo pipefail

PASS=0; FAIL=0

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

# Helper: check that a variable contains a pattern
_contains() {
  local haystack="$1" needle="$2"
  printf '%s' "$haystack" | grep -q "$needle"
}

# Helper: check that a variable does NOT contain a pattern
_not_contains() {
  local haystack="$1" needle="$2"
  ! printf '%s' "$haystack" | grep -q "$needle"
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="${SCRIPT_DIR}/shell/doey-render-task.sh"

if [ ! -f "$RENDER" ]; then
  echo "Error: render script not found: $RENDER"
  exit 1
fi

source "${SCRIPT_DIR}/shell/doey-task-helpers.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "${TEST_DIR}/.doey/tasks"

# ── 1. Legacy v1 .task file (no .json) ─────────────────────────────────
echo "=== Test: Legacy v1 .task file ==="

V1_FILE="${TEST_DIR}/.doey/tasks/99.task"
printf 'TASK_ID=99\nTASK_TITLE=Legacy task title\nTASK_STATUS=active\nTASK_CREATED=%s\nTASK_DESCRIPTION=A v1 legacy task\n' "$(date +%s)" > "$V1_FILE"

V1_OUT=$(bash "$RENDER" "$V1_FILE" 2>&1) || true
_test "v1 renders successfully" test -n "$V1_OUT"
_test "v1 output contains task title" _contains "$V1_OUT" "Legacy task title"
_test "v1 output contains task ID" _contains "$V1_OUT" "#99"
_test "v1 output contains description" _contains "$V1_OUT" "A v1 legacy task"

# ── 2. Structured v3 .task + .json pair ────────────────────────────────
echo ""
echo "=== Test: Structured v3 .task + .json ==="

V3_ID=$(task_create "$TEST_DIR" "Implement search feature" "feature" "Boss" "Full-text search")

# Create companion .json with structured data
INTENT="Enable users to find content quickly" \
HYPOTHESES="Fuzzy matching improves results\\nIndex speeds up queries" \
DELIVERABLES="Search API endpoint\\nFrontend search component" \
FORCE=1 \
task_write_json "$TEST_DIR" "$V3_ID"

V3_OUT=$(bash "$RENDER" "${TEST_DIR}/.doey/tasks/${V3_ID}.task" 2>&1) || true
_test "v3 renders successfully" test -n "$V3_OUT"
_test "v3 output contains Intent section" _contains "$V3_OUT" "Intent"
_test "v3 output contains intent text" _contains "$V3_OUT" "find content quickly"
_test "v3 output contains hypothesis" _contains "$V3_OUT" "Fuzzy matching"
_test "v3 output contains deliverable" _contains "$V3_OUT" "Search API endpoint"

# ── 3. Width modes ─────────────────────────────────────────────────────
echo ""
echo "=== Test: Width modes ==="

W80_OUT=$(COLUMNS=80 bash "$RENDER" "${TEST_DIR}/.doey/tasks/${V3_ID}.task" 2>&1) || true
_test "width 80 renders without crash" test -n "$W80_OUT"

W140_OUT=$(COLUMNS=140 bash "$RENDER" "${TEST_DIR}/.doey/tasks/${V3_ID}.task" 2>&1) || true
_test "width 140 renders without crash" test -n "$W140_OUT"

# ── 4. DOEY_ASCII_ONLY mode ───────────────────────────────────────────
echo ""
echo "=== Test: ASCII-only mode ==="

ASCII_OUT=$(DOEY_ASCII_ONLY=1 bash "$RENDER" "${TEST_DIR}/.doey/tasks/${V3_ID}.task" 2>&1) || true
_test "ASCII mode renders successfully" test -n "$ASCII_OUT"
_test "ASCII mode uses * symbol" _contains "$ASCII_OUT" '\*'
_test "ASCII mode does not contain diamond" _not_contains "$ASCII_OUT" '◆'

# ── 5. Compact density mode ───────────────────────────────────────────
echo ""
echo "=== Test: Compact density mode ==="

NORMAL_OUT=$(bash "$RENDER" "${TEST_DIR}/.doey/tasks/${V3_ID}.task" 2>&1) || true
COMPACT_OUT=$(DOEY_VISUALIZATION_DENSITY=compact bash "$RENDER" "${TEST_DIR}/.doey/tasks/${V3_ID}.task" 2>&1) || true
NORMAL_LINES=$(echo "$NORMAL_OUT" | wc -l | tr -d ' ')
COMPACT_LINES=$(echo "$COMPACT_OUT" | wc -l | tr -d ' ')
_test "compact mode renders successfully" test -n "$COMPACT_OUT"
_test "compact mode is shorter than normal" test "$COMPACT_LINES" -lt "$NORMAL_LINES"

# ── 6. Missing .json graceful fallback ─────────────────────────────────
echo ""
echo "=== Test: Missing .json graceful fallback ==="

NOJSON_FILE="${TEST_DIR}/.doey/tasks/88.task"
printf 'TASK_SCHEMA_VERSION=3\nTASK_ID=88\nTASK_TITLE=Task without JSON\nTASK_STATUS=active\nTASK_TYPE=bug\nTASK_CREATED_BY=Worker\nTASK_TIMESTAMPS=created=%s\n' "$(date +%s)" > "$NOJSON_FILE"
# Ensure no .json exists
rm -f "${TEST_DIR}/.doey/tasks/88.json"

NOJSON_OUT=$(bash "$RENDER" "$NOJSON_FILE" 2>&1)
NOJSON_RC=$?
_test "missing json exits 0" test "$NOJSON_RC" -eq 0
_test "missing json shows title" _contains "$NOJSON_OUT" "Task without JSON"
_test "missing json shows status" _contains "$NOJSON_OUT" "active"

# ── 7. --id and --runtime flags ───────────────────────────────────────
echo ""
echo "=== Test: --id and --runtime flags ==="

FLAG_ID=$(task_create "$TEST_DIR" "Flag test task")

# Render script expects runtime_dir with tasks/ subdir or session.env pointing to project
# Sync task to a fake runtime dir so --runtime lookup works
FAKE_RT="${TEST_DIR}/runtime"
mkdir -p "${FAKE_RT}/tasks"
cp "${TEST_DIR}/.doey/tasks/${FLAG_ID}.task" "${FAKE_RT}/tasks/"

FLAG_OUT=$(bash "$RENDER" --id "$FLAG_ID" --runtime "$FAKE_RT" 2>&1) || true
_test "--id/--runtime renders successfully" test -n "$FLAG_OUT"
_test "--id/--runtime contains task title" _contains "$FLAG_OUT" "Flag test task"
_test "--id/--runtime contains task ID" _contains "$FLAG_OUT" "#${FLAG_ID}"

# ── Results ────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$FAIL"
