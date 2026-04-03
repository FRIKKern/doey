#!/usr/bin/env bash
# doey-ipc-helpers.sh — Lightweight IPC helpers for messaging Taskmaster.
# Sourceable library, not standalone.
set -euo pipefail

# Returns: 0 = Taskmaster alive, 1 = Taskmaster woken (caller should retry), 2 = Taskmaster unreachable
ensure_taskmaster_alive() {
  local runtime_dir="$1" session_name="$2"
  local taskmaster_pane
  if [ -f "${runtime_dir}/session.env" ]; then
    taskmaster_pane=$(grep '^TASKMASTER_PANE=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2-)
  fi
  taskmaster_pane="${taskmaster_pane:-0.2}"
  local taskmaster_safe="${session_name//[-:.]/_}_${taskmaster_pane//[-.:]/_}"
  local status_file="${runtime_dir}/status/${taskmaster_safe}.status"

  tmux display-message -t "${session_name}:${taskmaster_pane}" -p '#{pane_pid}' >/dev/null 2>&1 || return 2

  # Try doey status (auto-detects DB)
  local _project_dir="${DOEY_PROJECT_DIR:-${PROJECT_DIR:-}}"
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "$_project_dir" ]; then
    local _db_status
    _db_status=$(doey status get "$taskmaster_safe" --project-dir "$_project_dir" --json 2>/dev/null) && {
      local _db_st
      _db_st=$(echo "$_db_status" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
      [ -n "$_db_st" ] && [ "$_db_st" != "FINISHED" ] && return 0
    }
  fi

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

  # Stale or missing — wake Taskmaster
  tmux send-keys -t "${session_name}:${taskmaster_pane}" "" 2>/dev/null || true
  touch "${runtime_dir}/status/taskmaster_trigger" 2>/dev/null || true
  sleep 3

  if [ -f "$status_file" ]; then
    local new_updated
    new_updated=$(grep '^UPDATED:' "$status_file" 2>/dev/null | head -1 | sed 's/^UPDATED:[[:space:]]*//' || true)
    [ -n "$new_updated" ] && [ "$new_updated" != "$updated" ] && return 1
  fi

  tmux display-message -t "${session_name}:${taskmaster_pane}" -p '#{pane_pid}' >/dev/null 2>&1 && return 1
  return 2
}

# Write a .msg file to Taskmaster's message queue and touch the trigger.
# Returns: 0 = delivered, 1 = Taskmaster unreachable
send_msg_to_taskmaster() {
  local runtime_dir="$1" session_name="$2" subject="$3" body="$4"
  local sender="${5:-${DOEY_PANE_ID:-unknown}}"
  local taskmaster_pane
  if [ -f "${runtime_dir}/session.env" ]; then
    taskmaster_pane=$(grep '^TASKMASTER_PANE=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2-)
  fi
  taskmaster_pane="${taskmaster_pane:-0.2}"
  local taskmaster_safe="${session_name//[-:.]/_}_${taskmaster_pane//[-.:]/_}"

  local rc=0; ensure_taskmaster_alive "$runtime_dir" "$session_name" || rc=$?
  [ "$rc" -eq 2 ] && return 1

  # Fast path: doey msg send (auto-detects DB, fires trigger internally)
  local _project_dir="${DOEY_PROJECT_DIR:-${PROJECT_DIR:-}}"
  if command -v doey-ctl >/dev/null 2>&1; then
    if doey msg send \
        --from "$sender" \
        --to "$taskmaster_safe" \
        --subject "$subject" \
        --body "$body" \
        --runtime "$runtime_dir" \
        ${_project_dir:+--project-dir "$_project_dir"} 2>/dev/null; then
      touch "${runtime_dir}/status/taskmaster_trigger" 2>/dev/null || true
      return 0
    fi
  fi

  # Fallback: shell implementation
  local msg_dir="${runtime_dir}/messages" trig_dir="${runtime_dir}/triggers"
  mkdir -p "$msg_dir" "$trig_dir" 2>/dev/null || true

  local msg_file="${msg_dir}/${taskmaster_safe}_$(date +%s)_$$.msg"
  local tmp_file="${msg_file}.tmp"
  if printf 'FROM: %s\nSUBJECT: %s\n%s\n' "$sender" "$subject" "$body" > "$tmp_file" 2>/dev/null \
     && mv "$tmp_file" "$msg_file" 2>/dev/null; then
    touch "${trig_dir}/${taskmaster_safe}.trigger" 2>/dev/null || true
    touch "${runtime_dir}/status/taskmaster_trigger" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp_file" 2>/dev/null || true
  return 1
}
