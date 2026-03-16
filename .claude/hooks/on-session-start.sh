#!/usr/bin/env bash
# SessionStart hook: injects Doey environment variables into every Claude Code session
# via CLAUDE_ENV_FILE so all subsequent Bash tool calls have them.
set -euo pipefail

# Bail silently if not in tmux
[ -z "${TMUX_PANE:-}" ] && exit 0

# Get runtime dir from tmux environment — bail if not set
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

# Bail if no env file to write to
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

# Source session.env for project metadata
SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

# Read variables from session.env (single-pass parse, no eval — /tmp is world-writable)
SESSION_NAME="" PROJECT_DIR="" PROJECT_NAME="" WATCHDOG_PANE=""
while IFS='=' read -r key value; do
  # Strip surrounding quotes (session.env values may be quoted)
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    PROJECT_DIR)  PROJECT_DIR="$value" ;;
    PROJECT_NAME) PROJECT_NAME="$value" ;;
    WATCHDOG_PANE) WATCHDOG_PANE="$value" ;;
  esac
done < "$SESSION_ENV"

# Write environment variables (append, don't overwrite)
cat >> "$CLAUDE_ENV_FILE" << EOF
export DOEY_RUNTIME="$RUNTIME_DIR"
export SESSION_NAME="$SESSION_NAME"
export PROJECT_DIR="$PROJECT_DIR"
export PROJECT_NAME="$PROJECT_NAME"
EOF

# Determine pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
# Extract window index for multi-window support
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

# Determine role based on new architecture:
# - Window 0 (Dashboard): pane 0.0=Info Panel, 0.1-0.3=Watchdog slots, 0.4=Session Manager
# - Window 1+ (Team):     pane W.0=Manager, W.1+=Workers
ROLE="worker"
DOEY_TEAM_WINDOW=""

if [ "$WINDOW_INDEX" = "0" ]; then
  # Dashboard window — check if this pane is a Watchdog slot
  SM_PANE=""
  sm_val=$(grep '^SM_PANE=' "$SESSION_ENV" | cut -d= -f2- || true)
  sm_val="${sm_val%\"}" && sm_val="${sm_val#\"}"
  [ -n "$sm_val" ] && SM_PANE="$sm_val"

  if [ "0.${PANE_INDEX}" = "${SM_PANE:-0.4}" ]; then
    ROLE="session_manager"
  elif [ "$PANE_INDEX" = "0" ]; then
    ROLE="info_panel"
  else
    # Check if this pane is a Watchdog for any team
    for _ss_tf in "${RUNTIME_DIR}"/team_*.env; do
      [ -f "$_ss_tf" ] || continue
      _ss_wd=$(grep '^WATCHDOG_PANE=' "$_ss_tf" | cut -d= -f2-)
      _ss_wd="${_ss_wd%\"}" && _ss_wd="${_ss_wd#\"}"
      if [ "$_ss_wd" = "0.${PANE_INDEX}" ]; then
        ROLE="watchdog"
        # Extract team window index from filename (team_N.env)
        _ss_fn="${_ss_tf##*/}"   # team_N.env
        _ss_fn="${_ss_fn#team_}" # N.env
        DOEY_TEAM_WINDOW="${_ss_fn%.env}"  # N
        break
      fi
    done
  fi
else
  # Team window — pane 0 is Manager, rest are Workers
  TEAM_MGR_PANE=""
  TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  if [ -f "$TEAM_ENV" ]; then
    TEAM_MGR_PANE=$(grep '^MANAGER_PANE=' "$TEAM_ENV" | cut -d= -f2-)
    TEAM_MGR_PANE="${TEAM_MGR_PANE%\"}" && TEAM_MGR_PANE="${TEAM_MGR_PANE#\"}"
  fi
  [ -z "$TEAM_MGR_PANE" ] && TEAM_MGR_PANE="0"

  if [ "$PANE_INDEX" = "$TEAM_MGR_PANE" ]; then
    ROLE="manager"
  else
    ROLE="worker"
  fi
fi

cat >> "$CLAUDE_ENV_FILE" << EOF
export DOEY_ROLE="$ROLE"
export DOEY_PANE_INDEX="$PANE_INDEX"
export DOEY_WINDOW_INDEX="$WINDOW_INDEX"
export DOEY_TEAM_WINDOW="${DOEY_TEAM_WINDOW:-$WINDOW_INDEX}"
EOF
