#!/usr/bin/env bash
# SessionStart hook: injects Doey env vars into Claude Code sessions via CLAUDE_ENV_FILE.
set -euo pipefail

[ -z "${TMUX_PANE:-}" ] && exit 0
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

source "$(dirname "$0")/common.sh"
_DOEY_HOOK_NAME="on-session-start"
if type _init_debug >/dev/null 2>&1; then
  _init_debug; _debug_hook_entry
fi

SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

SESSION_NAME="" PROJECT_DIR="" PROJECT_NAME=""
while IFS='=' read -r key value; do
  value="${value%\"}"; value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    PROJECT_DIR)  PROJECT_DIR="$value" ;;
    PROJECT_NAME) PROJECT_NAME="$value" ;;
  esac
done < "$SESSION_ENV"

DOEY_LIB=""
if [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then DOEY_LIB="${PROJECT_DIR}/shell"
elif [ -f "$HOME/.local/bin/doey-task-helpers.sh" ]; then DOEY_LIB="$HOME/.local/bin"
fi

REMOTE=$(grep '^REMOTE=' "$SESSION_ENV" 2>/dev/null | head -1 | cut -d= -f2-) || true
TUNNEL_URL=""
[ -f "${RUNTIME_DIR}/tunnel.env" ] && TUNNEL_URL=$(grep '^TUNNEL_URL=' "${RUNTIME_DIR}/tunnel.env" 2>/dev/null | head -1 | cut -d= -f2-) || true

# Pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

ROLE="$DOEY_ROLE_ID_WORKER"
TEAM_WINDOW="$WINDOW_INDEX"

# Extract Core Team window from TASKMASTER_PANE
_core_team_window=""
_tm_pane_val=$(_read_team_key "$SESSION_ENV" TASKMASTER_PANE)
[ -n "$_tm_pane_val" ] && _core_team_window="${_tm_pane_val%%.*}"

if [ "$WINDOW_INDEX" = "0" ]; then
  # Dashboard window
  case "$PANE_INDEX" in
    0) ROLE="info_panel" ;;
    1) ROLE="$DOEY_ROLE_ID_BOSS" ;;
  esac
elif [ -n "$_core_team_window" ] && [ "$WINDOW_INDEX" = "$_core_team_window" ]; then
  # Core Team window
  case "$PANE_INDEX" in
    0) ROLE="$DOEY_ROLE_ID_COORDINATOR" ;;
    1) ROLE="$DOEY_ROLE_ID_TASK_REVIEWER" ;;
    2) ROLE="$DOEY_ROLE_ID_DEPLOYMENT" ;;
    3) ROLE="$DOEY_ROLE_ID_DOEY_EXPERT" ;;
  esac
else
  # Worker team window
  _team_file="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
  _team_type=""; [ -f "$_team_file" ] && _team_type=$(_read_team_key "$_team_file" TEAM_TYPE)
  if [ "$_team_type" != "$DOEY_ROLE_ID_FREELANCER" ]; then
    mgr_pane=""; [ -f "$_team_file" ] && mgr_pane=$(_read_team_key "$_team_file" MANAGER_PANE)
    [ "$PANE_INDEX" = "${mgr_pane:-0}" ] && ROLE="$DOEY_ROLE_ID_TEAM_LEAD"
  fi
fi

PROJECT_ACRONYM=$(_read_team_key "$SESSION_ENV" PROJECT_ACRONYM)
[ -z "$PROJECT_ACRONYM" ] && PROJECT_ACRONYM=$(echo "$PROJECT_NAME" | awk -F- '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-4)

case "$ROLE" in
  "$DOEY_ROLE_ID_BOSS")            PANE_ID="boss" ;;
  "$DOEY_ROLE_ID_COORDINATOR") PANE_ID="taskmaster" ;;
  info_panel)      PANE_ID="info" ;;
  "$DOEY_ROLE_ID_TASK_REVIEWER") PANE_ID="task-reviewer" ;;
  "$DOEY_ROLE_ID_DEPLOYMENT")    PANE_ID="deployment" ;;
  "$DOEY_ROLE_ID_DOEY_EXPERT")   PANE_ID="doey-expert" ;;
  "$DOEY_ROLE_ID_TEAM_LEAD")         PANE_ID="t${WINDOW_INDEX}-mgr" ;;
  "$DOEY_ROLE_ID_WORKER")
    if [ "${_team_type:-}" = "$DOEY_ROLE_ID_FREELANCER" ]; then
      PANE_ID="t${WINDOW_INDEX}-f${PANE_INDEX}"
    else
      PANE_ID="t${WINDOW_INDEX}-w${PANE_INDEX}"
    fi
    ;;
  *)               PANE_ID="t${WINDOW_INDEX}-p${PANE_INDEX}" ;;
esac
FULL_PANE_ID="${PROJECT_ACRONYM}-${PANE_ID}"

PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${PANE_INDEX}" | tr ':.-' '_')
mkdir -p "${RUNTIME_DIR}/status" "${RUNTIME_DIR}/scratchpad"
atomic_write "${RUNTIME_DIR}/status/${PANE_SAFE}.role" "$ROLE"

wt_dir=$(_read_team_key "${RUNTIME_DIR}/team_${TEAM_WINDOW}.env" WORKTREE_DIR)

_repo_path=""
[ -f "$HOME/.claude/doey/repo-path" ] && _repo_path=$(cat "$HOME/.claude/doey/repo-path")
if [ -n "$_repo_path" ] && [ -d "$_repo_path/.claude/skills" ]; then
  _skill_target="${wt_dir:-$PROJECT_DIR}"
  # Skip sync when source and target are the same directory (e.g. running inside the Doey repo)
  _src_canon="$(cd "$_repo_path" 2>/dev/null && pwd)" || _src_canon="$_repo_path"
  _tgt_canon="$(cd "$_skill_target" 2>/dev/null && pwd)" || _tgt_canon="$_skill_target"
  if [ "$_src_canon" = "$_tgt_canon" ]; then
    _repo_path=""
  fi
fi
if [ -n "$_repo_path" ] && [ -d "$_repo_path/.claude/skills" ]; then
  _skill_target="${wt_dir:-$PROJECT_DIR}"
  mkdir -p "$_skill_target/.claude/skills"
  LOCK_DIR="${RUNTIME_DIR}/.skill_sync_lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
    for _sd in "$_repo_path"/.claude/skills/doey-*/; do
      [ -d "$_sd" ] && cp -R "$_sd" "$_skill_target/.claude/skills/"
    done
    for _sd in "$_skill_target"/.claude/skills/doey-*/; do
      [ -d "$_sd" ] || continue
      [ ! -d "$_repo_path/.claude/skills/$(basename "$_sd")" ] && rm -rf "$_sd"
    done
    rmdir "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT
  else
    sleep 1
  fi
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ] && touch "$CLAUDE_ENV_FILE" 2>/dev/null; then
  cat >> "$CLAUDE_ENV_FILE" << EOF
export DOEY_RUNTIME="$RUNTIME_DIR"
export SESSION_NAME="$SESSION_NAME"
export PROJECT_DIR="$PROJECT_DIR"
export PROJECT_NAME="$PROJECT_NAME"
export DOEY_ROLE="$ROLE"
export DOEY_PANE_INDEX="$PANE_INDEX"
export DOEY_WINDOW_INDEX="$WINDOW_INDEX"
export DOEY_TEAM_WINDOW="$TEAM_WINDOW"
export DOEY_TEAM_DIR="${wt_dir:-$PROJECT_DIR}"
export DOEY_PROJECT_ACRONYM="$PROJECT_ACRONYM"
export DOEY_PANE_ID="$PANE_ID"
export DOEY_FULL_PANE_ID="$FULL_PANE_ID"
export DOEY_PANE_SAFE="$PANE_SAFE"
export DOEY_REMOTE="${REMOTE:-false}"
export DOEY_TUNNEL_URL="${TUNNEL_URL:-}"
export DOEY_LIB="${DOEY_LIB}"
export DOEY_SCRATCHPAD="${RUNTIME_DIR}/scratchpad"
EOF
fi

_team_def=$(grep '^TEAM_DEF=' "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
if [ -n "$_team_def" ]; then
  _teamdef_env="${RUNTIME_DIR}/teamdef_${_team_def}.env"
  if [ -f "$_teamdef_env" ]; then
    _team_role=$(grep "^PANE_${PANE_INDEX}_ROLE=" "$_teamdef_env" 2>/dev/null | cut -d= -f2-) || true
    _team_pane_name=$(grep "^PANE_${PANE_INDEX}_NAME=" "$_teamdef_env" 2>/dev/null | cut -d= -f2-) || true
    if [ -w "$CLAUDE_ENV_FILE" ]; then
      [ -n "$_team_role" ] && echo "DOEY_TEAM_ROLE=$_team_role" >> "$CLAUDE_ENV_FILE"
      [ -n "$_team_pane_name" ] && echo "DOEY_TEAM_PANE_NAME=$_team_pane_name" >> "$CLAUDE_ENV_FILE"
    fi
    [ -n "$_team_role" ] && [ -n "${PANE_SAFE:-}" ] && \
      echo "$_team_role" > "${RUNTIME_DIR}/status/${PANE_SAFE}.team_role"
  fi
fi

_TITLE=""
case "$ROLE" in
  "$DOEY_ROLE_ID_BOSS")            _TITLE="${PROJECT_NAME} ${DOEY_ROLE_BOSS}" ;;
  "$DOEY_ROLE_ID_TEAM_LEAD")         _TITLE="${PROJECT_NAME} T${WINDOW_INDEX} ${DOEY_ROLE_TEAM_LEAD}" ;;
  "$DOEY_ROLE_ID_COORDINATOR") _TITLE="${PROJECT_NAME} ${DOEY_ROLE_COORDINATOR}" ;;
  "$DOEY_ROLE_ID_TASK_REVIEWER") _TITLE="${PROJECT_NAME} ${DOEY_ROLE_TASK_REVIEWER}" ;;
  "$DOEY_ROLE_ID_DEPLOYMENT")    _TITLE="${PROJECT_NAME} ${DOEY_ROLE_DEPLOYMENT}" ;;
  "$DOEY_ROLE_ID_DOEY_EXPERT")   _TITLE="${PROJECT_NAME} ${DOEY_ROLE_DOEY_EXPERT}" ;;
  "$DOEY_ROLE_ID_WORKER")          _TITLE=$([ "${_team_type:-}" = "$DOEY_ROLE_ID_FREELANCER" ] && echo "$DOEY_ROLE_FREELANCER" || echo "$DOEY_ROLE_WORKER") ;;
esac
[ -n "$_TITLE" ] && tmux select-pane -t "${TMUX_PANE}" -T "${FULL_PANE_ID} | ${_TITLE}" 2>/dev/null || true

type _debug_log >/dev/null 2>&1 && \
  _debug_log lifecycle "session_start" "role=${ROLE:-unknown}" "team_window=${WINDOW_INDEX:-0}" "project=${PROJECT_NAME:-unknown}"

# Refresh agent registry in SQLite (fast, idempotent)
# Only run for first pane in session to avoid redundant work
if [ "${PANE_INDEX:-0}" = "0" ] && [ "${WINDOW_INDEX:-0}" = "0" ]; then
  if command -v doey-ctl >/dev/null 2>&1 && [ -n "${PROJECT_DIR:-}" ]; then
    doey-ctl migrate --project-dir "$PROJECT_DIR" --runtime "${RUNTIME_DIR:-}" 2>/dev/null &
  fi
fi

exit 0
