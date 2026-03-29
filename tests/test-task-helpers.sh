#!/usr/bin/env bash
# Test: doey-task-helpers.sh — task_create, task_list, task_read, task_update_status, task_upgrade_schema, task_dispatch_msg
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

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "${TEST_DIR}/tasks"

# Helper: write string to temp file for grepping
_tmp="${TEST_DIR}/_test_output"

# ── 1. task_create ──────────────────────────────────────────────────
echo "=== Test: task_create ==="

ID=$(task_create "$TEST_DIR" "Build login page" "feature" "Boss" "P1" "Login page" "Full login flow")

_test "task_create returns an ID" test -n "$ID"
_test ".task file exists" test -f "${TEST_DIR}/tasks/${ID}.task"
_test ".json file exists" test -f "${TEST_DIR}/tasks/${ID}.json"
_test "TASK_ID is set in .task" grep -q "TASK_ID=${ID}" "${TEST_DIR}/tasks/${ID}.task"
_test "TASK_SCHEMA_VERSION=2 in .task" grep -q "TASK_SCHEMA_VERSION=2" "${TEST_DIR}/tasks/${ID}.task"
_test ".json contains schema_version 2" grep -q '"schema_version": 2' "${TEST_DIR}/tasks/${ID}.json"

# ── 2. task_create defaults ─────────────────────────────────────────
echo ""
echo "=== Test: task_create defaults ==="

rm -rf "${TEST_DIR}/tasks"
mkdir -p "${TEST_DIR}/tasks"

ID2=$(task_create "$TEST_DIR" "Minimal task")
task_read "${TEST_DIR}/tasks/${ID2}.task"

_test "default type is feature" test "$TASK_TYPE" = "feature"
_test "default owner is Boss" test "$TASK_OWNER" = "Boss"
_test "default priority is P2" test "$TASK_PRIORITY" = "P2"

# ── 3. task_list ────────────────────────────────────────────────────
echo ""
echo "=== Test: task_list ==="

rm -rf "${TEST_DIR}/tasks"
mkdir -p "${TEST_DIR}/tasks"

task_create "$TEST_DIR" "Alpha task" "feature" "Boss" "P0" >/dev/null
task_create "$TEST_DIR" "Beta task" "bug" "Boss" "P1" >/dev/null
task_create "$TEST_DIR" "Gamma task" "feature" "Boss" "P3" >/dev/null

task_list "$TEST_DIR" > "$_tmp"

_test "task_list output is non-empty" test -s "$_tmp"
_test "output contains Alpha task" grep -q "Alpha task" "$_tmp"
_test "output contains Beta task" grep -q "Beta task" "$_tmp"
_test "output contains Gamma task" grep -q "Gamma task" "$_tmp"

# ── 4. task_list --all ──────────────────────────────────────────────
echo ""
echo "=== Test: task_list --all ==="

rm -rf "${TEST_DIR}/tasks"
mkdir -p "${TEST_DIR}/tasks"

DONE_ID=$(task_create "$TEST_DIR" "Finished work")
task_update_status "$TEST_DIR" "$DONE_ID" "done"

task_list "$TEST_DIR" > "$_tmp"
_test_fails "task_list hides done tasks" grep -q "Finished work" "$_tmp"

task_list "$TEST_DIR" --all > "$_tmp"
_test "task_list --all shows done tasks" grep -q "Finished work" "$_tmp"

# ── 5. task_read ────────────────────────────────────────────────────
echo ""
echo "=== Test: task_read ==="

rm -rf "${TEST_DIR}/tasks"
mkdir -p "${TEST_DIR}/tasks"

READ_ID=$(task_create "$TEST_DIR" "Read me" "bug" "SM" "P0" "Summary here" "Desc here")
task_read "${TEST_DIR}/tasks/${READ_ID}.task"

_test "TASK_ID set" test "$TASK_ID" = "$READ_ID"
_test "TASK_TITLE set" test "$TASK_TITLE" = "Read me"
_test "TASK_STATUS set" test "$TASK_STATUS" = "active"
_test "TASK_TYPE set" test "$TASK_TYPE" = "bug"
_test "TASK_SCHEMA_VERSION set" test "$TASK_SCHEMA_VERSION" = "2"

# ── 6. task_read legacy v1 ──────────────────────────────────────────
echo ""
echo "=== Test: task_read legacy v1 ==="

V1_FILE="${TEST_DIR}/tasks/99.task"
printf 'TASK_ID=99\nTASK_TITLE=Legacy task\nTASK_STATUS=active\nTASK_CREATED=1700000000\n' > "$V1_FILE"

task_read "$V1_FILE"

_test "v1 TASK_SCHEMA_VERSION defaults to 1" test "$TASK_SCHEMA_VERSION" = "1"
_test "v1 TASK_TYPE defaults to feature" test "$TASK_TYPE" = "feature"
_test "v1 TASK_PRIORITY defaults to P2" test "$TASK_PRIORITY" = "P2"

# ── 7. task_update_status ───────────────────────────────────────────
echo ""
echo "=== Test: task_update_status ==="

rm -rf "${TEST_DIR}/tasks"
mkdir -p "${TEST_DIR}/tasks"

UPD_ID=$(task_create "$TEST_DIR" "Status test")
task_update_status "$TEST_DIR" "$UPD_ID" "in_progress"

_test "status updated to in_progress" grep -q "TASK_STATUS=in_progress" "${TEST_DIR}/tasks/${UPD_ID}.task"

_test_fails "invalid status returns 1" task_update_status "$TEST_DIR" "$UPD_ID" "bogus"

# ── 8. task_upgrade_schema ──────────────────────────────────────────
echo ""
echo "=== Test: task_upgrade_schema ==="

V1_UPG="${TEST_DIR}/tasks/88.task"
printf 'TASK_ID=88\nTASK_TITLE=Upgrade me\nTASK_STATUS=active\nTASK_CREATED=1700000000\n' > "$V1_UPG"

task_upgrade_schema "$V1_UPG"

_test "upgraded to TASK_SCHEMA_VERSION=2" grep -q "TASK_SCHEMA_VERSION=2" "$V1_UPG"
_test ".json companion created" test -f "${TEST_DIR}/tasks/88.json"

# Idempotent — call again
task_upgrade_schema "$V1_UPG"
_test "idempotent upgrade (no error)" test $? -eq 0

# ── 9. task_dispatch_msg ────────────────────────────────────────────
echo ""
echo "=== Test: task_dispatch_msg ==="

rm -rf "${TEST_DIR}/tasks"
mkdir -p "${TEST_DIR}/tasks"

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

rm -rf "${TEST_DIR}/tasks"
mkdir -p "${TEST_DIR}/tasks"

CID1=$(task_create "$TEST_DIR" "First")
CID2=$(task_create "$TEST_DIR" "Second")
CID3=$(task_create "$TEST_DIR" "Third")

_test "first ID is 1" test "$CID1" = "1"
_test "second ID is 2" test "$CID2" = "2"
_test "third ID is 3" test "$CID3" = "3"
_test ".next_id contains 4" test "$(cat "${TEST_DIR}/tasks/.next_id")" = "4"

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
