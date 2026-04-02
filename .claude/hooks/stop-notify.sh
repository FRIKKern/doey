#!/usr/bin/env bash
# Stop hook: unified notification dispatch (async)
# Worker→Subtaskmaster, Subtaskmaster→Taskmaster, Taskmaster→Boss, Boss→desktop
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "stop-notify"

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

_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

_send_message_file() {
  local target_pane="$1" subject="$2" body="$3"
  local sender="${DOEY_PANE_ID:-${PANE_SAFE:-unknown}}"
  local target_safe; target_safe=$(printf '%s' "$target_pane" | tr ':.-' '_')
  mkdir -p "${RUNTIME_DIR}/messages" "${RUNTIME_DIR}/triggers" 2>/dev/null || true
  local msg_file="${RUNTIME_DIR}/messages/${target_safe}_$(date +%s)_$$.msg"
  if printf 'FROM: %s\nSUBJECT: %s\n%s\n' "$sender" "$subject" "$body" > "${msg_file}.tmp" 2>/dev/null \
     && mv "${msg_file}.tmp" "$msg_file" 2>/dev/null; then
    touch "${RUNTIME_DIR}/triggers/${target_safe}.trigger" 2>/dev/null || true
    return 0
  fi
  rm -f "${msg_file}.tmp" 2>/dev/null || true
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
  local team_def; team_def=$(_read_team_key "$team_env" TEAM_DEF 2>/dev/null) || return 0
  [ -n "$team_def" ] || return 0
  local teamdef_env="${runtime_dir}/teamdef_${team_def}.env"
  [ -f "$teamdef_env" ] || return 0
  local my_role; my_role=$(grep "^PANE_${pane_idx}_ROLE=" "$teamdef_env" 2>/dev/null | head -1 | cut -d'=' -f2-) || true
  [ -n "$my_role" ] || return 0
  local mgr_pane; mgr_pane=$(_read_team_key "$team_env" MANAGER_PANE 2>/dev/null) || mgr_pane=""

  local i=0 rule
  while rule=$(grep "^WORKFLOW_${i}=" "$teamdef_env" 2>/dev/null | head -1 | cut -d'=' -f2-) && [ -n "$rule" ]; do
    i=$((i + 1))
    local trigger from_role to_role subject
    trigger=$(printf '%s' "$rule" | cut -d'|' -f1); from_role=$(printf '%s' "$rule" | cut -d'|' -f2)
    to_role=$(printf '%s' "$rule" | cut -d'|' -f3); subject=$(printf '%s' "$rule" | cut -d'|' -f4)
    [ "$trigger" = "stop" ] && [ "$from_role" = "$my_role" ] || continue

    local target=""
    if [ -n "$mgr_pane" ]; then
      target="${SESSION_NAME}:${win_idx}.${mgr_pane}"
    else
      local p=0 p_role
      while p_role=$(grep "^PANE_${p}_ROLE=" "$teamdef_env" 2>/dev/null | head -1 | cut -d'=' -f2-) && [ -n "$p_role" ]; do
        [ "$p_role" = "$to_role" ] && { target="${SESSION_NAME}:${win_idx}.${p}"; break; }
        p=$((p + 1))
      done
    fi
    [ -n "$target" ] || continue

    local body="WORKFLOW_TARGET: ${to_role}
WORKFLOW_SOURCE: ${my_role}
Workflow rule matched: ${from_role} → ${to_role}"
    local result_file="${runtime_dir}/results/pane_${win_idx}_${pane_idx}.json"
    if [ -f "$result_file" ]; then
      local summary; summary=$(head -20 "$result_file" 2>/dev/null) || summary=""
      [ -n "$summary" ] && body="${body}
${summary}"
    fi
    _send_message_file "$target" "workflow:${subject}" "$body" 2>/dev/null \
      && type _debug_log >/dev/null 2>&1 && _debug_log workflow "dispatched" "rule=${from_role}->${to_role}" "subject=${subject}" "target=${target}"
  done
}

_wake_taskmaster() { tmux send-keys -t "${SESSION_NAME}:${TASKMASTER_PANE:-0.2}" "" 2>/dev/null || true; }

if is_worker; then
  _team_type=$(_read_team_key "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" TEAM_TYPE)

  PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="W${PANE_INDEX}"

  RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
  STATUS="done"
  _SUMMARY="" _TOOL_COUNT="0" _FILES_COUNT="0" _RESULT_TS="0"
  if [ -f "$RESULT_FILE" ]; then
    if command -v jq >/dev/null 2>&1; then
      STATUS=$(jq -r '.status // "done"' "$RESULT_FILE" 2>/dev/null) || STATUS="done"
      _SUMMARY=$(jq -r '.summary // ""' "$RESULT_FILE" 2>/dev/null) || _SUMMARY=""
      _TOOL_COUNT=$(jq -r '.tool_calls // 0' "$RESULT_FILE" 2>/dev/null) || _TOOL_COUNT="0"
      _FILES_COUNT=$(jq '.files_changed | length' "$RESULT_FILE" 2>/dev/null) || _FILES_COUNT="0"
      _RESULT_TS=$(jq -r '.timestamp // 0' "$RESULT_FILE" 2>/dev/null) || _RESULT_TS="0"
    elif command -v python3 >/dev/null 2>&1; then
      STATUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status','done'))" "$RESULT_FILE" 2>/dev/null) || STATUS="done"
      _SUMMARY=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('summary',''))" "$RESULT_FILE" 2>/dev/null) || _SUMMARY=""
      _TOOL_COUNT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('tool_calls',0))" "$RESULT_FILE" 2>/dev/null) || _TOOL_COUNT="0"
      _FILES_COUNT=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('files_changed',[])))" "$RESULT_FILE" 2>/dev/null) || _FILES_COUNT="0"
      _RESULT_TS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('timestamp',0))" "$RESULT_FILE" 2>/dev/null) || _RESULT_TS="0"
    fi
  fi

  # Compute duration from status file
  _DURATION="unknown"
  _STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  if [ -f "$_STATUS_FILE" ] && [ "${_RESULT_TS}" != "0" ]; then
    _start_ts=$(grep '^UPDATED:' "$_STATUS_FILE" 2>/dev/null | head -1 | sed 's/^UPDATED:[[:space:]]*//' | tr -d ' ') || _start_ts=""
    if [ -z "$_start_ts" ]; then
      _start_ts=$(stat -c%Y "$_STATUS_FILE" 2>/dev/null || stat -f%m "$_STATUS_FILE" 2>/dev/null) || _start_ts=""
    fi
    if [ -n "${_start_ts:-}" ] && [ "$_start_ts" -gt 0 ] 2>/dev/null && [ "$_RESULT_TS" -gt "$_start_ts" ] 2>/dev/null; then
      _DURATION="$((_RESULT_TS - _start_ts))s"
    fi
  fi

  LAST_MSG=$(parse_field "last_assistant_message")

  if [ "$_team_type" = "freelancer" ]; then
    _taskmaster_pane=$(_read_team_key "${RUNTIME_DIR}/session.env" TASKMASTER_PANE)
    _target="$SESSION_NAME:${_taskmaster_pane:-0.2}"
    _subject="freelancer_finished"
  else
    _mgr_idx=$(_read_team_key "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
    _target="$SESSION_NAME:$WINDOW_INDEX.${_mgr_idx:-0}"
    _subject="worker_finished"
  fi

  _pane_alive "$_target" || { _log_error "DELIVERY_FAILED" "Target pane not found" "target=$_target"; exit 0; }

  # Build summary: prefer result summary, fall back to last message
  _NOTIFY_SUMMARY="${_SUMMARY}"
  [ -z "$_NOTIFY_SUMMARY" ] && [ -n "$LAST_MSG" ] && _NOTIFY_SUMMARY=$(sanitize_message "$LAST_MSG" 100)
  _STATUS_LABEL="FINISHED"
  [ "$STATUS" = "error" ] && _STATUS_LABEL="ERROR"
  MSG="<task-notification>
  <pane>${WINDOW_INDEX}.${PANE_INDEX}</pane>
  <status>${_STATUS_LABEL}</status>
  <summary>$(_xml_escape "${_NOTIFY_SUMMARY}")</summary>
  <files-changed>${_FILES_COUNT}</files-changed>
  <tool-count>${_TOOL_COUNT}</tool-count>
  <duration>${_DURATION}</duration>
</task-notification>"
  _notify_pane "$_target" "$_subject" "$MSG"
  _debug_sent "$_target" "$_subject"
  { [ "$_team_type" = "freelancer" ] && touch "${RUNTIME_DIR}/status/taskmaster_trigger" 2>/dev/null; } || true
  _log "stop-notify: sent ${_subject} to ${_target}"
  _dispatch_workflow_hooks "$RUNTIME_DIR" "$WINDOW_INDEX" "$PANE_INDEX"
  _wake_taskmaster
  exit 0
fi

if is_manager; then
  STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
  [ -f "$STATUS_FILE" ] || exit 0
  _cur=$(grep '^STATUS:' "$STATUS_FILE" 2>/dev/null | head -1)
  [ "${_cur#STATUS: }" = "BUSY" ] || exit 0

  TASKMASTER_PANE=$(get_taskmaster_pane)
  _pane_alive "$SESSION_NAME:${TASKMASTER_PANE}" || { _log_error "DELIVERY_FAILED" "Target pane not found" "target=$SESSION_NAME:${TASKMASTER_PANE}"; exit 0; }

  SUMMARY=$(sanitize_message "$(parse_field "last_assistant_message")" 150)
  [ -z "$SUMMARY" ] && SUMMARY="(no summary)"

  _notify_pane "$SESSION_NAME:${TASKMASTER_PANE}" "task_complete" "Team ${WINDOW_INDEX} Manager finished: ${SUMMARY}"
  _debug_sent "$SESSION_NAME:${TASKMASTER_PANE}" "task_complete"
  touch "${RUNTIME_DIR}/status/taskmaster_trigger" 2>/dev/null || true
  _log "stop-notify: sent task_complete to session manager at $SESSION_NAME:${TASKMASTER_PANE}"
  _wake_taskmaster
  exit 0
fi

if is_taskmaster; then
  LAST_MSG=$(parse_field "last_assistant_message")
  [ -z "$LAST_MSG" ] && exit 0
  _is_spam "$LAST_MSG" && exit 0

  BOSS_TARGET="$SESSION_NAME:0.1"
  if _pane_alive "$BOSS_TARGET"; then
    SUMMARY=$(sanitize_message "$LAST_MSG" 150)
    _notify_pane "$BOSS_TARGET" "taskmaster_update" "Taskmaster update: ${SUMMARY}"
    _debug_sent "$BOSS_TARGET" "taskmaster_update"
    _log "stop-notify: sent taskmaster_update to Boss at $BOSS_TARGET"
  fi
fi

if is_boss; then
  LAST_MSG=$(parse_field "last_assistant_message")
  [ -z "$LAST_MSG" ] && exit 0
  _is_spam "$LAST_MSG" && exit 0

  send_notification "Doey — Boss" "$(printf '%s' "${LAST_MSG:0:150}" | tr '\n"' " '")"
  _debug_sent "desktop" "desktop_notification" "osascript"
  _log "stop-notify: sent desktop notification"
fi

exit 0
