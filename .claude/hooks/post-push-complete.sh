#!/usr/bin/env bash
# PostToolUse: auto-complete tasks after successful git push
set -euo pipefail

INPUT=$(cat)

# Source common utilities, init hook
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${HOOK_DIR}/common.sh"
init_hook

_DOEY_HOOK_NAME="post-push-complete"
_debug_hook_entry

# Only Session Manager can push
[ "${DOEY_ROLE:-}" = "session_manager" ] || exit 0

# --- JSON parsing (jq preferred, grep fallback) ---
_HAS_JQ=false; command -v jq >/dev/null 2>&1 && _HAS_JQ=true

_parse() {
  if "$_HAS_JQ"; then
    echo "$INPUT" | jq -r ".$1 // empty" 2>/dev/null || echo ""
  else
    echo "$INPUT" | grep -o "\"${1##*.}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"${1##*.}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" 2>/dev/null || echo ""
  fi
}

_parse_num() {
  if "$_HAS_JQ"; then
    echo "$INPUT" | jq -r ".$1 // empty" 2>/dev/null || echo ""
  else
    echo "$INPUT" | grep -o "\"${1##*.}\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | sed "s/.*:[[:space:]]*//" 2>/dev/null || echo ""
  fi
}

# Must be a Bash tool call
case "$(_parse tool_name)" in Bash) ;; *) exit 0 ;; esac

# Extract command from tool_input
COMMAND=$(_parse tool_input.command)
[ -n "$COMMAND" ] || exit 0

# Must contain "git" and "push" as a subcommand (not just in a string/message)
# Match: git push, git -c ... push, git push origin main, etc.
# Reject: git log with "push" in commit message, git commit -m "push fix"
case "$COMMAND" in
  git\ push*|git\ -[a-zA-Z]\ *push*|git\ --*\ push*)
    ;; # valid git push pattern
  *)
    exit 0
    ;;
esac

# Check for success: exit_code should be 0
EXIT_CODE=$(_parse_num tool_result.exit_code)
[ "$EXIT_CODE" = "0" ] || exit 0

# --- Successful push detected — find and complete tasks ---

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJECT_DIR" ] || exit 0

TASKS_DIR="${PROJECT_DIR}/.doey/tasks"
[ -d "$TASKS_DIR" ] || exit 0

LOG_FILE="${RUNTIME_DIR}/errors/errors.log"

_log_push() {
  printf '[%s] POST_PUSH_COMPLETE | %s | %s | %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "${DOEY_PANE_ID:-unknown}" "${DOEY_ROLE:-unknown}" "$1" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# Get recent commit subjects to find task IDs
RECENT_COMMITS=$(cd "$PROJECT_DIR" && git log --oneline -20 2>/dev/null) || exit 0
[ -n "$RECENT_COMMITS" ] || exit 0

# Extract unique task IDs from commit subjects (pattern: task-<number>)
TASK_IDS=$(echo "$RECENT_COMMITS" | grep -oE 'task-[0-9]+' | grep -oE '[0-9]+' | sort -u) || true
[ -n "$TASK_IDS" ] || exit 0

# Source task helpers for task_update_status
HELPERS_FILE="${HOOK_DIR}/../../shell/doey-task-helpers.sh"
if [ ! -f "$HELPERS_FILE" ]; then
  # Try installed location
  HELPERS_FILE="${HOME}/.local/share/doey/shell/doey-task-helpers.sh"
fi
if [ ! -f "$HELPERS_FILE" ]; then
  _log_push "SKIP: doey-task-helpers.sh not found"
  exit 0
fi
source "$HELPERS_FILE"

COMPLETED_COUNT=0

while IFS= read -r task_id; do
  [ -n "$task_id" ] || continue

  TASK_FILE="${TASKS_DIR}/${task_id}.task"
  [ -f "$TASK_FILE" ] || continue

  # Read current status
  CURRENT_STATUS=$(grep '^TASK_STATUS=' "$TASK_FILE" | head -1 | cut -d= -f2-) || continue
  CURRENT_STATUS="${CURRENT_STATUS%\"}"
  CURRENT_STATUS="${CURRENT_STATUS#\"}"

  # Skip if already done or cancelled
  case "$CURRENT_STATUS" in
    done|cancelled) continue ;;
    active|in_progress|pending_user_confirmation) ;; # process these
    *) continue ;; # skip unknown statuses
  esac

  # Find the commit hash for this task
  SHORT_HASH=$(echo "$RECENT_COMMITS" | grep -m1 "task-${task_id}" | cut -d' ' -f1) || SHORT_HASH="unknown"

  # Update task status to done
  if task_update_status "$PROJECT_DIR" "$task_id" "done" 2>/dev/null; then
    # Append auto-complete log entry
    local_epoch=$(date +%s)
    printf 'TASK_LOG_%s=AUTO_COMPLETE: Marked done after push (commit %s)\n' \
      "$local_epoch" "$SHORT_HASH" >> "$TASK_FILE" 2>/dev/null || true

    COMPLETED_COUNT=$((COMPLETED_COUNT + 1))
    _log_push "COMPLETED task-${task_id} (was ${CURRENT_STATUS}, commit ${SHORT_HASH})"
  else
    _log_push "FAILED to complete task-${task_id}: task_update_status returned error"
  fi
done <<TASK_EOF
$TASK_IDS
TASK_EOF

if [ "$COMPLETED_COUNT" -gt 0 ]; then
  _log_push "Auto-completed ${COMPLETED_COUNT} task(s) after push"
fi

# PostToolUse hooks must always exit 0
exit 0
