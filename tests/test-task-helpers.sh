#!/usr/bin/env bash
# Test: doey-task-helpers.sh — task_create, task_list, task_read, task_update_status,
#   task_upgrade_schema, task_dispatch_msg, task_write_json, task_commit_msg
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0

_test() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1)); printf "  ✗ %s\n" "$desc"
  fi
}

_test_fails() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); printf "  ✗ %s\n" "$desc"
  else
    PASS=$((PASS + 1)); printf "  ✓ %s\n" "$desc"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/shell/doey-task-helpers.sh"

# Helper: check that a string contains a pattern
_contains() { printf '%s' "$1" | grep -q "$2"; }

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "${TEST_DIR}/.doey/tasks"

# Helper: write string to temp file for grepping
_tmp="${TEST_DIR}/_test_output"

# ── 1. task_create ──────────────────────────────────────────────────
echo "=== Test: task_create ==="

ID=$(task_create "$TEST_DIR" "Build login page" "feature" "Boss" "Full login flow")

_test "task_create returns an ID" test -n "$ID"
_test ".task file exists" test -f "${TEST_DIR}/.doey/tasks/${ID}.task"
_test "TASK_ID is set in .task" grep -q "TASK_ID=${ID}" "${TEST_DIR}/.doey/tasks/${ID}.task"
_test "TASK_SCHEMA_VERSION=3 in .task" grep -q "TASK_SCHEMA_VERSION=3" "${TEST_DIR}/.doey/tasks/${ID}.task"

# ── 2. task_create defaults ─────────────────────────────────────────
echo ""
echo "=== Test: task_create defaults ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

ID2=$(task_create "$TEST_DIR" "Minimal task")
task_read "${TEST_DIR}/.doey/tasks/${ID2}.task"

_test "default type is feature" test "$TASK_TYPE" = "feature"
_test "default created_by is Boss" test "$TASK_CREATED_BY" = "Boss"
_test "TASK_TIMESTAMPS contains created=" _contains "$TASK_TIMESTAMPS" "created="

# ── 3. task_list ────────────────────────────────────────────────────
echo ""
echo "=== Test: task_list ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

task_create "$TEST_DIR" "Alpha task" "feature" "Boss" >/dev/null
task_create "$TEST_DIR" "Beta task" "bug" "Boss" >/dev/null
task_create "$TEST_DIR" "Gamma task" "feature" "Boss" >/dev/null

task_list "$TEST_DIR" > "$_tmp"

_test "task_list output is non-empty" test -s "$_tmp"
_test "output contains Alpha task" grep -q "Alpha task" "$_tmp"
_test "output contains Beta task" grep -q "Beta task" "$_tmp"
_test "output contains Gamma task" grep -q "Gamma task" "$_tmp"

# ── 4. task_list --all ──────────────────────────────────────────────
echo ""
echo "=== Test: task_list --all ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

DONE_ID=$(task_create "$TEST_DIR" "Finished work")
task_update_status "$TEST_DIR" "$DONE_ID" "done"

task_list "$TEST_DIR" > "$_tmp"
_test_fails "task_list hides done tasks" grep -q "Finished work" "$_tmp"

task_list "$TEST_DIR" --all > "$_tmp"
_test "task_list --all shows done tasks" grep -q "Finished work" "$_tmp"

# ── 5. task_read ────────────────────────────────────────────────────
echo ""
echo "=== Test: task_read ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

READ_ID=$(task_create "$TEST_DIR" "Read me" "bug" "SM" "Desc here")
task_read "${TEST_DIR}/.doey/tasks/${READ_ID}.task"

_test "TASK_ID set" test "$TASK_ID" = "$READ_ID"
_test "TASK_TITLE set" test "$TASK_TITLE" = "Read me"
_test "TASK_STATUS set" test "$TASK_STATUS" = "active"
_test "TASK_TYPE set" test "$TASK_TYPE" = "bug"
_test "TASK_SCHEMA_VERSION set" test "$TASK_SCHEMA_VERSION" = "3"

# ── 6. task_read legacy v1 ──────────────────────────────────────────
echo ""
echo "=== Test: task_read legacy v1 ==="

V1_FILE="${TEST_DIR}/.doey/tasks/99.task"
printf 'TASK_ID=99\nTASK_TITLE=Legacy task\nTASK_STATUS=active\nTASK_CREATED=1700000000\n' > "$V1_FILE"

task_read "$V1_FILE"

_test "v1 TASK_SCHEMA_VERSION defaults to 1" test "$TASK_SCHEMA_VERSION" = "1"
_test "v1 TASK_TYPE defaults to feature" test "$TASK_TYPE" = "feature"
_test "v1 TASK_CREATED_BY defaults to Boss" test "$TASK_CREATED_BY" = "Boss"

# ── 7. task_update_status ───────────────────────────────────────────
echo ""
echo "=== Test: task_update_status ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

UPD_ID=$(task_create "$TEST_DIR" "Status test")
task_update_status "$TEST_DIR" "$UPD_ID" "in_progress"

_test "status updated to in_progress" grep -q "TASK_STATUS=in_progress" "${TEST_DIR}/.doey/tasks/${UPD_ID}.task"

_test_fails "invalid status returns 1" task_update_status "$TEST_DIR" "$UPD_ID" "bogus"

# ── 8. task_upgrade_schema ──────────────────────────────────────────
echo ""
echo "=== Test: task_upgrade_schema ==="

V1_UPG="${TEST_DIR}/.doey/tasks/88.task"
printf 'TASK_ID=88\nTASK_TITLE=Upgrade me\nTASK_STATUS=active\nTASK_CREATED=1700000000\n' > "$V1_UPG"

task_upgrade_schema "$V1_UPG"

_test "upgraded to TASK_SCHEMA_VERSION=3" grep -q "TASK_SCHEMA_VERSION=3" "$V1_UPG"
_test ".json companion created" test -f "${TEST_DIR}/.doey/tasks/88.json"

# Idempotent — call again
task_upgrade_schema "$V1_UPG"
_test "idempotent upgrade (no error)" test $? -eq 0

# ── 9. task_dispatch_msg ────────────────────────────────────────────
echo ""
echo "=== Test: task_dispatch_msg ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

DISP_ID=$(task_create "$TEST_DIR" "Dispatch me")
task_dispatch_msg "$TEST_DIR" "$DISP_ID" > "$_tmp"

_test "output contains SUBJECT: dispatch_task" grep -q "SUBJECT: dispatch_task" "$_tmp"
_test "output contains TASK_ID=" grep -q "TASK_ID=" "$_tmp"
_test "output contains TASK_FILE path" grep -q "TASK_FILE=" "$_tmp"
_test "output contains TASK_JSON path" grep -q "TASK_JSON=" "$_tmp"
_test_fails "non-existent task returns 1" task_dispatch_msg "$TEST_DIR" "999"

# ── 10. .next_id counter ───────────────────────────────────────────
echo ""
echo "=== Test: .next_id counter ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

CID1=$(task_create "$TEST_DIR" "First")
CID2=$(task_create "$TEST_DIR" "Second")
CID3=$(task_create "$TEST_DIR" "Third")

_test "first ID is 1" test "$CID1" = "1"
_test "second ID is 2" test "$CID2" = "2"
_test "third ID is 3" test "$CID3" = "3"
_test ".next_id contains 4" test "$(cat "${TEST_DIR}/.doey/tasks/.next_id")" = "4"

# ── 11. _json_escape ───────────────────────────────────────────────
echo ""
echo "=== Test: _json_escape ==="

ESC1=$(_json_escape 'hello "world"')
_test "escapes double quotes" _contains "$ESC1" '\\"world\\"'

ESC2=$(_json_escape 'back\slash')
_test "escapes backslashes" _contains "$ESC2" '\\\\'

ESC3=$(_json_escape "line1
line2")
_test "escapes newlines" _contains "$ESC3" '\\n'

# ── 12. task_write_json ────────────────────────────────────────────
echo ""
echo "=== Test: task_write_json ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

JSON_ID=$(task_create "$TEST_DIR" "JSON test task" "bugfix" "Boss" "Fix the thing")

INTENT="Fix the widget" \
HYPOTHESES="H1: approach A\\nH2: approach B" \
CONSTRAINTS="Must be fast\\nNo breaking changes" \
SUCCESS_CRITERIA="Tests pass\\nNo regressions" \
DELIVERABLES="Updated widget.go\\nNew tests" \
DISPATCH_MODE="phased" \
DISPATCH_TEAM="managed" \
task_write_json "$TEST_DIR" "$JSON_ID"

JSON_FILE="${TEST_DIR}/.doey/tasks/${JSON_ID}.json"
_test "json file created" test -f "$JSON_FILE"
_test "json is valid" python3 -m json.tool "$JSON_FILE"
_test "json contains task_id" grep -q "\"task_id\": ${JSON_ID}" "$JSON_FILE"
_test "json contains intent" grep -q "Fix the widget" "$JSON_FILE"
_test "json contains hypotheses array" grep -q '"H1: approach A"' "$JSON_FILE"
_test "json contains dispatch mode" grep -q '"mode": "phased"' "$JSON_FILE"

# No-overwrite test
task_write_json "$TEST_DIR" "$JSON_ID" 2>"$_tmp"
_test "warns on existing file" grep -q "already exists" "$_tmp"

# FORCE overwrite
FORCE=1 INTENT="Updated intent" task_write_json "$TEST_DIR" "$JSON_ID"
_test "FORCE=1 overwrites" grep -q "Updated intent" "$JSON_FILE"

# ── 13. task_commit_msg ─────────────────────────────────────────────
echo ""
echo "=== Test: task_commit_msg ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

CM_ID=$(task_create "$TEST_DIR" "Add search feature" "feature")
CM_OUT=$(task_commit_msg "$TEST_DIR" "$CM_ID")
_test "feature -> feat prefix" _contains "$CM_OUT" "^feat:"
_test "contains title" _contains "$CM_OUT" "Add search feature"
_test "contains task ref" _contains "$CM_OUT" "(Task #${CM_ID})"

CM_ID2=$(task_create "$TEST_DIR" "Fix login crash" "bugfix")
CM_OUT2=$(task_commit_msg "$TEST_DIR" "$CM_ID2")
_test "bugfix -> fix prefix" _contains "$CM_OUT2" "^fix:"

CM_ID3=$(task_create "$TEST_DIR" "Research caching" "research")
CM_OUT3=$(task_commit_msg "$TEST_DIR" "$CM_ID3")
_test "research -> chore prefix" _contains "$CM_OUT3" "^chore:"

CM_ID4=$(task_create "$TEST_DIR" "Update readme" "docs")
CM_OUT4=$(task_commit_msg "$TEST_DIR" "$CM_ID4")
_test "docs -> docs prefix" _contains "$CM_OUT4" "^docs:"

# ── Results ─────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "$PASS/$TOTAL passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL"
  exit 1
fi
