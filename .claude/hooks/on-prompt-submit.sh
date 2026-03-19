#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

PROMPT=$(parse_field "prompt")
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

write_status() {
  local status="$1" task="$2" tmp
  tmp=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || tmp="$STATUS_FILE"
  cat > "$tmp" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: $status
TASK: $task
EOF
  case "$tmp" in "$STATUS_FILE") ;; *) mv "$tmp" "$STATUS_FILE" ;; esac
}

case "$PROMPT" in
  /compact*)        write_status "READY" ""; exit 0 ;;
  /simplify*|/loop*|/rename*|/exit*|/help*|/status*|/doey*) exit 0 ;;
esac

write_status "BUSY" "${PROMPT:0:80}"

# Expand collapsed column so worker becomes visible
if is_worker && [ "$PANE_INDEX" -gt 0 ]; then
  collapsed="${RUNTIME_DIR}/status/col_$(( (PANE_INDEX - 1) / 2 )).collapsed"
  if [ -f "$collapsed" ]; then
    tmux resize-pane -t "${PANE}" -x 80 2>/dev/null || true
    rm -f "$collapsed"
  fi
fi

exit 0
