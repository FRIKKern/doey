#!/usr/bin/env bash
# Claude Code hook: UserPromptSubmit — updates pane status
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

PROMPT=$(parse_field "prompt")
STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# Write status atomically (mktemp → mv)
write_status() {
  local status="$1" task="$2"
  local tmp
  tmp=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || tmp="$STATUS_FILE"
  cat > "$tmp" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: $status
TASK: $task
EOF
  case "$tmp" in "$STATUS_FILE") ;; *) mv "$tmp" "$STATUS_FILE" ;; esac
}

# Handle maintenance commands
case "$PROMPT" in
  /compact*)        write_status "READY" ""; exit 0 ;;
  /simplify*|/loop*|/rename*|/exit*|/help*|/status*|/doey*) exit 0 ;;
esac

write_status "BUSY" "${PROMPT:0:80}"

# Expand column if collapsed (worker needs to be visible)
if is_worker && [ "$PANE_INDEX" -gt 0 ]; then
  COL_IDX=$(( (PANE_INDEX - 1) / 2 ))
  COLLAPSED_FILE="${RUNTIME_DIR}/status/col_${COL_IDX}.collapsed"
  if [ -f "$COLLAPSED_FILE" ]; then
    tmux resize-pane -t "${PANE}" -x 80 2>/dev/null || true
    rm -f "$COLLAPSED_FILE"
  fi
fi

exit 0
