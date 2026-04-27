#!/usr/bin/env bash
# stm-wait.sh — Subtaskmaster (team lead) wait/sleep hook (task 648).
#
# Subtaskmasters block here while their workers run. Wake conditions:
#   MSG       — own-pane has unread messages
#   TRIGGERED — own-pane trigger file present
#   FINISHED  — any worker in this team transitioned to FINISHED/ERROR/RESERVED
#   ALL_DONE  — every worker in this team is in a terminal state
#   TIMEOUT   — DOEY_WAIT_TIMEOUT (default 1800s) elapsed without other wake
#
# Mirrors the structure of taskmaster-wait.sh's passive-role path so future
# diffs stay reviewable side-by-side.
set -euo pipefail

if [ -n "${DOEY_RUNTIME:-}" ]; then RUNTIME_DIR="$DOEY_RUNTIME"
elif [ -n "${1:-}" ] && [ -d "${1}" ]; then RUNTIME_DIR="$1"
else RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || { sleep 5; exit 0; }
fi
if [ -f "${RUNTIME_DIR}/session.env" ]; then
  while IFS='=' read -r _key _value; do
    _value="${_value%\"}"; _value="${_value#\"}"
    case "$_key" in
      SESSION_NAME) SESSION_NAME="$_value" ;;
      PROJECT_DIR)  PROJECT_DIR="$_value" ;;
      PROJECT_NAME) PROJECT_NAME="$_value" ;;
    esac
  done < "${RUNTIME_DIR}/session.env"
fi
trap 'exit 0' ERR
source "$(dirname "$0")/common.sh" 2>/dev/null || true

# ── Reverse role guard ────────────────────────────────────────────────
# Coordinator must use taskmaster-wait.sh — refuse cleanly so the caller
# adapts instead of running the wrong wake set.
case "${DOEY_ROLE:-}" in
  "${DOEY_ROLE_ID_COORDINATOR:-coordinator}"|coordinator)
    echo "ERROR: ${DOEY_ROLE} must use taskmaster-wait.sh, not stm-wait.sh" >&2
    exit 0
    ;;
esac

# ── Pane geometry ─────────────────────────────────────────────────────
_CALLER_PANE=""
if [ -n "${TMUX_PANE:-}" ]; then
  _CALLER_PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}.#{pane_index}' 2>/dev/null) || _CALLER_PANE=""
fi
if [ -z "$_CALLER_PANE" ] && [ -n "${DOEY_WINDOW_INDEX:-}" ]; then
  _CALLER_PANE="${DOEY_WINDOW_INDEX}.${DOEY_PANE_INDEX:-0}"
fi
[ -z "$_CALLER_PANE" ] && { echo "WAKE_REASON=TIMEOUT"; exit 0; }

PANE_SAFE="${SESSION_NAME//[-:.]/_}_${_CALLER_PANE//[-:.]/_}"
_TEAM_WINDOW="${DOEY_TEAM_WINDOW:-${_CALLER_PANE%%.*}}"
_TEAM_ENV="${RUNTIME_DIR}/team_${_TEAM_WINDOW}.env"

MSG_DIR="${RUNTIME_DIR}/messages"
TRIGGER_DIR="${RUNTIME_DIR}/triggers"
STATUS_DIR="${RUNTIME_DIR}/status"
HB_DIR="${STATUS_DIR}"
mkdir -p "$TRIGGER_DIR" "$STATUS_DIR" "$HB_DIR" "$MSG_DIR" 2>/dev/null

_TIMEOUT="${DOEY_WAIT_TIMEOUT:-1800}"
# Tick: 1s in production gives crisp wake on status/trigger changes when
# inotifywait is unavailable; with inotifywait the loop almost always sleeps
# on the kernel watch and the timeout is just an upper bound.
_TICK="${DOEY_STM_WAIT_TICK:-1}"

_emit_heartbeat() {
  printf '%s %s %s\n' "$(date +%s)" "${DOEY_TASK_ID:-}" "${DOEY_PANE_INDEX:-${_CALLER_PANE##*.}}" \
    > "${HB_DIR}/${PANE_SAFE}.heartbeat.tmp" 2>/dev/null \
    && mv "${HB_DIR}/${PANE_SAFE}.heartbeat.tmp" "${HB_DIR}/${PANE_SAFE}.heartbeat" 2>/dev/null \
    || true
}

_wake() {
  echo "WAKE_REASON=$1"
  exit 0
}

# ── Worker-state tracking ─────────────────────────────────────────────
# Snapshot worker statuses at loop entry, then fire FINISHED on TRANSITION
# to terminal — this catches workers that may already be FINISHED at start.
_WORKER_PANES=""
if [ -f "$_TEAM_ENV" ]; then
  _WORKER_PANES=$(grep '^WORKER_PANES=' "$_TEAM_ENV" 2>/dev/null | sed 's/^WORKER_PANES=//;s/"//g')
fi

_initial_states=""
_load_initial_states() {
  local _wp _wp_safe _wp_st _result=";"
  for _wp in $(echo "$_WORKER_PANES" | tr ',' ' '); do
    [ -z "$_wp" ] && continue
    _wp_safe="${SESSION_NAME//[-:.]/_}_${_TEAM_WINDOW}_${_wp}"
    _wp_st=$(grep '^STATUS:' "${STATUS_DIR}/${_wp_safe}.status" 2>/dev/null | head -1 | sed 's/^STATUS:[[:space:]]*//') || _wp_st=""
    [ -z "$_wp_st" ] && _wp_st="UNKNOWN"
    _result="${_result}${_wp}=${_wp_st};"
  done
  printf '%s' "$_result"
}
_initial_states=$(_load_initial_states)

_check_workers() {
  # Returns: 0 = transition detected, 2 = all terminal, 1 = no change
  local _wp _wp_safe _wp_st _all_done=true _any_transition=false _had_workers=false
  for _wp in $(echo "$_WORKER_PANES" | tr ',' ' '); do
    [ -z "$_wp" ] && continue
    _had_workers=true
    _wp_safe="${SESSION_NAME//[-:.]/_}_${_TEAM_WINDOW}_${_wp}"
    _wp_st=$(grep '^STATUS:' "${STATUS_DIR}/${_wp_safe}.status" 2>/dev/null | head -1 | sed 's/^STATUS:[[:space:]]*//') || _wp_st=""
    [ -z "$_wp_st" ] && _wp_st="UNKNOWN"
    case "$_wp_st" in
      FINISHED|RESERVED|ERROR) ;;
      *) _all_done=false ;;
    esac
    case "$_initial_states" in
      *";${_wp}=FINISHED;"*|*";${_wp}=RESERVED;"*|*";${_wp}=ERROR;"*) ;;
      *)
        case "$_wp_st" in
          FINISHED|RESERVED|ERROR) _any_transition=true ;;
        esac
        ;;
    esac
  done
  [ "$_had_workers" = true ] || return 1
  [ "$_all_done" = true ] && return 2
  [ "$_any_transition" = true ] && return 0
  return 1
}

_check_messages() {
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    local _unread
    _unread=$(doey msg count --to "$_CALLER_PANE" --project-dir "$PROJECT_DIR" 2>/dev/null) || _unread=0
    [ "${_unread:-0}" -gt 0 ] && return 0
  fi
  local _mf _short_safe="${_CALLER_PANE//[-:.]/_}"
  for _mf in "$MSG_DIR"/${PANE_SAFE}_*.msg "$MSG_DIR"/${_short_safe}_*.msg; do
    [ -f "$_mf" ] && return 0
  done
  return 1
}

_check_trigger() {
  local _tf="${TRIGGER_DIR}/${PANE_SAFE}.trigger"
  if [ -f "$_tf" ]; then
    rm -f "$_tf" 2>/dev/null || true
    return 0
  fi
  return 1
}

# ── Pre-loop fast path ────────────────────────────────────────────────
# `_check_workers` exit codes: 0=transition, 2=all-terminal, 1=no change.
# Capture into rc so `set -e` doesn't trip on the no-change path.
_emit_heartbeat
_check_messages && _wake "MSG"
_check_trigger  && _wake "TRIGGERED"
_rc=0; _check_workers || _rc=$?
[ "$_rc" = "2" ] && _wake "ALL_DONE"

_start_ts=$(date +%s)

while :; do
  _now_ts=$(date +%s)
  _elapsed=$((_now_ts - _start_ts))
  [ "$_elapsed" -ge "$_TIMEOUT" ] && _wake "TIMEOUT"

  _emit_heartbeat

  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -qq -t "$_TICK" -e create,modify,close_write \
      "$STATUS_DIR/" \
      "$MSG_DIR/" \
      "$TRIGGER_DIR/" 2>/dev/null || true
  else
    sleep "$_TICK"
  fi

  _check_messages && _wake "MSG"
  _check_trigger  && _wake "TRIGGERED"
  _rc=0; _check_workers || _rc=$?
  [ "$_rc" = "0" ] && _wake "FINISHED"
  [ "$_rc" = "2" ] && _wake "ALL_DONE"
done
