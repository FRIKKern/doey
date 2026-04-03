#!/usr/bin/env bash
set -uo pipefail
# No -e: tmux callbacks must not crash on transient failures

# Source role definitions
_ROLES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=doey-roles.sh
source "${_ROLES_DIR}/doey-roles.sh" 2>/dev/null || true

PANE_REF="${1:-}"
[ -z "$PANE_REF" ] && exit 0

TITLE=$(tmux display-message -t "$PANE_REF" -p '#{pane_title}' 2>/dev/null) || TITLE=""
FULL_PANE_ID=$(tmux display-message -t "$PANE_REF" -p '#{DOEY_FULL_PANE_ID}' 2>/dev/null) || true
[ -z "$FULL_PANE_ID" ] && FULL_PANE_ID=$(tmux show-environment -t "$PANE_REF" DOEY_FULL_PANE_ID 2>/dev/null | cut -d= -f2-) || true

_prefix_id() {
  local parts=""; [ -n "$FULL_PANE_ID" ] && parts="$FULL_PANE_ID"
  [ -n "$1" ] && parts="${parts:+$parts | }$1"
  echo "${parts:-}"
}

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
[ -z "$RUNTIME_DIR" ] && { _prefix_id "$TITLE"; exit 0; }

WIN_PANE="${PANE_REF##*:}"
WINDOW_IDX="${WIN_PANE%%.*}"
PANE_IDX="${WIN_PANE#*.}"
PANE_SAFE="${PANE_REF//[-:.]/_}"

env_val() {
  local v
  v=$(grep "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2-) || true
  v="${v#\"}"; echo "${v%\"}"
}

# Window 0: identify Taskmaster panes
if [ "$WINDOW_IDX" = "0" ]; then
  SESSION_ENV="${RUNTIME_DIR}/session.env"
  PROJ_NAME=""
  if [ -f "$SESSION_ENV" ]; then
    PROJ_NAME=$(env_val "$SESSION_ENV" PROJECT_NAME)
    TASKMASTER_PANE=$(env_val "$SESSION_ENV" TASKMASTER_PANE)
    [ -n "$TASKMASTER_PANE" ] && [ "0.${PANE_IDX}" = "$TASKMASTER_PANE" ] && { _prefix_id "${PROJ_NAME} ${DOEY_ROLE_COORDINATOR}"; exit 0; }
  fi

  for team_file in "${RUNTIME_DIR}"/team_*.env; do
    [ -f "$team_file" ] || continue
    WDG_PANE=$(env_val "$team_file" WATCHDOG_PANE)
    if [ -n "$WDG_PANE" ] && [ "0.${PANE_IDX}" = "$WDG_PANE" ]; then
      _prefix_id "${PROJ_NAME} T$(env_val "$team_file" WINDOW_INDEX) WD"; exit 0
    fi
  done

  _prefix_id "$TITLE"; exit 0
fi

[ -f "${RUNTIME_DIR}/status/${PANE_SAFE}.reserved" ] && { _prefix_id "${TITLE} 🔒"; exit 0; }

# Extract task label from status file for BUSY/WORKING panes
_task_label=""
_status_file="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
if [ -f "$_status_file" ]; then
  _pane_status=$(grep '^STATUS: ' "$_status_file" 2>/dev/null | head -1 | sed 's/^STATUS: *//')
  case "$_pane_status" in BUSY|WORKING)
    _task_field=$(grep '^TASK: ' "$_status_file" 2>/dev/null | head -1 | sed 's/^TASK: *//')
    _task_id=$(echo "$_task_field" | sed -n 's/.*#\([0-9][0-9]*\).*/\1/p' | head -1)
    if [ -n "$_task_id" ]; then
      _task_title=""
      _pbs_proj_dir=$(env_val "${RUNTIME_DIR}/session.env" PROJECT_DIR 2>/dev/null) || _pbs_proj_dir=""
      # DB-first: try doey-ctl
      if [ -n "$_pbs_proj_dir" ]; then
        _task_title=$(doey-ctl task get --id "$_task_id" --project-dir "$_pbs_proj_dir" 2>/dev/null | sed -n 's/^Title:[[:space:]]*//p')
      fi
      # File fallback
      if [ -z "$_task_title" ]; then
        for _td in "$RUNTIME_DIR" "${_pbs_proj_dir}/.doey/tasks"; do
          _tf="${_td}/tasks/${_task_id}.task"; [ -f "$_tf" ] || _tf="${_td}/${_task_id}.task"
          [ -f "$_tf" ] && { _task_title=$(grep '^TASK_TITLE=' "$_tf" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//;s/"$//'); break; }
        done
      fi
      if [ -n "$_task_title" ]; then
        _short_title=$(printf '%.20s' "$_task_title")
        [ ${#_task_title} -gt 20 ] && _short_title="${_short_title}.."
        _task_label="#${_task_id} ${_short_title}"
      else _task_label="#${_task_id}"; fi
    fi
  ;; esac
fi

[ -n "$_task_label" ] && _prefix_id "${TITLE} [${_task_label}]" || _prefix_id "$TITLE"
