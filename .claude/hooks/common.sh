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
  # Cache result — this is called on every tool hook invocation
  if [ -n "${_DOEY_IS_WD+x}" ]; then
    return "$_DOEY_IS_WD"
  fi
  _DOEY_IS_WD=1  # default: not a watchdog
  # Watchdogs live in Dashboard (window 0), panes 0.2-0.4.
  # Each team_W.env has WATCHDOG_PANE="0.X" referencing the Dashboard pane.
  if [ "$WINDOW_INDEX" = "0" ]; then
    for _wd_tf in "${RUNTIME_DIR}"/team_*.env; do
      [ -f "$_wd_tf" ] || continue
      local _wd_val
      _wd_val=$(grep '^WATCHDOG_PANE=' "$_wd_tf" | cut -d= -f2)
      _wd_val="${_wd_val//\"/}"
      if [ "$_wd_val" = "0.${PANE_INDEX}" ]; then
        _DOEY_IS_WD=0
        break
      fi
    done
  fi
  return "$_DOEY_IS_WD"
}

is_manager() {
  # Cache result — this is called on every tool hook invocation
  if [ -n "${_DOEY_IS_MGR+x}" ]; then
    return "$_DOEY_IS_MGR"
  fi
  _DOEY_IS_MGR=1  # default: not a manager
  # Managers live in team windows (W≥1), pane 0.
  # Each team_W.env has MANAGER_PANE="0" (pane index within the team window).
  if [ "$WINDOW_INDEX" != "0" ]; then
    local team_file="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
    if [ -f "$team_file" ]; then
      local _mgr_val
      _mgr_val=$(grep '^MANAGER_PANE=' "$team_file" | cut -d= -f2)
      _mgr_val="${_mgr_val//\"/}"
      if [ "$PANE_INDEX" = "$_mgr_val" ]; then
        _DOEY_IS_MGR=0
      fi
    fi
  fi
  return "$_DOEY_IS_MGR"
}

is_session_manager() {
  # True only for the Session Manager — Dashboard pane 0.1.
  if [ "$WINDOW_INDEX" != "0" ]; then
    return 1
  fi
  local sm_pane
  sm_pane=$(get_sm_pane)
  local wp="${PANE#*:}"
  [ "$wp" = "$sm_pane" ]
}

is_worker() {
  # Workers live in team windows (1+), not in Dashboard (0), and are not the Manager (pane 0)
  [ "$WINDOW_INDEX" = "0" ] && return 1
  ! is_manager
}

# Get Session Manager pane address (e.g. "0.1"). Reads SM_PANE from session.env, defaults to "0.1".
get_sm_pane() {
  local sm_pane="0.1"
  if [ -f "${RUNTIME_DIR}/session.env" ]; then
    local _sm_val
    _sm_val=$(grep '^SM_PANE=' "${RUNTIME_DIR}/session.env" | cut -d= -f2)
    _sm_val="${_sm_val//\"/}"
    [ -n "$_sm_val" ] && sm_pane="$_sm_val"
  fi
  echo "$sm_pane"
}

# Send a message to another pane via tmux send-keys.
# Exits copy-mode first, suppresses errors silently.
# Usage: send_to_pane <target> <message>
send_to_pane() {
  local target="$1" msg="$2"
  tmux copy-mode -q -t "$target" 2>/dev/null
  tmux send-keys -t "$target" "$msg" Enter 2>/dev/null
}

# Sanitize and truncate a message for tmux delivery.
# Collapses newlines/whitespace, truncates to max_len chars.
# Usage: sanitize_message <text> [max_len]
sanitize_message() {
  local text="$1" max_len="${2:-100}"
  # Collapse newlines and multiple spaces
  text=$(printf '%s' "$text" | tr '\n' ' ' | sed 's/  */ /g')
  if [ "${#text}" -gt "$max_len" ]; then
    local cut_len=$((max_len - 3))
    text="${text:0:$cut_len}..."
  fi
  echo "$text"
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
