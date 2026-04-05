#!/usr/bin/env bash
# doey-helpers.sh — Small pure-utility functions shared across Doey scripts.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_helpers_sourced:-}" = "1" ] && return 0
__doey_helpers_sourced=1

# ── Config Loading ───────────────────────────────────────────────────
# Load user config (optional), then apply defaults for any unset variables.
# Hierarchy: project .doey/config.sh > global ~/.config/doey/config.sh > defaults
_doey_load_config() {
  local global_config="${DOEY_CONFIG:-${HOME}/.config/doey/config.sh}"
  # shellcheck source=/dev/null
  [ -f "$global_config" ] && source "$global_config"
  # Project config — walk up from cwd to find .doey/config.sh
  local search_dir
  search_dir="$(pwd)"
  while [ "$search_dir" != "/" ]; do
    if [ -f "${search_dir}/.doey/config.sh" ]; then
      # shellcheck source=/dev/null
      source "${search_dir}/.doey/config.sh"
      break
    fi
    search_dir="$(dirname "$search_dir")"
  done
}

# ── Env / Config Readers ─────────────────────────────────────────────

# Read a key=value from an env file, stripping quotes.  Pure bash — no forks.
# Usage: _env_val <file> <KEY> [default]
_env_val() {
  local _ev_file="$1" _ev_key="$2" _ev_default="${3:-}" _ev_line
  if [ ! -f "$_ev_file" ]; then
    [ -n "$_ev_default" ] && printf '%s\n' "$_ev_default"
    return 0
  fi
  while IFS= read -r _ev_line || [ -n "$_ev_line" ]; do
    case "$_ev_line" in
      "${_ev_key}="*)
        _ev_line="${_ev_line#*=}"
        _ev_line="${_ev_line//\"/}"
        printf '%s\n' "$_ev_line"
        return 0
        ;;
    esac
  done < "$_ev_file"
  [ -n "$_ev_default" ] && printf '%s\n' "$_ev_default"
  return 0
}

# Read per-team config: _read_team_config <team_num> <property> <default>
# Reads DOEY_TEAM_<N>_<PROPERTY>, falls back to <default>
_read_team_config() {
  local n="$1" prop="$2" default="$3"
  eval "echo \"\${DOEY_TEAM_${n}_${prop}:-${default}}\""
}

# ── Project / Session Resolution ─────────────────────────────────────

resolve_repo_dir() {
  if [ -f "$HOME/.claude/doey/repo-path" ]; then
    cat "$HOME/.claude/doey/repo-path"
  else
    (cd "$SCRIPT_DIR/.." && pwd)
  fi
}

project_name_from_dir() {
  local raw
  if [ -f "$1/.doey-name" ]; then raw=$(head -1 "$1/.doey-name"); else raw="${1##*/}"; fi
  echo "$raw" | tr '[:upper:] .' '[:lower:]--' | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//;s/-$//'
}

# Generate a short project acronym from a hyphenated name (max 4 chars).
# e.g. "claude-code-tmux-team" → "cctm", "gyldendal-no" → "gn", "my-app" → "ma"
project_acronym() {
  local name="$1" acr="" seg
  local old_ifs="$IFS"; IFS='-'
  for seg in $name; do
    [ -n "$seg" ] && acr="${acr}$(printf '%s' "$seg" | cut -c1)"
  done
  IFS="$old_ifs"
  printf '%s' "$acr" | cut -c1-4
}

find_project() {
  local dir="$1"
  grep -m1 ":${dir}$" "$PROJECTS_FILE" 2>/dev/null | cut -d: -f1 || true
}

# < /dev/null prevents tmux from consuming stdin in read loops
session_exists() {
  tmux has-session -t "$1" < /dev/null 2>/dev/null
}

read_team_windows() {
  _env_val "$1/session.env" TEAM_WINDOWS
}
