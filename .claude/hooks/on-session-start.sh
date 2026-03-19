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
SESSION_NAME="" PROJECT_DIR="" PROJECT_NAME=""
while IFS='=' read -r key value; do
  # Strip surrounding quotes (session.env values may be quoted)
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    PROJECT_DIR)  PROJECT_DIR="$value" ;;
    PROJECT_NAME) PROJECT_NAME="$value" ;;
  esac
done < "$SESSION_ENV"

# Determine pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

# Determine role:
#   Window 0 (Dashboard): 0.0=Info Panel, 0.1=Session Manager, 0.2-0.7=Watchdog slots
#   Window 1+ (Team):     W.0=Manager, W.1+=Workers
ROLE="worker"
TEAM_WINDOW="$WINDOW_INDEX"

if [ "$WINDOW_INDEX" = "0" ]; then
  sm_val=$(grep '^SM_PANE=' "$SESSION_ENV" | cut -d= -f2- || true)
  sm_val="${sm_val%\"}" && sm_val="${sm_val#\"}"

  if [ "0.${PANE_INDEX}" = "${sm_val:-0.1}" ]; then
    ROLE="session_manager"
  elif [ "$PANE_INDEX" = "0" ]; then
    ROLE="info_panel"
  else
    for tf in "${RUNTIME_DIR}"/team_*.env; do
      [ -f "$tf" ] || continue
      wd_pane=$(grep '^WATCHDOG_PANE=' "$tf" | cut -d= -f2-)
      wd_pane="${wd_pane%\"}" && wd_pane="${wd_pane#\"}"
      if [ "$wd_pane" = "0.${PANE_INDEX}" ]; then
        ROLE="watchdog"
        fn="${tf##*/}"            # team_N.env
        TEAM_WINDOW="${fn#team_}" # N.env
        TEAM_WINDOW="${TEAM_WINDOW%.env}"
        break
      fi
    done
  fi
else
  mgr_pane="0"
  team_env="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  if [ -f "$team_env" ]; then
    mgr_val=$(grep '^MANAGER_PANE=' "$team_env" | cut -d= -f2-)
    mgr_val="${mgr_val%\"}" && mgr_val="${mgr_val#\"}"
    [ -n "$mgr_val" ] && mgr_pane="$mgr_val"
  fi
  [ "$PANE_INDEX" = "$mgr_pane" ] && ROLE="manager"
fi

# Worktree-aware team directory
wt_dir=""
wt_env="${RUNTIME_DIR}/team_${TEAM_WINDOW}.env"
if [ -f "$wt_env" ]; then
  wt_dir=$(grep '^WORKTREE_DIR=' "$wt_env" 2>/dev/null | head -1 | cut -d= -f2-)
  wt_dir="${wt_dir%\"}" && wt_dir="${wt_dir#\"}"
fi

# Write all environment variables (single append)
cat >> "$CLAUDE_ENV_FILE" << EOF
export DOEY_RUNTIME="$RUNTIME_DIR"
export SESSION_NAME="$SESSION_NAME"
export PROJECT_DIR="$PROJECT_DIR"
export PROJECT_NAME="$PROJECT_NAME"
export DOEY_ROLE="$ROLE"
export DOEY_PANE_INDEX="$PANE_INDEX"
export DOEY_WINDOW_INDEX="$WINDOW_INDEX"
export DOEY_TEAM_WINDOW="$TEAM_WINDOW"
export DOEY_TEAM_DIR="${wt_dir:-$PROJECT_DIR}"
EOF

# Set descriptive pane title
case "$ROLE" in
  watchdog)        tmux select-pane -t "${TMUX_PANE}" -T "T${TEAM_WINDOW} Watchdog" ;;
  manager)         tmux select-pane -t "${TMUX_PANE}" -T "T${TEAM_WINDOW} Window Manager" ;;
  session_manager) tmux select-pane -t "${TMUX_PANE}" -T "Session Manager" ;;
  worker)          tmux select-pane -t "${TMUX_PANE}" -T "T${TEAM_WINDOW} W${PANE_INDEX}" ;;
esac
