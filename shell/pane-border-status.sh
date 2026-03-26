#!/usr/bin/env bash
set -uo pipefail
# No -e: tmux callbacks must not crash on transient failures

PANE_REF="${1:-}"
[ -z "$PANE_REF" ] && exit 0

TITLE=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || TITLE=""
FULL_PANE_ID=$(tmux display-message -t "$PANE_REF" -p '#{DOEY_FULL_PANE_ID}' 2>/dev/null) || true
# Fallback: try pane environment variable directly
if [ -z "$FULL_PANE_ID" ]; then
  FULL_PANE_ID=$(tmux show-environment -t "$PANE_REF" DOEY_FULL_PANE_ID 2>/dev/null | cut -d= -f2-) || true
fi

# Prefix output with FULL_PANE_ID if available
_prefix_id() {
  local parts=""
  [ -n "$FULL_PANE_ID" ] && parts="$FULL_PANE_ID"
  [ -n "$1" ] && parts="${parts:+$parts | }$1"
  echo "${parts:-}"
}

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
[ -z "$RUNTIME_DIR" ] && { _prefix_id "$TITLE"; exit 0; }

WIN_PANE="${PANE_REF##*:}"
WINDOW_IDX="${WIN_PANE%%.*}"
PANE_IDX="${WIN_PANE#*.}"
PANE_SAFE="${PANE_REF//[-:.]/_}"

env_val() {
  local v
  v=$(grep "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2-) || true
  v="${v#\"}"; echo "${v%\"}"
}

# Window 0: identify Session Manager or Watchdog panes
if [ "$WINDOW_IDX" = "0" ]; then
  SESSION_ENV="${RUNTIME_DIR}/session.env"
  PROJ_NAME=""
  if [ -f "$SESSION_ENV" ]; then
    PROJ_NAME=$(env_val "$SESSION_ENV" PROJECT_NAME)
    SM_PANE=$(env_val "$SESSION_ENV" SM_PANE)
    [ -n "$SM_PANE" ] && [ "0.${PANE_IDX}" = "$SM_PANE" ] && { _prefix_id "${PROJ_NAME} SM"; exit 0; }
  fi

  for team_file in "${RUNTIME_DIR}"/team_*.env; do
    [ -f "$team_file" ] || continue
    WDG_PANE=$(env_val "$team_file" WATCHDOG_PANE)
    if [ -n "$WDG_PANE" ] && [ "0.${PANE_IDX}" = "$WDG_PANE" ]; then
      _prefix_id "${PROJ_NAME} T$(env_val "$team_file" WINDOW_INDEX) WD"; exit 0
    fi
  done

  _prefix_id "$TITLE"; exit 0
fi

# Worker panes: show lock icon if reserved
[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && { _prefix_id "${TITLE} 🔒"; exit 0; }

_prefix_id "$TITLE"
