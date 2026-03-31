#!/usr/bin/env bash
# doey-ipc-helpers.sh — Lightweight IPC helpers for messaging Session Manager.
# Sourceable library, not standalone.
set -euo pipefail

# ── ensure_sm_alive ──────────────────────────────────────────────────
# Check if Session Manager is alive and responsive.
# Args: $1 = RUNTIME_DIR, $2 = SESSION_NAME
# Returns: 0 = SM alive, 1 = SM woken (caller should retry), 2 = SM unreachable
ensure_sm_alive() {
  local runtime_dir="$1" session_name="$2"
  local sm_pane="0.2"
  local sm_safe="${session_name//[-:.]/_}_0_2"
  local status_file="${runtime_dir}/status/${sm_safe}.status"

  # Check if tmux pane exists at all
  if ! tmux display-message -t "${session_name}:${sm_pane}" -p '#{pane_pid}' >/dev/null 2>&1; then
    return 2
  fi

  # Read status file
  local status="" updated=""
  if [ -f "$status_file" ]; then
    status=$(grep '^STATUS:' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS:[[:space:]]*//' || true)
    updated=$(grep '^UPDATED:' "$status_file" 2>/dev/null | head -1 | sed 's/^UPDATED:[[:space:]]*//' || true)
  fi

  # Check staleness: UPDATED should be < 120s old
  if [ -n "$updated" ] && [ -n "$status" ]; then
    local now updated_epoch age
    now=$(date +%s)
    # Parse ISO date to epoch — try GNU date, fall back to Python, fall back to file mtime
    updated_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$updated" +%s 2>/dev/null) \
      || updated_epoch=$(python3 -c "import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))" "$updated" 2>/dev/null) \
      || updated_epoch=0
    if [ "$updated_epoch" -gt 0 ]; then
      age=$((now - updated_epoch))
      if [ "$age" -lt 120 ]; then
        return 0  # SM alive and fresh
      fi
    fi
  fi

  # Stale or missing — wake SM
  tmux send-keys -t "${session_name}:${sm_pane}" "" 2>/dev/null || true
  touch "${runtime_dir}/status/session_manager_trigger" 2>/dev/null || true

  # Brief wait, re-check
  sleep 3

  if [ -f "$status_file" ]; then
    local new_updated
    new_updated=$(grep '^UPDATED:' "$status_file" 2>/dev/null | head -1 | sed 's/^UPDATED:[[:space:]]*//' || true)
    if [ -n "$new_updated" ] && [ "$new_updated" != "$updated" ]; then
      return 1  # SM woken successfully
    fi
  fi

  # Still stale — check pane is still there
  if tmux display-message -t "${session_name}:${sm_pane}" -p '#{pane_pid}' >/dev/null 2>&1; then
    return 1  # Pane exists, assume wake is propagating
  fi
  return 2
}

# ── send_msg_to_sm ───────────────────────────────────────────────────
# Write a .msg file to SM's message queue and touch the trigger.
# Calls ensure_sm_alive first; retries once if SM was woken.
# Args: $1 = RUNTIME_DIR, $2 = SESSION_NAME, $3 = subject, $4 = body
#       $5 = sender (optional, defaults to DOEY_PANE_ID or "unknown")
# Returns: 0 = delivered, 1 = SM unreachable
send_msg_to_sm() {
  local runtime_dir="$1" session_name="$2" subject="$3" body="$4"
  local sender="${5:-${DOEY_PANE_ID:-unknown}}"
  local sm_safe="${session_name//[-:.]/_}_0_2"

  local msg_dir="${runtime_dir}/messages"
  local trig_dir="${runtime_dir}/triggers"
  mkdir -p "$msg_dir" "$trig_dir" 2>/dev/null || true

  # Health check
  local rc=0
  ensure_sm_alive "$runtime_dir" "$session_name" || rc=$?
  if [ "$rc" -eq 2 ]; then
    return 1
  fi

  # Write message atomically
  local timestamp
  timestamp="$(date +%s)_$$"
  local msg_file="${msg_dir}/${sm_safe}_${timestamp}.msg"
  local tmp_file="${msg_file}.tmp"

  if printf 'FROM: %s\nSUBJECT: %s\n%s\n' "$sender" "$subject" "$body" > "$tmp_file" 2>/dev/null \
     && mv "$tmp_file" "$msg_file" 2>/dev/null; then
    touch "${trig_dir}/${sm_safe}.trigger" 2>/dev/null || true
    touch "${runtime_dir}/status/session_manager_trigger" 2>/dev/null || true
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  return 1
}
