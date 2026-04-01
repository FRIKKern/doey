#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "on-prompt-submit"

PROMPT=$(parse_field "prompt")
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

case "$PROMPT" in
  /compact*)        write_pane_status "$STATUS_FILE" "READY"; notify_sm "READY" "compact"; exit 0 ;;
  /simplify*|/loop*|/rename*|/exit*|/help*|/status*|/doey*) exit 0 ;;
esac

write_pane_status "$STATUS_FILE" "BUSY" "${PROMPT:0:80}"
type _debug_log >/dev/null 2>&1 && _debug_log state "transition" "from=READY" "to=BUSY" "trigger=prompt-submit"
[ -n "${DOEY_PANE_ID:-}" ] && write_pane_status "${RUNTIME_DIR}/status/${DOEY_PANE_ID}.status" "BUSY" "${PROMPT:0:80}"

# Activity logging
_prompt_safe=$(printf '%s' "${PROMPT:0:120}" | tr '"\\' '__')
write_activity "status_change" '{"status":"BUSY"}'
write_activity "task_assigned" "{\"task\":\"${_prompt_safe}\"}"

notify_sm "BUSY" "${PROMPT:0:60}"
_log "task started: $(echo "$PROMPT" | head -c 80)"

if is_session_manager; then
  touch "${RUNTIME_DIR}/status/session_manager_trigger" 2>/dev/null || true
  touch "${RUNTIME_DIR}/triggers/${PANE_SAFE}.trigger" 2>/dev/null || true
fi

if is_worker && [ "$PANE_INDEX" -gt 0 ]; then
  collapsed="${RUNTIME_DIR}/status/col_$(( (PANE_INDEX - 1) / 2 )).collapsed"
  if [ -f "$collapsed" ]; then
    tmux resize-pane -t "${PANE}" -x 80 2>/dev/null || true
    rm -f "$collapsed"
  fi
fi

exit 0
