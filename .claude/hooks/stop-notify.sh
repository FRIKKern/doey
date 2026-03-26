#!/usr/bin/env bash
# Stop hook: unified notification dispatch (async)
#   Worker          → notify Window Manager pane
#   Window Manager  → notify Session Manager pane
#   Session Manager → desktop notification
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook
_DOEY_HOOK_NAME="stop-notify"
type _debug_hook_entry >/dev/null 2>&1 && _debug_hook_entry

# Early exit for roles that never send stop notifications
is_watchdog && exit 0
[ "$WINDOW_INDEX" = "0" ] && [ "$PANE_INDEX" = "0" ] && exit 0  # info panel

# Debug: dump stop hook INPUT to discover available fields
if [ -f "${RUNTIME_DIR}/debug.conf" ] && [ -d "${RUNTIME_DIR}/debug" ]; then
  echo "$INPUT" > "${RUNTIME_DIR}/debug/last_stop_input_${PANE_SAFE:-unknown}.json" 2>/dev/null || true
fi

# File-based message delivery with send-keys fallback.
# Writes an atomic message file and touches a trigger to wake the recipient.
_send_message_file() {
  local target_pane="$1" subject="$2" body="$3" sender="${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}"
  # Derive a safe target identifier from the pane spec (e.g. "doey-doey:3.0" -> "doey-doey_3_0")
  local target_safe
  target_safe=$(printf '%s' "$target_pane" | tr ':.' '_')

  local msg_dir="${RUNTIME_DIR}/messages"
  local trig_dir="${RUNTIME_DIR}/triggers"
  mkdir -p "$msg_dir" "$trig_dir" 2>/dev/null || true

  local timestamp
  timestamp="$(date +%s)_$$"
  local msg_file="${msg_dir}/${target_safe}_${timestamp}.msg"
  local tmp_file="${msg_file}.tmp"

  # Atomic write: tmp + mv
  if printf 'FROM: %s\nSUBJECT: %s\n%s\n' "$sender" "$subject" "$body" > "$tmp_file" 2>/dev/null \
     && mv "$tmp_file" "$msg_file" 2>/dev/null; then
    # Touch trigger to wake recipient
    touch "${trig_dir}/${target_safe}.trigger" 2>/dev/null || true
    return 0
  fi

  # Cleanup failed tmp
  rm -f "$tmp_file" 2>/dev/null || true
  return 1
}

# Deliver message via file queue, fall back to send-keys
_notify_pane() {
  local target_pane="$1" subject="$2" body="$3"
  if ! _send_message_file "$target_pane" "$subject" "$body" 2>/dev/null; then
    if ! send_to_pane "$target_pane" "$body" 2>/dev/null; then
      _log_error "DELIVERY_FAILED" "Both file and send-keys delivery failed" "target=$target_pane subject=$subject"
      return 1
    fi
  fi
}

# Dispatch workflow hooks for team-definition-based teams.
# Routes messages to the next pane in the workflow chain.
_dispatch_workflow_hooks() {
  local runtime_dir="$1" win_idx="$2" pane_idx="$3"
  local team_env="${runtime_dir}/team_${win_idx}.env"

  # Fast exit: no team def → nothing to do
  local team_def
  team_def=$(_read_team_key "$team_env" TEAM_DEF 2>/dev/null) || return 0
  [ -n "$team_def" ] || return 0

  local teamdef_env="${runtime_dir}/teamdef_${team_def}.env"
  [ -f "$teamdef_env" ] || return 0

  # Get this pane's role
  local my_role
  my_role=$(grep "^PANE_${pane_idx}_ROLE=" "$teamdef_env" 2>/dev/null | head -1 | cut -d'=' -f2-) || true
  [ -n "$my_role" ] || return 0

  # Check if team has a manager
  local mgr_pane
  mgr_pane=$(_read_team_key "$team_env" MANAGER_PANE 2>/dev/null) || mgr_pane=""

  # Loop through WORKFLOW_N rules (format: trigger|from|to|subject)
  local i=0
  while true; do
    local rule
    rule=$(grep "^WORKFLOW_${i}=" "$teamdef_env" 2>/dev/null | head -1 | cut -d'=' -f2-) || true
    [ -n "$rule" ] || break
    i=$((i + 1))

    local trigger from_role to_role subject
    trigger=$(printf '%s' "$rule" | cut -d'|' -f1)
    from_role=$(printf '%s' "$rule" | cut -d'|' -f2)
    to_role=$(printf '%s' "$rule" | cut -d'|' -f3)
    subject=$(printf '%s' "$rule" | cut -d'|' -f4)

    # Only match stop trigger from our role
    [ "$trigger" = "stop" ] && [ "$from_role" = "$my_role" ] || continue

    # Find target pane
    local target=""
    if [ -n "$mgr_pane" ]; then
      # Managed team: route through manager
      target="${SESSION_NAME}:${win_idx}.${mgr_pane}"
    else
      # Freelancer team: find target pane by scanning roles
      local p=0
      while true; do
        local p_role
        p_role=$(grep "^PANE_${p}_ROLE=" "$teamdef_env" 2>/dev/null | head -1 | cut -d'=' -f2-) || true
        [ -n "$p_role" ] || break
        if [ "$p_role" = "$to_role" ]; then
          target="${SESSION_NAME}:${win_idx}.${p}"
          break
        fi
        p=$((p + 1))
      done
    fi

    [ -n "$target" ] || continue

    # Build message body with workflow metadata
    local result_file="${runtime_dir}/results/pane_${win_idx}_${pane_idx}.json"
    local body="WORKFLOW_TARGET: ${to_role}
WORKFLOW_SOURCE: ${my_role}
Workflow rule matched: ${from_role} → ${to_role}"
    if [ -f "$result_file" ]; then
      local summary
      summary=$(head -20 "$result_file" 2>/dev/null) || summary=""
      [ -n "$summary" ] && body="${body}
${summary}"
    fi

    if _send_message_file "$target" "workflow:${subject}" "$body" 2>/dev/null; then
      type _debug_log >/dev/null 2>&1 && _debug_log workflow "dispatched" "rule=${from_role}->${to_role}" "subject=${subject}" "target=${target}"
    fi
  done
}

# Belt-and-suspenders: send-keys wake to team Watchdog (supplements trigger file)
_wake_team_watchdog() {
  local team_w="${DOEY_TEAM_WINDOW:-${WINDOW_INDEX:-}}"
  [ -z "$team_w" ] && return 0
  local team_env="${RUNTIME_DIR}/team_${team_w}.env"
  [ -f "$team_env" ] || return 0
  local wdg_pane
  wdg_pane=$(grep '^WATCHDOG_PANE=' "$team_env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"') || return 0
  [ -n "$wdg_pane" ] || return 0
  local wdg_target="${SESSION_NAME}:${wdg_pane}"
  # Only wake if pane exists and has a running process
  tmux display-message -t "$wdg_target" -p '#{pane_pid}' >/dev/null 2>&1 || return 0
  tmux send-keys -t "$wdg_target" "" 2>/dev/null || true
}

# --- Worker: notify its Window Manager (or Session Manager for freelancers) ---
if is_worker; then
  _team_type=$(_read_team_key "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" TEAM_TYPE)

  PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="W${PANE_INDEX}"

  RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
  STATUS="done"
  if [ -f "$RESULT_FILE" ]; then
    STATUS=$(jq -r '.status // "done"' "$RESULT_FILE" 2>/dev/null) \
      || STATUS=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('status','done'))" < "$RESULT_FILE" 2>/dev/null) \
      || STATUS="done"
  fi

  PANE_DISPLAY="${DOEY_PANE_ID:-${PANE_TITLE}}"
  LAST_MSG=$(parse_field "last_assistant_message")

  if [ "$_team_type" = "freelancer" ]; then
    # Freelancer workers notify Session Manager directly (no manager in this team)
    _sm_pane=$(_read_team_key "${RUNTIME_DIR}/session.env" SM_PANE)
    SM_TARGET="$SESSION_NAME:${_sm_pane:-0.1}"
    if ! tmux display-message -t "$SM_TARGET" -p '#{pane_pid}' >/dev/null 2>&1; then
      _log_error "DELIVERY_FAILED" "Target pane not found, notification dropped" "target=$SM_TARGET"
      exit 0
    fi
    MSG="Freelancer ${PANE_DISPLAY} finished (${STATUS})"
    [ -n "$LAST_MSG" ] && MSG="${MSG}: $(sanitize_message "$LAST_MSG" 100)"
    _notify_pane "$SM_TARGET" "freelancer_finished" "$MSG"
    type _debug_log >/dev/null 2>&1 && _debug_log messages "sent" "from=${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}" "to=${SM_TARGET}" "type=freelancer_finished" "delivery=file" "success=true"
    # Also touch SM-specific trigger for session-manager-wait.sh fast wakeup
    touch "${RUNTIME_DIR}/status/session_manager_trigger" 2>/dev/null || true
    _log "stop-notify: sent freelancer_finished to SM at $SM_TARGET"
  else
    _mgr_idx=$(_read_team_key "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
    MGR_PANE="$SESSION_NAME:$WINDOW_INDEX.${_mgr_idx:-0}"
    if ! tmux display-message -t "$MGR_PANE" -p '#{pane_pid}' >/dev/null 2>&1; then
      _log_error "DELIVERY_FAILED" "Target pane not found, notification dropped" "target=$MGR_PANE"
      exit 0
    fi
    MSG="Worker ${PANE_DISPLAY} finished (${STATUS})"
    [ -n "$LAST_MSG" ] && MSG="${MSG}: $(sanitize_message "$LAST_MSG" 100)"
    _notify_pane "$MGR_PANE" "worker_finished" "$MSG"
    type _debug_log >/dev/null 2>&1 && _debug_log messages "sent" "from=${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}" "to=${MGR_PANE}" "type=worker_finished" "delivery=file" "success=true"
    _log "stop-notify: sent worker_finished to manager at $MGR_PANE"
  fi

  # Dispatch workflow hooks if this team has a team definition
  _dispatch_workflow_hooks "$RUNTIME_DIR" "$WINDOW_INDEX" "$PANE_INDEX"
  _wake_team_watchdog
  exit 0
fi

# --- Window Manager: notify Session Manager ---
if is_manager; then
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  [ -f "$STATUS_FILE" ] || exit 0
  _cur=$(grep '^STATUS:' "$STATUS_FILE" 2>/dev/null | head -1)
  [ "${_cur#STATUS: }" = "BUSY" ] || exit 0

  SM_PANE=$(get_sm_pane)
  if ! tmux display-message -t "$SESSION_NAME:${SM_PANE}" -p '#{pane_pid}' >/dev/null 2>&1; then
    _log_error "DELIVERY_FAILED" "Target pane not found, notification dropped" "target=$SESSION_NAME:${SM_PANE}"
    exit 0
  fi

  SUMMARY=$(sanitize_message "$(parse_field "last_assistant_message")" 150)
  [ -z "$SUMMARY" ] && SUMMARY="(no summary)"

  _notify_pane "$SESSION_NAME:${SM_PANE}" "task_complete" "Team ${WINDOW_INDEX} Manager finished: ${SUMMARY}"
  type _debug_log >/dev/null 2>&1 && _debug_log messages "sent" "from=${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}" "to=${SESSION_NAME}:${SM_PANE}" "type=task_complete" "delivery=file" "success=true"
  # Also touch SM-specific trigger for session-manager-wait.sh fast wakeup
  touch "${RUNTIME_DIR}/status/session_manager_trigger" 2>/dev/null || true
  _log "stop-notify: sent task_complete to session manager at $SESSION_NAME:${SM_PANE}"
  _wake_team_watchdog
  exit 0
fi

# --- Session Manager: desktop notification ---
if is_session_manager; then
  LAST_MSG=$(parse_field "last_assistant_message")
  [ -z "$LAST_MSG" ] && exit 0
  echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯" && exit 0

  send_notification "Doey — Session Manager" "$(printf '%s' "${LAST_MSG:0:150}" | tr '\n"' " '")"
  type _debug_log >/dev/null 2>&1 && _debug_log messages "sent" "from=${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}" "to=desktop" "type=desktop_notification" "delivery=osascript" "success=true"
  _log "stop-notify: sent desktop notification"
fi

# Auto-resume REMOVED. The event-driven model (wait hooks + triggers) handles
# loop continuity. Auto-resume fired on every stop (including normal turn ends
# and user interrupts) because Claude Code doesn't expose stop_reason to hooks,
# causing false "API error" messages that distract the user.

exit 0
