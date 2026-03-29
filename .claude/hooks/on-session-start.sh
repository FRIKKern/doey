#!/usr/bin/env bash
# SessionStart hook: injects Doey env vars into Claude Code sessions via CLAUDE_ENV_FILE.
set -euo pipefail

[ -z "${TMUX_PANE:-}" ] && exit 0
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

source "$(dirname "$0")/common.sh"
if type _init_debug >/dev/null 2>&1; then
  _init_debug
  _DOEY_HOOK_NAME="on-session-start"
  _debug_hook_entry
fi

SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

_env_val() { local v; v=$(grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-) || true; v="${v%\"}"; echo "${v#\"}"; }

SESSION_NAME="" PROJECT_DIR="" PROJECT_NAME=""
while IFS='=' read -r key value; do
  value="${value%\"}" && value="${value#\"}"
  case "$key" in
    SESSION_NAME) SESSION_NAME="$value" ;;
    PROJECT_DIR)  PROJECT_DIR="$value" ;;
    PROJECT_NAME) PROJECT_NAME="$value" ;;
  esac
done < "$SESSION_ENV"

# Pane identity
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
PANE_INDEX="${PANE##*.}"
_WP="${PANE#*:}"
WINDOW_INDEX="${_WP%.*}"

# Role detection
ROLE="worker"
TEAM_WINDOW="$WINDOW_INDEX"

if [ "$WINDOW_INDEX" = "0" ]; then
  sm_val=$(_env_val "$SESSION_ENV" SM_PANE)
  if [ "$PANE_INDEX" = "1" ]; then
    ROLE="boss"
  elif [ "0.${PANE_INDEX}" = "${sm_val:-0.2}" ]; then
    ROLE="session_manager"
  elif [ "$PANE_INDEX" = "0" ]; then
    ROLE="info_panel"
  fi
else
  _team_type=$(_env_val "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" TEAM_TYPE)
  if [ "$_team_type" = "freelancer" ]; then
    ROLE="worker"
  else
    mgr_pane=$(_env_val "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
    [ "$PANE_INDEX" = "${mgr_pane:-0}" ] && ROLE="manager"
  fi
fi

# Compute pane identifiers
PROJECT_ACRONYM=$(_env_val "$SESSION_ENV" PROJECT_ACRONYM)
[ -z "$PROJECT_ACRONYM" ] && PROJECT_ACRONYM=$(echo "$PROJECT_NAME" | awk -F- '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-4)

case "$ROLE" in
  boss)            PANE_ID="boss" ;;
  session_manager) PANE_ID="sm" ;;
  info_panel)      PANE_ID="info" ;;
  manager)         PANE_ID="t${WINDOW_INDEX}-mgr" ;;
  worker)
    if [ "${_team_type:-}" = "freelancer" ]; then
      PANE_ID="t${WINDOW_INDEX}-f${PANE_INDEX}"
    else
      PANE_ID="t${WINDOW_INDEX}-w${PANE_INDEX}"
    fi
    ;;
  *)               PANE_ID="t${WINDOW_INDEX}-p${PANE_INDEX}" ;;
esac
FULL_PANE_ID="${PROJECT_ACRONYM}-${PANE_ID}"

PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${PANE_INDEX}" | tr ':.-' '_')
mkdir -p "${RUNTIME_DIR}/status"
atomic_write "${RUNTIME_DIR}/status/${PANE_SAFE}.role" "$ROLE"

wt_dir=$(_env_val "${RUNTIME_DIR}/team_${TEAM_WINDOW}.env" WORKTREE_DIR)

_repo_path=""
[ -f "$HOME/.claude/doey/repo-path" ] && _repo_path=$(cat "$HOME/.claude/doey/repo-path")
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
  boss)            _TITLE="${PROJECT_NAME} Boss" ;;
  manager)         _TITLE="${PROJECT_NAME} T${WINDOW_INDEX} Mgr" ;;
  session_manager) _TITLE="${PROJECT_NAME} SM" ;;
  worker)          _TITLE=$([ "${_team_type:-}" = "freelancer" ] && echo "Freelancer" || echo "Worker") ;;
esac
[ -n "$_TITLE" ] && tmux select-pane -t "${TMUX_PANE}" -T "${FULL_PANE_ID} | ${_TITLE}"

type _debug_log >/dev/null 2>&1 && \
  _debug_log lifecycle "session_start" "role=${ROLE:-unknown}" "team_window=${WINDOW_INDEX:-0}" "project=${PROJECT_NAME:-unknown}"
