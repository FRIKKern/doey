#!/usr/bin/env bash
# Stop hook: unified notification dispatch (async)
#   Worker          → notify Window Manager pane
#   Window Manager  → notify Session Manager pane
#   Session Manager → notify Boss pane
#   Boss            → desktop notification
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook
_DOEY_HOOK_NAME="stop-notify"
type _debug_hook_entry >/dev/null 2>&1 && _debug_hook_entry

[ "$WINDOW_INDEX" = "0" ] && [ "$PANE_INDEX" = "0" ] && exit 0  # info panel

if [ -f "${RUNTIME_DIR}/debug.conf" ] && [ -d "${RUNTIME_DIR}/debug" ]; then
  echo "$INPUT" > "${RUNTIME_DIR}/debug/last_stop_input_${PANE_SAFE:-unknown}.json" 2>/dev/null || true
fi

# Helpers for repeated patterns
_pane_alive() { tmux display-message -t "$1" -p '#{pane_pid}' >/dev/null 2>&1; }
_is_spam() { echo "$1" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯"; }
_debug_sent() {
  type _debug_log >/dev/null 2>&1 && _debug_log messages "sent" "from=${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}" "to=$1" "type=$2" "delivery=${3:-file}" "success=true"
}

_send_message_file() {
  local target_pane="$1" subject="$2" body="$3" sender="${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}"
  local target_safe
  target_safe=$(printf '%s' "$target_pane" | tr ':.-' '_')

  local msg_dir="${RUNTIME_DIR}/messages"
  local trig_dir="${RUNTIME_DIR}/triggers"
  mkdir -p "$msg_dir" "$trig_dir" 2>/dev/null || true

  local timestamp
  timestamp="$(date +%s)_$$"
  local msg_file="${msg_dir}/${target_safe}_${timestamp}.msg"
  local tmp_file="${msg_file}.tmp"

  if printf 'FROM: %s\nSUBJECT: %s\n%s\n' "$sender" "$subject" "$body" > "$tmp_file" 2>/dev/null \
     && mv "$tmp_file" "$msg_file" 2>/dev/null; then
    touch "${trig_dir}/${target_safe}.trigger" 2>/dev/null || true
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  return 1
}

_notify_pane() {
  local target_pane="$1" subject="$2" body="$3"
  if ! _send_message_file "$target_pane" "$subject" "$body" 2>/dev/null; then
    if ! send_to_pane "$target_pane" "$body" 2>/dev/null; then
      _log_error "DELIVERY_FAILED" "Both file and send-keys delivery failed" "target=$target_pane subject=$subject"
      return 1
    fi
  fi
}

_dispatch_workflow_hooks() {
  local runtime_dir="$1" win_idx="$2" pane_idx="$3"
  local team_env="${runtime_dir}/team_${win_idx}.env"
  local team_def
  team_def=$(_read_team_key "$team_env" TEAM_DEF 2>/dev/null) || return 0
  [ -n "$team_def" ] || return 0

  local teamdef_env="${runtime_dir}/teamdef_${team_def}.env"
  [ -f "$teamdef_env" ] || return 0

  local my_role
  my_role=$(grep "^PANE_${pane_idx}_ROLE=" "$teamdef_env" 2>/dev/null | head -1 | cut -d'=' -f2-) || true
  [ -n "$my_role" ] || return 0

  local mgr_pane
  mgr_pane=$(_read_team_key "$team_env" MANAGER_PANE 2>/dev/null) || mgr_pane=""

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

    [ "$trigger" = "stop" ] && [ "$from_role" = "$my_role" ] || continue

    local target=""
    if [ -n "$mgr_pane" ]; then
      target="${SESSION_NAME}:${win_idx}.${mgr_pane}"
    else
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

# Belt-and-suspenders: send-keys wake to Session Manager (supplements trigger file)
_wake_sm() {
  local sm_pane="${SM_PANE:-0.2}"
  tmux send-keys -t "${SESSION_NAME}:${sm_pane}" "" 2>/dev/null || true
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

  # Determine target pane, label, and subject
  if [ "$_team_type" = "freelancer" ]; then
    _sm_pane=$(_read_team_key "${RUNTIME_DIR}/session.env" SM_PANE)
    _target="$SESSION_NAME:${_sm_pane:-0.2}"
    _label="Freelancer"; _subject="freelancer_finished"
  else
    _mgr_idx=$(_read_team_key "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
    _target="$SESSION_NAME:$WINDOW_INDEX.${_mgr_idx:-0}"
    _label="Worker"; _subject="worker_finished"
  fi

  _pane_alive "$_target" || { _log_error "DELIVERY_FAILED" "Target pane not found" "target=$_target"; exit 0; }
  MSG="${_label} ${PANE_DISPLAY} finished (${STATUS})"
  [ -n "$LAST_MSG" ] && MSG="${MSG}: $(sanitize_message "$LAST_MSG" 100)"
  _notify_pane "$_target" "$_subject" "$MSG"
  _debug_sent "$_target" "$_subject"
  { [ "$_team_type" = "freelancer" ] && touch "${RUNTIME_DIR}/status/session_manager_trigger" 2>/dev/null; } || true
  _log "stop-notify: sent ${_subject} to ${_target}"
  _dispatch_workflow_hooks "$RUNTIME_DIR" "$WINDOW_INDEX" "$PANE_INDEX"
  _wake_sm
  exit 0
fi

# --- Window Manager: notify Session Manager ---
if is_manager; then
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  [ -f "$STATUS_FILE" ] || exit 0
  _cur=$(grep '^STATUS:' "$STATUS_FILE" 2>/dev/null | head -1)
  [ "${_cur#STATUS: }" = "BUSY" ] || exit 0

  SM_PANE=$(get_sm_pane)
  _pane_alive "$SESSION_NAME:${SM_PANE}" || { _log_error "DELIVERY_FAILED" "Target pane not found" "target=$SESSION_NAME:${SM_PANE}"; exit 0; }

  SUMMARY=$(sanitize_message "$(parse_field "last_assistant_message")" 150)
  [ -z "$SUMMARY" ] && SUMMARY="(no summary)"

  _notify_pane "$SESSION_NAME:${SM_PANE}" "task_complete" "Team ${WINDOW_INDEX} Manager finished: ${SUMMARY}"
  _debug_sent "$SESSION_NAME:${SM_PANE}" "task_complete"
  touch "${RUNTIME_DIR}/status/session_manager_trigger" 2>/dev/null || true
  _log "stop-notify: sent task_complete to session manager at $SESSION_NAME:${SM_PANE}"
  _wake_sm
  exit 0
fi

# --- Session Manager: notify Boss ---
if is_session_manager; then
  LAST_MSG=$(parse_field "last_assistant_message")
  [ -z "$LAST_MSG" ] && exit 0
  _is_spam "$LAST_MSG" && exit 0

  BOSS_TARGET="$SESSION_NAME:0.1"
  if _pane_alive "$BOSS_TARGET"; then
    SUMMARY=$(sanitize_message "$LAST_MSG" 150)
    _notify_pane "$BOSS_TARGET" "sm_update" "SM update: ${SUMMARY}"
    _debug_sent "$BOSS_TARGET" "sm_update"
    _log "stop-notify: sent sm_update to Boss at $BOSS_TARGET"
  fi
fi

# --- Boss: desktop notification ---
if is_boss; then
  LAST_MSG=$(parse_field "last_assistant_message")
  [ -z "$LAST_MSG" ] && exit 0
  _is_spam "$LAST_MSG" && exit 0

  send_notification "Doey — Boss" "$(printf '%s' "${LAST_MSG:0:150}" | tr '\n"' " '")"
  _debug_sent "desktop" "desktop_notification" "osascript"
  _log "stop-notify: sent desktop notification"
fi

exit 0
