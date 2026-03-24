#!/usr/bin/env bash
# Stop hook: unified notification dispatch (async)
#   Worker          → notify Window Manager pane
#   Window Manager  → notify Session Manager pane
#   Session Manager → desktop notification
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook
_DOEY_HOOK_NAME="stop-notify"

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
    _log "stop-notify: sent worker_finished to manager at $MGR_PANE"
  fi
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
  _log "stop-notify: sent task_complete to session manager at $SESSION_NAME:${SM_PANE}"
  exit 0
fi

# --- Session Manager: desktop notification ---
if is_session_manager; then
  LAST_MSG=$(parse_field "last_assistant_message")
  [ -z "$LAST_MSG" ] && exit 0
  echo "$LAST_MSG" | grep -qiE "bypass permissions|permissions on|shift\+tab|press enter|─{3,}|❯" && exit 0

  send_notification "Doey — Session Manager" "$(printf '%s' "${LAST_MSG:0:150}" | tr '\n"' " '")"
  _log "stop-notify: sent desktop notification"
  exit 0
fi

exit 0
