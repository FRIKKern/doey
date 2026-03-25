#!/usr/bin/env bash
# SessionStart hook: injects Doey env vars into Claude Code sessions via CLAUDE_ENV_FILE.
set -euo pipefail

[ -z "${TMUX_PANE:-}" ] && exit 0
[ -z "${CLAUDE_ENV_FILE:-}" ] && exit 0

RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
[ -z "$RUNTIME_DIR" ] && exit 0

# Debug: source common.sh functions for _init_debug/_debug_hook_entry/_debug_log
# (common.sh guards itself — safe to source even though this hook has its own init)
source "$(dirname "$0")/common.sh"
if type _init_debug >/dev/null 2>&1; then
  _init_debug
  _DOEY_HOOK_NAME="on-session-start"
  _debug_hook_entry
fi

SESSION_ENV="${RUNTIME_DIR}/session.env"
[ -f "$SESSION_ENV" ] || exit 0

# Read unquoted value from env file: _env_val file key
_env_val() { local v; v=$(grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-) || true; v="${v%\"}"; echo "${v#\"}"; }

# Single-pass read of session.env (avoid repeated grep subshells)
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
  if [ "0.${PANE_INDEX}" = "${sm_val:-0.1}" ]; then
    ROLE="session_manager"
  elif [ "$PANE_INDEX" = "0" ]; then
    ROLE="info_panel"
  else
    for tf in "${RUNTIME_DIR}"/team_*.env; do
      [ -f "$tf" ] || continue
      wd_pane=$(_env_val "$tf" WATCHDOG_PANE)
      if [ "$wd_pane" = "0.${PANE_INDEX}" ]; then
        ROLE="watchdog"
        fn="${tf##*/}"
        TEAM_WINDOW="${fn#team_}"
        TEAM_WINDOW="${TEAM_WINDOW%.env}"
        break
      fi
    done
  fi
else
  _team_type=$(_env_val "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" TEAM_TYPE)
  if [ "$_team_type" = "freelancer" ]; then
    # Freelancer: check for role override (e.g., git_agent dispatched here)
    _ro_key=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${PANE_INDEX}" | tr ':.' '_')
    if [ -f "${RUNTIME_DIR}/status/${_ro_key}.role_override" ]; then
      ROLE=$(cat "${RUNTIME_DIR}/status/${_ro_key}.role_override")
    else
      ROLE="worker"
    fi
  else
    mgr_pane=$(_env_val "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" MANAGER_PANE)
    [ "$PANE_INDEX" = "${mgr_pane:-0}" ] && ROLE="manager"
  fi
fi

# Compute pane identifiers
PROJECT_ACRONYM=$(_env_val "$SESSION_ENV" PROJECT_ACRONYM)
[ -z "$PROJECT_ACRONYM" ] && PROJECT_ACRONYM=$(echo "$PROJECT_NAME" | awk -F- '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-4)

_is_freelancer_team="false"
[ "${_team_type:-}" = "freelancer" ] && _is_freelancer_team="true"

case "$ROLE" in
  session_manager) PANE_ID="sm" ;;
  info_panel)      PANE_ID="info" ;;
  manager)         PANE_ID="t${WINDOW_INDEX}-mgr" ;;
  watchdog)        PANE_ID="t${TEAM_WINDOW}-wd" ;;
  git_agent) PANE_ID="t${WINDOW_INDEX}-git" ;;
  worker)
    if [ "$_is_freelancer_team" = "true" ]; then
      PANE_ID="t${WINDOW_INDEX}-f${PANE_INDEX}"
    else
      PANE_ID="t${WINDOW_INDEX}-w${PANE_INDEX}"
    fi
    ;;
  *)               PANE_ID="t${WINDOW_INDEX}-p${PANE_INDEX}" ;;
esac
FULL_PANE_ID="${PROJECT_ACRONYM}-${PANE_ID}"

# Cache role per-pane for fast lookup by subsequent hooks
# NOTE: tmux set-environment is session-wide, so the last pane to start would
# overwrite everyone's role. Use per-pane files instead.
PANE_SAFE=$(echo "${SESSION_NAME}:${WINDOW_INDEX}.${PANE_INDEX}" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"
atomic_write "${RUNTIME_DIR}/status/${PANE_SAFE}.role" "$ROLE"

wt_dir=$(_env_val "${RUNTIME_DIR}/team_${TEAM_WINDOW}.env" WORKTREE_DIR)

# Sync doey skills from source repo into the working directory
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

# Guard env file writes — during compact, CLAUDE_ENV_FILE may be stale
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

# Team definition role injection
if [ -n "${RUNTIME_DIR:-}" ]; then
  _team_def=""
  _team_def=$(grep '^TEAM_DEF=' "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
  if [ -n "$_team_def" ]; then
    _teamdef_env="${RUNTIME_DIR}/teamdef_${_team_def}.env"
    if [ -f "$_teamdef_env" ]; then
      _team_role=""
      _team_pane_name=""
      _team_role=$(grep "^PANE_${PANE_INDEX}_ROLE=" "$_teamdef_env" 2>/dev/null | cut -d= -f2-) || true
      _team_pane_name=$(grep "^PANE_${PANE_INDEX}_NAME=" "$_teamdef_env" 2>/dev/null | cut -d= -f2-) || true
      if [ -n "$_team_role" ] && [ -w "$CLAUDE_ENV_FILE" ]; then
        echo "DOEY_TEAM_ROLE=$_team_role" >> "$CLAUDE_ENV_FILE"
      fi
      if [ -n "$_team_pane_name" ] && [ -w "$CLAUDE_ENV_FILE" ]; then
        echo "DOEY_TEAM_PANE_NAME=$_team_pane_name" >> "$CLAUDE_ENV_FILE"
      fi
      # Write team role to per-pane file so hooks can read without env vars
      if [ -n "$_team_role" ] && [ -n "${PANE_SAFE:-}" ]; then
        echo "$_team_role" > "${RUNTIME_DIR}/status/${PANE_SAFE}.team_role"
      fi
    fi
  fi
fi

# Pane title
_TITLE=""
case "$ROLE" in
  watchdog)        _TITLE="${PROJECT_NAME} T${TEAM_WINDOW} WD" ;;
  manager)         _TITLE="${PROJECT_NAME} T${WINDOW_INDEX} Mgr" ;;
  session_manager) _TITLE="${PROJECT_NAME} SM" ;;
  git_agent)       _TITLE="Git Agent" ;;
  worker)
    if [ "$_is_freelancer_team" = "true" ]; then
      _TITLE="Freelancer"
    else
      _TITLE="Worker"
    fi
    ;;
esac
[ -n "$_TITLE" ] && tmux select-pane -t "${TMUX_PANE}" -T "${FULL_PANE_ID} | ${_TITLE}"

type _debug_log >/dev/null 2>&1 && \
  _debug_log lifecycle "session_start" "role=${ROLE:-unknown}" "team_window=${WINDOW_INDEX:-0}" "project=${PROJECT_NAME:-unknown}"
