#!/usr/bin/env bash
set -uo pipefail
# No -e: tmux callbacks must not crash on transient failures

PANE_REF="${1:-}"
[ -z "$PANE_REF" ] && exit 0

TITLE=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || TITLE=""
FULL_PANE_ID=$(tmux display-message -t "$PANE_REF" -p '#{DOEY_FULL_PANE_ID}' 2>/dev/null) || FULL_PANE_ID=""
# Fallback: try pane environment variable directly
[ -z "$FULL_PANE_ID" ] && FULL_PANE_ID=$(tmux show-environment -t "$PANE_REF" DOEY_FULL_PANE_ID 2>/dev/null | cut -d= -f2-) || true

# Prefix output with FULL_PANE_ID if available
_prefix_id() {
  local label="$1"
  if [ -n "$FULL_PANE_ID" ] && [ -n "$label" ]; then
    echo "${FULL_PANE_ID} | ${label}"
  elif [ -n "$FULL_PANE_ID" ]; then
    echo "$FULL_PANE_ID"
  else
    echo "$label"
  fi
}

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
[ -z "$RUNTIME_DIR" ] && { _prefix_id "$TITLE"; exit 0; }

WIN_PANE="${PANE_REF##*:}"
WINDOW_IDX="${WIN_PANE%%.*}"
PANE_IDX="${WIN_PANE#*.}"
PANE_SAFE="${PANE_REF//[:.]/_}"

env_val() {
  while IFS='=' read -r k v; do
    [ "$k" = "$2" ] && { v="${v#\"}"; echo "${v%\"}"; return; }
  done < "$1"
}

# Window 0: identify Session Manager or Watchdog panes
if [ "$WINDOW_IDX" = "0" ]; then
  SESSION_ENV="${RUNTIME_DIR}/session.env"
  if [ -f "$SESSION_ENV" ]; then
    SM_PANE=$(env_val "$SESSION_ENV" SM_PANE)
    [ -n "$SM_PANE" ] && [ "0.${PANE_IDX}" = "$SM_PANE" ] && { _prefix_id "Session Manager"; exit 0; }
  fi

  for team_file in "${RUNTIME_DIR}"/team_*.env; do
    [ -f "$team_file" ] || continue
    WDG_PANE=$(env_val "$team_file" WATCHDOG_PANE)
    if [ -n "$WDG_PANE" ] && [ "0.${PANE_IDX}" = "$WDG_PANE" ]; then
      _prefix_id "Watchdog Team $(env_val "$team_file" WINDOW_INDEX)"; exit 0
    fi
  done

  _prefix_id "$TITLE"; exit 0
fi

# Worker panes: show lock icon if reserved
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && { _prefix_id "${TITLE} 🔒"; exit 0; }

_prefix_id "$TITLE"
