#!/usr/bin/env bash
# Common utilities for Claude Team hooks
# Sourced by individual hook scripts — do not run directly.

set -euo pipefail

init_hook() {
  # Read stdin JSON
  INPUT=$(cat)

  # Bail silently if not in tmux
  [ -z "${TMUX_PANE:-}" ] && exit 0
  tmux display-message -t "${TMUX_PANE}" -p '' >/dev/null 2>&1 || exit 0

  # Get runtime dir — bail if not set
  RUNTIME_DIR=$(tmux show-environment CLAUDE_TEAM_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  [ -z "$RUNTIME_DIR" ] && exit 0

  # Get pane identity
  # IMPORTANT: Use -t "$TMUX_PANE" to resolve THIS pane's identity, not the client's focused pane.
  # Without -t, tmux display-message returns info for whichever pane the user is viewing (usually 0.0),
  # which caused ALL workers to think they were the Manager and spam notifications.
  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_SAFE=${PANE//[:.]/_}
  SESSION_NAME="${PANE%%:*}"
  PANE_INDEX="${PANE##*.}"
  NOW=$(date -Iseconds)

  # Ensure runtime dirs exist
  mkdir -p "${RUNTIME_DIR}/status" "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports" "${RUNTIME_DIR}/results"
}

parse_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    echo "$INPUT" | jq -r ".${field} // empty" 2>/dev/null || echo ""
  else
    echo "$INPUT" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" 2>/dev/null || echo ""
  fi
}

is_watchdog() {
  [ -f "${RUNTIME_DIR}/session.env" ] || return 1
  local wd_pane
  wd_pane=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/session.env" | cut -d= -f2)
  [ "$PANE_INDEX" = "$wd_pane" ]
}

is_manager() {
  local wp="${PANE#*:}"
  [ "$wp" = "0.0" ]
}

is_worker() {
  ! is_manager && ! is_watchdog
}

# Cross-platform desktop notification
send_notification() {
  local title="${1:-Claude Code}"
  local body="${2:-Task completed}"

  if command -v osascript >/dev/null 2>&1; then
    # macOS
    osascript -e "display notification \"${body}\" with title \"${title}\" sound name \"Ping\"" 2>/dev/null &
  elif command -v notify-send >/dev/null 2>&1; then
    # Linux (libnotify)
    notify-send "$title" "$body" 2>/dev/null &
  elif command -v powershell.exe >/dev/null 2>&1; then
    # WSL2
    powershell.exe -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('${body}', '${title}')" 2>/dev/null &
  fi
  # Silent fallback if none available
  return 0
}
