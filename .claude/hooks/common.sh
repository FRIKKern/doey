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
  NOW=$(date -Iseconds)

  # Ensure runtime dirs exist (fast-path: skip if all present)
  if [ ! -d "${RUNTIME_DIR}/status" ] || [ ! -d "${RUNTIME_DIR}/results" ]; then
    mkdir -p "${RUNTIME_DIR}/status" "${RUNTIME_DIR}/research" "${RUNTIME_DIR}/reports" "${RUNTIME_DIR}/results"
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

# Check if this pane is reserved (has unexpired reservation)
is_reserved() {
  local reserve_file="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
  [ -f "$reserve_file" ] || return 1
  local expiry
  expiry=$(head -1 "$reserve_file" 2>/dev/null) || return 1
  # "permanent" means reserved indefinitely
  [ "$expiry" = "permanent" ] && return 0
  local now
  now=$(date +%s)
  [ "$now" -lt "$expiry" ] && return 0
  # Expired — clean up
  rm -f "$reserve_file"
  return 1
}

# Reserve this pane. Args: duration_seconds ("permanent" for indefinite)
reserve_pane() {
  local duration="$1"
  local reserve_file="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
  if [ "$duration" = "permanent" ]; then
    echo "permanent" > "$reserve_file"
  else
    local expiry
    expiry=$(( $(date +%s) + duration ))
    echo "$expiry" > "$reserve_file"
  fi
}

# Unreserve this pane
unreserve_pane() {
  rm -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
}

# Get reservation info. Returns: "none", "permanent", or seconds remaining
get_reservation_info() {
  local reserve_file="${RUNTIME_DIR}/status/${PANE_SAFE}.reserved"
  [ -f "$reserve_file" ] || { echo "none"; return; }
  local expiry
  expiry=$(head -1 "$reserve_file" 2>/dev/null) || { echo "none"; return; }
  [ "$expiry" = "permanent" ] && { echo "permanent"; return; }
  local now remaining
  now=$(date +%s)
  remaining=$(( expiry - now ))
  [ "$remaining" -le 0 ] && { rm -f "$reserve_file"; echo "none"; return; }
  echo "$remaining"
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

# Cross-platform desktop notification
send_notification() {
  local title="${1:-Claude Code}"
  local body="${2:-Task completed}"

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
