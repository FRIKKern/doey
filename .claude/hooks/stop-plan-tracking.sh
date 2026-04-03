#!/usr/bin/env bash
# Stop hook: check off plan checkboxes when a worker finishes a task (async)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "stop-plan-tracking"

is_worker || exit 0

task_id="${DOEY_TASK_ID:-}"
[ -n "$task_id" ] || exit 0

PROJECT_DIR=$(_resolve_project_dir)
[ -n "$PROJECT_DIR" ] || exit 0

# Source plan helpers
PLAN_HELPERS="${PROJECT_DIR}/shell/doey-plan-helpers.sh"
[ -f "$PLAN_HELPERS" ] || exit 0
source "$PLAN_HELPERS"

# Get task title — DB fast path, file fallback
task_title=""
if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
  task_title=$(doey-ctl task get --id "$task_id" --project-dir "$PROJECT_DIR" 2>/dev/null | sed -n 's/^Title:[[:space:]]*//p')
fi
if [ -z "$task_title" ]; then
  task_file="${PROJECT_DIR}/.doey/tasks/${task_id}.task"
  [ -f "$task_file" ] && task_title=$(grep '^TASK_TITLE=' "$task_file" 2>/dev/null | head -1 | cut -d= -f2-) || task_title=""
fi
[ -n "$task_title" ] || exit 0

# Find plan linked to this task
plan_file=""
plan_file=$(plan_find_by_task_id "$PROJECT_DIR" "$task_id") || exit 0
[ -n "$plan_file" ] || exit 0

# Check off the matching checkbox
if plan_check_checkbox "$plan_file" "$task_id" "$task_title"; then
  _log "stop-plan-tracking: checked checkbox for task ${task_id} in ${plan_file}"
  write_activity "plan_checkbox_checked" "{\"task_id\":\"${task_id}\",\"plan_file\":\"${plan_file}\"}"
fi

exit 0
