#!/usr/bin/env bash
# PostToolUse: auto-complete tasks after successful git push
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "post-push-complete"

[ "${DOEY_ROLE:-}" = "$DOEY_ROLE_ID_COORDINATOR" ] || exit 0

case "$(_parse_tool_field tool_name)" in Bash) ;; *) exit 0 ;; esac

COMMAND=$(_parse_tool_field tool_input.command)
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

EXIT_CODE=$(_parse_tool_field tool_result.exit_code)
[ "$EXIT_CODE" = "0" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJECT_DIR" ] || exit 0
TASKS_DIR="${PROJECT_DIR}/.doey/tasks"
[ -d "$TASKS_DIR" ] || exit 0

RECENT_COMMITS=$(cd "$PROJECT_DIR" && git log --oneline -20 2>/dev/null) || exit 0
[ -n "$RECENT_COMMITS" ] || exit 0

TASK_IDS=$(echo "$RECENT_COMMITS" | grep -oE 'task-[0-9]+' | grep -oE '[0-9]+' | sort -u) || true
[ -n "$TASK_IDS" ] || exit 0

HELPERS_FILE="$(cd "$(dirname "$0")/../.." && pwd)/shell/doey-task-helpers.sh"
[ -f "$HELPERS_FILE" ] || HELPERS_FILE="${HOME}/.local/share/doey/shell/doey-task-helpers.sh"
[ -f "$HELPERS_FILE" ] || { _log "SKIP: doey-task-helpers.sh not found"; exit 0; }
source "$HELPERS_FILE"

COMPLETED_COUNT=0

while IFS= read -r task_id; do
  [ -n "$task_id" ] || continue
  TASK_FILE="${TASKS_DIR}/${task_id}.task"
  [ -f "$TASK_FILE" ] || continue

  CURRENT_STATUS=$(grep '^TASK_STATUS=' "$TASK_FILE" | head -1 | cut -d= -f2-) || continue
  CURRENT_STATUS="${CURRENT_STATUS%\"}"; CURRENT_STATUS="${CURRENT_STATUS#\"}"
  case "$CURRENT_STATUS" in
    active|in_progress|pending_user_confirmation) ;;
    *) continue ;;
  esac

  SHORT_HASH=$(echo "$RECENT_COMMITS" | grep -m1 "task-${task_id}" | cut -d' ' -f1) || SHORT_HASH="unknown"
  if task_update_status "$PROJECT_DIR" "$task_id" "done" 2>/dev/null; then
    printf 'TASK_LOG_%s=AUTO_COMPLETE: Marked done after push (commit %s)\n' \
      "$(date +%s)" "$SHORT_HASH" >> "$TASK_FILE" 2>/dev/null || true
    COMPLETED_COUNT=$((COMPLETED_COUNT + 1))
    _log "COMPLETED task-${task_id} (was ${CURRENT_STATUS}, commit ${SHORT_HASH})"
  else
    _log "FAILED to complete task-${task_id}: task_update_status returned error"
  fi
done <<TASK_EOF
$TASK_IDS
TASK_EOF

[ "$COMPLETED_COUNT" -gt 0 ] && _log "Auto-completed ${COMPLETED_COUNT} task(s) after push"
exit 0
