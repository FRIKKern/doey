#!/usr/bin/env bash
# Claude Code hook: UserPromptSubmit — updates pane status
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook

PROMPT=$(parse_field "prompt")
TASK="${PROMPT:0:80}"

STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"

# Maintenance commands: don't change status (except /compact → READY)
case "$PROMPT" in
  /compact*)
    # After compact, context is clean → READY
    TMPFILE_STATUS=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || TMPFILE_STATUS="$STATUS_FILE"
    cat > "$TMPFILE_STATUS" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: READY
TASK:
EOF
    case "$TMPFILE_STATUS" in "$STATUS_FILE") ;; *) mv "$TMPFILE_STATUS" "$STATUS_FILE" ;; esac
    exit 0
    ;;
  /simplify*|/loop*|/rename*|/exit*|/help*|/status*|/doey*)
    # Internal commands — don't change status
    exit 0
    ;;
esac

NEW_STATUS="BUSY"

TMPFILE_STATUS=$(mktemp "${RUNTIME_DIR}/status/.tmp_XXXXXX" 2>/dev/null) || TMPFILE_STATUS="$STATUS_FILE"
cat > "$TMPFILE_STATUS" <<EOF
PANE: $PANE
UPDATED: $NOW
STATUS: $NEW_STATUS
TASK: $TASK
EOF
case "$TMPFILE_STATUS" in "$STATUS_FILE") ;; *) mv "$TMPFILE_STATUS" "$STATUS_FILE" ;; esac

# Expand column if collapsed (human needs to see the pane)
if is_worker; then
  # Quick check: are ANY columns collapsed?
  HAS_COLLAPSED=false
  for _f in "${RUNTIME_DIR}/status"/col_*.collapsed; do
    [ -f "$_f" ] && HAS_COLLAPSED=true && break
  done
  if $HAS_COLLAPSED; then
    COLS=$(grep '^GRID=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2 | cut -dx -f1)
    COLS="${COLS//\"/}"
    # Handle dynamic grid mode
    if [ "$COLS" = "dynamic" ] || [ -z "$COLS" ]; then
      COLS=$(grep '^CURRENT_COLS=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2)
      COLS="${COLS//\"/}"
    fi
    if [ -n "$COLS" ] && [ "$COLS" -gt 0 ]; then
      COL_IDX=$(( PANE_INDEX % COLS ))
      COLLAPSED_FILE="${RUNTIME_DIR}/status/col_${COL_IDX}.collapsed"
      if [ -f "$COLLAPSED_FILE" ]; then
        tmux resize-pane -t "${PANE}" -x 80 2>/dev/null || true
        rm -f "$COLLAPSED_FILE"
      fi
    fi
  fi
fi

exit 0
