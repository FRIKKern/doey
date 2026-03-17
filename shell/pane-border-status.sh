#!/usr/bin/env bash
set -uo pipefail
# No -e: tmux callbacks must not crash on transient failures

# Fast pane border label: shows meaningful names for Dashboard panes,
# pane title + 🔒 if reserved for others.
# Called by tmux pane-border-format via #()

PANE_REF="${1:-}"
[ -z "$PANE_REF" ] && exit 0

TITLE=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || TITLE=""

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true

# Extract window index and pane index from PANE_REF (format: "session:W.P")
# Strip everything up to and including the colon to get "W.P"
WIN_PANE="${PANE_REF##*:}"
WINDOW_IDX="${WIN_PANE%%.*}"
PANE_IDX="${WIN_PANE#*.}"

# Dashboard panes (window 0): show role-based labels
if [ "$WINDOW_IDX" = "0" ] && [ -n "$RUNTIME_DIR" ]; then
  SESSION_ENV="${RUNTIME_DIR}/session.env"
  if [ -f "$SESSION_ENV" ]; then
    # Check if this is the Session Manager pane
    SM_PANE=""
    while IFS='=' read -r key val; do
      if [ "$key" = "SM_PANE" ]; then
        # Strip surrounding quotes
        SM_PANE="${val#\"}"
        SM_PANE="${SM_PANE%\"}"
        break
      fi
    done < "$SESSION_ENV"
    if [ -n "$SM_PANE" ] && [ "0.${PANE_IDX}" = "$SM_PANE" ]; then
      echo "Session Manager"
      exit 0
    fi
  fi

  # Check if this pane is a team watchdog
  for team_file in "${RUNTIME_DIR}"/team_*.env; do
    [ -f "$team_file" ] || continue
    TEAM_WIN=""
    WDG_PANE=""
    while IFS='=' read -r key val; do
      case "$key" in
        WINDOW_INDEX)
          TEAM_WIN="${val#\"}"
          TEAM_WIN="${TEAM_WIN%\"}"
          ;;
        WATCHDOG_PANE)
          WDG_PANE="${val#\"}"
          WDG_PANE="${WDG_PANE%\"}"
          ;;
      esac
    done < "$team_file"
    if [ -n "$WDG_PANE" ] && [ "0.${PANE_IDX}" = "$WDG_PANE" ]; then
      echo "Watchdog Team ${TEAM_WIN:-?}"
      exit 0
    fi
  done

  # Fall through to default title for other Dashboard panes (e.g., Info Panel)
  echo "$TITLE"
  exit 0
fi

# Non-Dashboard panes: show title with reserved indicator if applicable
if [ -n "$RUNTIME_DIR" ]; then
  PANE_SAFE="${PANE_REF//[:.]/_}"
  RESERVE_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
  if [ -f "$RESERVE_FILE" ]; then
    echo "${TITLE} 🔒"
    exit 0
  fi
fi

echo "$TITLE"
