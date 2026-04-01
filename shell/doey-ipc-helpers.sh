#!/usr/bin/env bash
# doey-ipc-helpers.sh — Lightweight IPC helpers for messaging Session Manager.
# Sourceable library, not standalone.
set -euo pipefail

# Returns: 0 = SM alive, 1 = SM woken (caller should retry), 2 = SM unreachable
ensure_sm_alive() {
  local runtime_dir="$1" session_name="$2"
  local sm_pane="0.2" sm_safe="${session_name//[-:.]/_}_0_2"
  local status_file="${runtime_dir}/status/${sm_safe}.status"

  tmux display-message -t "${session_name}:${sm_pane}" -p '#{pane_pid}' >/dev/null 2>&1 || return 2

  local status="" updated=""
  if [ -f "$status_file" ]; then
    status=$(grep '^STATUS:' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS:[[:space:]]*//' || true)
    updated=$(grep '^UPDATED:' "$status_file" 2>/dev/null | head -1 | sed 's/^UPDATED:[[:space:]]*//' || true)
  fi

  if [ -n "$updated" ] && [ -n "$status" ]; then
    local now updated_epoch age; now=$(date +%s)
    updated_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$updated" +%s 2>/dev/null) \
      || updated_epoch=$(python3 -c "import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))" "$updated" 2>/dev/null) \
      || updated_epoch=0
    if [ "$updated_epoch" -gt 0 ]; then
      age=$((now - updated_epoch))
      [ "$age" -lt 120 ] && return 0
    fi
  fi

  # Stale or missing — wake SM
  tmux send-keys -t "${session_name}:${sm_pane}" "" 2>/dev/null || true
  touch "${runtime_dir}/status/session_manager_trigger" 2>/dev/null || true
  sleep 3

  if [ -f "$status_file" ]; then
    local new_updated
    new_updated=$(grep '^UPDATED:' "$status_file" 2>/dev/null | head -1 | sed 's/^UPDATED:[[:space:]]*//' || true)
    [ -n "$new_updated" ] && [ "$new_updated" != "$updated" ] && return 1
  fi

  tmux display-message -t "${session_name}:${sm_pane}" -p '#{pane_pid}' >/dev/null 2>&1 && return 1
  return 2
}

# Write a .msg file to SM's message queue and touch the trigger.
# Returns: 0 = delivered, 1 = SM unreachable
send_msg_to_sm() {
  local runtime_dir="$1" session_name="$2" subject="$3" body="$4"
  local sender="${5:-${DOEY_PANE_ID:-unknown}}"
  local sm_safe="${session_name//[-:.]/_}_0_2"
  local msg_dir="${runtime_dir}/messages" trig_dir="${runtime_dir}/triggers"
  mkdir -p "$msg_dir" "$trig_dir" 2>/dev/null || true

  local rc=0; ensure_sm_alive "$runtime_dir" "$session_name" || rc=$?
  [ "$rc" -eq 2 ] && return 1

  local msg_file="${msg_dir}/${sm_safe}_$(date +%s)_$$.msg"
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
