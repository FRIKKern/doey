#!/usr/bin/env bash
# Common utilities for Doey hooks
# Sourced by individual hook scripts — do not run directly.

set -euo pipefail

init_hook() {
  # Read stdin JSON
  INPUT=$(cat)

  # Bail silently if not in tmux
  [ -z "${TMUX_PANE:-}" ] && exit 0

  # Get runtime dir — bail if not set
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  [ -z "$RUNTIME_DIR" ] && exit 0

  # Get pane identity
  # IMPORTANT: Use -t "$TMUX_PANE" to resolve THIS pane's identity, not the client's focused pane.
  # Without -t, tmux display-message returns info for whichever pane the user is viewing (usually 0.0),
  # which caused ALL workers to think they were the Window Manager and spam notifications.
  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_SAFE=${PANE//[:.]/_}
  SESSION_NAME="${PANE%%:*}"
  PANE_INDEX="${PANE##*.}"
  # Extract window index for multi-window support
  local _wp="${PANE#*:}"          # "1.5"
  WINDOW_INDEX="${_wp%.*}"        # "1"
  NOW=$(date '+%Y-%m-%dT%H:%M:%S%z')

  # Ensure runtime dirs exist (fast-path: skip if all present)
  if [ ! -d "${RUNTIME_DIR}/status" ] || [ ! -d "${RUNTIME_DIR}/results" ] || [ ! -d "${RUNTIME_DIR}/messages" ] || [ ! -d "${RUNTIME_DIR}/research" ] || [ ! -d "${RUNTIME_DIR}/reports" ]; then
    mkdir -p "${RUNTIME_DIR}/status" "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports" "${RUNTIME_DIR}/results" "${RUNTIME_DIR}/messages"
  fi
}

parse_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    echo "$INPUT" | jq -r ".${field} // empty" 2>/dev/null || echo ""
  else
    echo "$INPUT" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" 2>/dev/null || echo ""
  fi
}

load_team_env() {
  # Load per-window team env file (multi-window support).
  # Populates _TEAM_WD_PANE, _TEAM_MGR_PANE, _TEAM_WORKER_PANES, _TEAM_WORKER_COUNT.
  # Returns 1 if no team file exists for this window.
  local team_file="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  [ -f "$team_file" ] || return 1
  _TEAM_WD_PANE="" _TEAM_MGR_PANE="" _TEAM_WORKER_PANES="" _TEAM_WORKER_COUNT=""
  while IFS='=' read -r key value; do
    value="${value%\"}" && value="${value#\"}"
    case "$key" in
      WATCHDOG_PANE)  _TEAM_WD_PANE="$value" ;;
      WORKER_PANES)   _TEAM_WORKER_PANES="$value" ;;
      MANAGER_PANE)   _TEAM_MGR_PANE="$value" ;;
      WORKER_COUNT)   _TEAM_WORKER_COUNT="$value" ;;
    esac
  done < "$team_file"
}

is_watchdog() {
  # Cache result to avoid re-reading env files on repeated calls.
  # Multi-window: check team_<W>.env first, fall back to session.env.
  if [ -z "${_DOEY_WD_PANE+x}" ]; then
    local team_file="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
    if [ -f "$team_file" ]; then
      _DOEY_WD_PANE=$(grep '^WATCHDOG_PANE=' "$team_file" | cut -d= -f2)
      _DOEY_WD_PANE="${_DOEY_WD_PANE//\"/}"
    elif [ -f "${RUNTIME_DIR}/session.env" ]; then
      _DOEY_WD_PANE=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/session.env" | cut -d= -f2)
      _DOEY_WD_PANE="${_DOEY_WD_PANE//\"/}"
    else
      return 1
    fi
  fi
  [ "$PANE_INDEX" = "$_DOEY_WD_PANE" ]
}

is_manager() {
  # Pane index 0 is always the Window Manager in any team window.
  # Info Panel (0.0 in multi-window) is a shell script — hooks never run there, so this is safe.
  [ "$PANE_INDEX" = "0" ]
}

is_session_manager() {
  # True only for the global session manager (window 0, pane 1)
  # In multi-window mode, 0.0 is the Info Panel; 0.1 is the Session Manager.
  local wp="${PANE#*:}"
  [ "$wp" = "0.1" ]
}

is_worker() {
  ! is_manager && ! is_watchdog
}

is_reserved() {
  [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]
}

# Portable newline for bash 3.2 string building
NL='
'

# Numeric-only validation (bash 3.2 safe)
is_numeric() { case "$1" in *[!0-9]*|'') return 1 ;; esac; }

# Cross-platform desktop notification
send_notification() {
  local title="${1:-Claude Code}"
  local body="${2:-Task completed}"

  # Defense-in-depth: only Session Manager (0.1) sends notifications
  if ! is_session_manager; then
    return 0
  fi

  # Enforce 60-second cooldown per title
  if [ -n "${RUNTIME_DIR:-}" ]; then
    local title_safe="${title//[^a-zA-Z0-9]/_}"
    local cooldown_file="${RUNTIME_DIR}/status/notif_cooldown_${title_safe}"
    if [ -f "$cooldown_file" ]; then
      local last_sent now
      last_sent=$(cat "$cooldown_file" 2>/dev/null) || last_sent=0
      now=$(date +%s)
      if [ "$((now - last_sent))" -lt 60 ]; then
        return 0  # Cooldown active — skip
      fi
    fi
    date +%s > "$cooldown_file" 2>/dev/null || true
  fi

  # Sanitize for AppleScript string safety
  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  body="${body//\\/\\\\}"
  body="${body//\"/\\\"}"

  if command -v osascript >/dev/null 2>&1; then
    # macOS
    osascript -e "display notification \"${body}\" with title \"${title}\" sound name \"Ping\"" 2>/dev/null &
  elif command -v notify-send >/dev/null 2>&1; then
    # Linux (libnotify)
    notify-send "$title" "$body" 2>/dev/null &
  elif command -v powershell.exe >/dev/null 2>&1; then
    # WSL2 — escape single quotes for PowerShell string safety
    local ps_title="${title//\'/\'\'}"
    local ps_body="${body//\'/\'\'}"
    powershell.exe -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('${ps_body}', '${ps_title}')" 2>/dev/null &
  fi
  # Silent fallback if none available
  return 0
}
