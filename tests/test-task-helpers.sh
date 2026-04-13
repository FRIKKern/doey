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
_test "TASK_SCHEMA_VERSION=4 in .task" grep -q "TASK_SCHEMA_VERSION=4" "${TEST_DIR}/.doey/tasks/${ID}.task"
_test "TASK_CONSTRAINTS present (v4)" grep -q "^TASK_CONSTRAINTS=" "${TEST_DIR}/.doey/tasks/${ID}.task"
_test "TASK_RUNNING_SUMMARY present (v4)" grep -q "^TASK_RUNNING_SUMMARY=" "${TEST_DIR}/.doey/tasks/${ID}.task"
_test_fails "no inline TASK_SUBTASKS in fresh v4 task" grep -q "^TASK_SUBTASKS=" "${TEST_DIR}/.doey/tasks/${ID}.task"

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

READ_ID=$(task_create "$TEST_DIR" "Read me" "bug" "Taskmaster" "Desc here")
task_read "${TEST_DIR}/.doey/tasks/${READ_ID}.task"

_test "TASK_ID set" test "$TASK_ID" = "$READ_ID"
_test "TASK_TITLE set" test "$TASK_TITLE" = "Read me"
_test "TASK_STATUS set" test "$TASK_STATUS" = "active"
_test "TASK_TYPE set" test "$TASK_TYPE" = "bug"
_test "TASK_SCHEMA_VERSION set" test "$TASK_SCHEMA_VERSION" = "4"

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

_test "upgraded to TASK_SCHEMA_VERSION=4" grep -q "TASK_SCHEMA_VERSION=4" "$V1_UPG"
_test ".json companion created" test -f "${TEST_DIR}/.doey/tasks/88.json"

# Idempotent — call again
task_upgrade_schema "$V1_UPG"
_test "idempotent upgrade (no error)" test $? -eq 0

# ── 8b. task_upgrade_schema v3→v4: drop inline when expanded present ─
echo ""
echo "=== Test: task_upgrade_schema v3→v4 (double-encoding collapse) ==="

V3_BOTH="${TEST_DIR}/.doey/tasks/8801.task"
cat > "$V3_BOTH" <<'EOF'
TASK_SCHEMA_VERSION=3
TASK_ID=8801
TASK_TITLE=Both forms
TASK_STATUS=active
TASK_TYPE=feature
TASK_CREATED_BY=Boss
TASK_DESCRIPTION=
TASK_TIMESTAMPS=created=1776000000
TASK_SUBTASKS=1:Old inline:done\n2:Another:pending
TASK_UPDATED=1776000000
TASK_SUBTASK_1_TITLE=Canonical first
TASK_SUBTASK_1_STATUS=done
TASK_SUBTASK_1_WORKER=doey_doey_4_1
TASK_SUBTASK_2_TITLE=Canonical second
TASK_SUBTASK_2_STATUS=pending
EOF

task_upgrade_schema "$V3_BOTH"

_test "v4 version bumped" grep -q "^TASK_SCHEMA_VERSION=4" "$V3_BOTH"
_test_fails "inline TASK_SUBTASKS dropped when expanded present" grep -q "^TASK_SUBTASKS=1:Old inline" "$V3_BOTH"
_test "expanded TASK_SUBTASK_1_TITLE preserved" grep -q "^TASK_SUBTASK_1_TITLE=Canonical first" "$V3_BOTH"
_test "expanded TASK_SUBTASK_2_TITLE preserved" grep -q "^TASK_SUBTASK_2_TITLE=Canonical second" "$V3_BOTH"
_test "TASK_CONSTRAINTS added" grep -q "^TASK_CONSTRAINTS=" "$V3_BOTH"
_test "TASK_RUNNING_SUMMARY added" grep -q "^TASK_RUNNING_SUMMARY=" "$V3_BOTH"

# ── 8c. task_upgrade_schema v3→v4: expand inline when no expanded ────
echo ""
echo "=== Test: task_upgrade_schema v3→v4 (inline → expanded) ==="

V3_INLINE="${TEST_DIR}/.doey/tasks/8802.task"
cat > "$V3_INLINE" <<'EOF'
TASK_SCHEMA_VERSION=3
TASK_ID=8802
TASK_TITLE=Inline only
TASK_STATUS=active
TASK_TYPE=feature
TASK_CREATED_BY=Boss
TASK_DESCRIPTION=
TASK_TIMESTAMPS=created=1776000000
TASK_SUBTASKS=1:First:done\n2:Second:pending
TASK_UPDATED=1776000000
EOF

task_upgrade_schema "$V3_INLINE"

_test "v4 version bumped (inline→expanded)" grep -q "^TASK_SCHEMA_VERSION=4" "$V3_INLINE"
_test_fails "inline TASK_SUBTASKS dropped after expansion" grep -q "^TASK_SUBTASKS=1:First" "$V3_INLINE"
_test "subtask 1 expanded" grep -q "^TASK_SUBTASK_1_TITLE=First" "$V3_INLINE"
_test "subtask 1 status expanded" grep -q "^TASK_SUBTASK_1_STATUS=done" "$V3_INLINE"
_test "subtask 2 expanded" grep -q "^TASK_SUBTASK_2_TITLE=Second" "$V3_INLINE"

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
_test "feature -> feat prefix" _contains "$CM_OUT" "^feat(task-"
_test "contains title" _contains "$CM_OUT" "add search feature"
_test "contains task scope" _contains "$CM_OUT" "(task-${CM_ID}):"

CM_ID2=$(task_create "$TEST_DIR" "Fix login crash" "bugfix")
CM_OUT2=$(task_commit_msg "$TEST_DIR" "$CM_ID2")
_test "bugfix -> fix prefix" _contains "$CM_OUT2" "^fix(task-"

CM_ID3=$(task_create "$TEST_DIR" "Research caching" "research")
CM_OUT3=$(task_commit_msg "$TEST_DIR" "$CM_ID3")
_test "research -> docs prefix" _contains "$CM_OUT3" "^docs(task-"

CM_ID4=$(task_create "$TEST_DIR" "Update readme" "docs")
CM_OUT4=$(task_commit_msg "$TEST_DIR" "$CM_ID4")
_test "docs -> docs prefix" _contains "$CM_OUT4" "^docs(task-"

# ── 14. task_context_overlap ────────────────────────────────────────
echo ""
echo "=== Test: task_context_overlap ==="

# Full overlap: same tags, same type, same file dirs
SCORE1=$(task_context_overlap "hooks,shell,testing" "bugfix" "shell/doey.sh|tests/test.sh" \
                              "hooks,shell,testing" "bugfix" "shell/other.sh|tests/foo.sh")
_test "full overlap -> 100" test "$SCORE1" -eq 100

# No overlap: different tags, different type, different dirs
SCORE2=$(task_context_overlap "hooks,shell" "bugfix" "shell/doey.sh" \
                              "tui,config" "feature" "tui/main.go")
_test "no overlap -> 0" test "$SCORE2" -eq 0

# Type match only: different tags, same type, different dirs
SCORE3=$(task_context_overlap "hooks,shell" "feature" "shell/doey.sh" \
                              "tui,config" "feature" "tui/main.go")
_test "type match only -> 20" test "$SCORE3" -eq 20

# Tag overlap only: 1 of 2 tags match, different type, different dirs
SCORE4=$(task_context_overlap "hooks,shell" "bugfix" "shell/doey.sh" \
                              "shell,tui" "feature" "tui/main.go")
_test "partial tag overlap -> 20" test "$SCORE4" -eq 20

# File overlap only: different tags, different type, same dirs
SCORE5=$(task_context_overlap "hooks" "bugfix" "shell/doey.sh|shell/utils.sh" \
                              "tui" "feature" "shell/other.sh")
_test "file dir overlap -> score > 0" test "$SCORE5" -gt 0

# Empty inputs: all empty
SCORE6=$(task_context_overlap "" "" "" "" "" "")
_test "all empty -> 0" test "$SCORE6" -eq 0

# One side empty
SCORE7=$(task_context_overlap "hooks,shell" "bugfix" "shell/doey.sh" "" "" "")
_test "new side empty -> 0" test "$SCORE7" -eq 0

# Single tag full match
SCORE8=$(task_context_overlap "shell" "bugfix" "" "shell" "bugfix" "")
_test "single tag + type match -> 60" test "$SCORE8" -eq 60

# ── 15. task_should_restart ────────────────────────────────────────
echo ""
echo "=== Test: task_should_restart ==="

# High overlap (100) -> should NOT restart (delegate) -> exit 1
_test_fails "high overlap -> should delegate (exit 1)" \
  task_should_restart "hooks,shell,testing" "bugfix" "shell/a.sh|tests/b.sh" \
                      "hooks,shell,testing" "bugfix" "shell/c.sh|tests/d.sh"

# No overlap (0) -> should restart -> exit 0
_test "no overlap -> should restart (exit 0)" \
  task_should_restart "hooks,shell" "bugfix" "shell/doey.sh" \
                      "tui,config" "feature" "tui/main.go"

# Borderline: exactly 20 (type match only) -> below 30 -> restart
_test "score 20 -> should restart (exit 0)" \
  task_should_restart "hooks" "feature" "shell/doey.sh" \
                      "tui" "feature" "tui/main.go"

# Score 60 (tag + type) -> above 30 -> delegate
_test_fails "score 60 -> should delegate (exit 1)" \
  task_should_restart "shell" "bugfix" "" "shell" "bugfix" ""

# All empty -> 0 -> restart
_test "all empty -> should restart (exit 0)" \
  task_should_restart "" "" "" "" "" ""

# ── 16. task_add_subtask ───────────────────────────────────────────
echo ""
echo "=== Test: task_add_subtask ==="

rm -rf "${TEST_DIR}/.doey/tasks"
mkdir -p "${TEST_DIR}/.doey/tasks"

SUB_ID=$(task_create "$TEST_DIR" "Subtask host")
SUB_FILE="${TEST_DIR}/.doey/tasks/${SUB_ID}.task"

S1=$(task_add_subtask "$SUB_FILE" "First subtask")
_test "add_subtask returns 1" test "$S1" = "1"
_test "subtask 1 stored as TASK_SUBTASK_1_TITLE" grep -q "^TASK_SUBTASK_1_TITLE=First subtask$" "$SUB_FILE"
_test "subtask 1 initial status pending" grep -q "^TASK_SUBTASK_1_STATUS=pending$" "$SUB_FILE"

S2=$(task_add_subtask "$SUB_FILE" "Second subtask")
_test "add_subtask returns 2" test "$S2" = "2"
_test "subtask 2 appended (expanded)" grep -q "^TASK_SUBTASK_2_TITLE=Second subtask$" "$SUB_FILE"

# Verify subtask count
SUB_COUNT=$(grep -c '^TASK_SUBTASK_[0-9][0-9]*_TITLE=' "$SUB_FILE")
_test "subtask count is 2" test "$SUB_COUNT" -eq 2

_test_fails "canonical v4 form — no inline TASK_SUBTASKS" grep -q "^TASK_SUBTASKS=" "$SUB_FILE"

# ── 17. task_update_subtask ────────────────────────────────────────
echo ""
echo "=== Test: task_update_subtask ==="

task_update_subtask "$SUB_FILE" 1 in_progress
_test "subtask 1 status -> in_progress" grep -q "^TASK_SUBTASK_1_STATUS=in_progress$" "$SUB_FILE"

task_update_subtask "$SUB_FILE" 1 done
_test "subtask 1 status -> done" grep -q "^TASK_SUBTASK_1_STATUS=done$" "$SUB_FILE"

_test "subtask 2 still pending" grep -q "^TASK_SUBTASK_2_STATUS=pending$" "$SUB_FILE"

_test_fails "invalid subtask status rejected" task_update_subtask "$SUB_FILE" 1 "bogus"

_test_fails "non-existent subtask rejected" task_update_subtask "$SUB_FILE" 99 "done"

# ── 18. task_add_decision (activity updates) ───────────────────────
echo ""
echo "=== Test: task_add_decision ==="

task_add_decision "$SUB_FILE" "Starting implementation"
_test "decision 1 stored" grep -q "Starting implementation" "$SUB_FILE"

task_add_decision "$SUB_FILE" "Files changed: foo.go"
_test "decision 2 appended" grep -q "Files changed: foo.go" "$SUB_FILE"

# Verify TASK_DECISION_LOG has timestamp prefix (epoch:text format)
DL_RAW=$(grep "^TASK_DECISION_LOG=" "$SUB_FILE" | head -1)
DL_VAL="${DL_RAW#TASK_DECISION_LOG=}"
_test "decision log has timestamp prefix" _contains "$DL_VAL" "^[0-9].*:"

# ── 19. task_add_note ──────────────────────────────────────────────
echo ""
echo "=== Test: task_add_note ==="

task_add_note "$SUB_FILE" "First note"
_test "note 1 stored" grep -q "First note" "$SUB_FILE"

task_add_note "$SUB_FILE" "Second note"
_test "note 2 appended" grep -q "Second note" "$SUB_FILE"

# ── 20. original fields intact after mutations ─────────────────────
echo ""
echo "=== Test: original fields intact ==="

_test "TASK_ID still intact" grep -q "TASK_ID=${SUB_ID}" "$SUB_FILE"
_test "TASK_TITLE still intact" grep -q "TASK_TITLE=Subtask host" "$SUB_FILE"
_test "TASK_STATUS still intact" grep -q "TASK_STATUS=active" "$SUB_FILE"
_test "TASK_SCHEMA_VERSION still intact" grep -q "TASK_SCHEMA_VERSION=4" "$SUB_FILE"

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
