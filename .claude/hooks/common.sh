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
  # which caused ALL workers to think they were the Manager and spam notifications.
  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_SAFE=${PANE//[:.]/_}
  SESSION_NAME="${PANE%%:*}"
  PANE_INDEX="${PANE##*.}"
  NOW=$(date '+%Y-%m-%dT%H:%M:%S%z')

  # Stable pane ID (survives pane add/remove, unlike PANE_INDEX)
  PANE_ID=""
  if [[ -n "$TMUX_PANE" ]]; then
    PANE_ID="$TMUX_PANE"  # TMUX_PANE env var IS the pane ID (e.g., %5)
  fi

  # Export pane identity for subprocesses
  export PANE_ID

  # Ensure runtime dirs exist (fast-path: skip if all present)
  if [ ! -d "${RUNTIME_DIR}/status" ] || [ ! -d "${RUNTIME_DIR}/results" ] || [ ! -d "${RUNTIME_DIR}/inbox" ]; then
    mkdir -p "${RUNTIME_DIR}/status" "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports" "${RUNTIME_DIR}/results" "${RUNTIME_DIR}/inbox"
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

is_watchdog() {
  [ -f "${RUNTIME_DIR}/session.env" ] || return 1
  local wd_pane
  wd_pane=$(grep '^WATCHDOG_PANE=' "${RUNTIME_DIR}/session.env" | cut -d= -f2 | tr -d '"')
  [ "$PANE_INDEX" = "$wd_pane" ]
}

is_manager() {
  local wp="${PANE#*:}"
  [ "$wp" = "0.0" ]
}

is_worker() {
  ! is_manager && ! is_watchdog
}

is_reserved() {
  [ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ]
}

reserve_pane() {
  echo "permanent" > "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
}

# Unreserve this pane
unreserve_pane() {
  rm -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
}

# Check if this prompt was dispatched by Manager/Watchdog (not human)
is_dispatched() {
  local marker="${RUNTIME_DIR}/status/${PANE_SAFE}.dispatched"
  if [ -f "$marker" ]; then
    rm -f "$marker"  # consume the marker
    return 0
  fi
  return 1
}

# Get stable pane ID for a given pane reference
# Usage: pane_id=$(get_pane_id "$SESSION_NAME:0.3")
get_pane_id() {
  local pane_ref="$1"
  tmux display-message -t "$pane_ref" -p '#{pane_id}' 2>/dev/null
}

# Get current pane index for a stable pane ID
# Usage: pane_idx=$(get_pane_index "%5")
get_pane_index() {
  local pane_id="$1"
  tmux list-panes -s -F '#{pane_id} #{pane_index}' 2>/dev/null | \
    awk -v id="$pane_id" '$1 == id { print $2 }'
}

# Rebuild pane ID → index mapping for all panes in session
# Writes to $RUNTIME_DIR/status/pane_map
refresh_pane_map() {
  local session="${1:-$SESSION_NAME}"
  local runtime="${2:-$RUNTIME_DIR}"
  mkdir -p "${runtime}/status"
  tmux list-panes -s -t "$session" -F '#{pane_id} #{pane_index} #{pane_title}' \
    > "${runtime}/status/pane_map" 2>/dev/null
}

# Cross-platform desktop notification
send_notification() {
  local title="${1:-Claude Code}"
  local body="${2:-Task completed}"

  # Defense-in-depth: only Manager sends notifications
  if ! is_manager; then
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
      if (( now - last_sent < 60 )); then
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
