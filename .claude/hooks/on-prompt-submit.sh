#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

PROMPT=$(parse_field "prompt")
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

case "$PROMPT" in
  /compact*)        write_pane_status "$STATUS_FILE" "READY"; exit 0 ;;
  /simplify*|/loop*|/rename*|/exit*|/help*|/status*|/doey*) exit 0 ;;
esac

write_pane_status "$STATUS_FILE" "BUSY" "${PROMPT:0:80}"
[ -n "${DOEY_PANE_ID:-}" ] && write_pane_status "${RUNTIME_DIR}/status/${DOEY_PANE_ID}.status" "BUSY" "${PROMPT:0:80}"
_log "task started: $(echo "$PROMPT" | head -c 80)"

# Expand collapsed column so worker becomes visible
if is_worker && [ "$PANE_INDEX" -gt 0 ]; then
  collapsed="${RUNTIME_DIR}/status/col_$(( (PANE_INDEX - 1) / 2 )).collapsed"
  if [ -f "$collapsed" ]; then
    tmux resize-pane -t "${PANE}" -x 80 2>/dev/null || true
    rm -f "$collapsed"
  fi
fi

exit 0
