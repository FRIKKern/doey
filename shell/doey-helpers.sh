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

# Fuzzy project lookup by name query. Returns "name:path" on stdout, exit 0 on match.
# Search order: exact → prefix → substring → multi-word fuzzy.
find_project_by_name() {
  local query="$1"
  local pfile="$PROJECTS_FILE"
  [ -f "$pfile" ] || return 1

  # Normalize: lowercase, spaces to hyphens
  local normalized
  normalized="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
  [ -z "$normalized" ] && return 1

  local match=""

  # 1. Exact name match (case-insensitive)
  match="$(grep -i "^${normalized}:" "$pfile" | head -1)" || true
  if [ -n "$match" ]; then printf '%s' "$match"; return 0; fi

  # 2. Prefix match
  match="$(grep -i "^${normalized}" "$pfile" | head -1)" || true
  if [ -n "$match" ]; then printf '%s' "$match"; return 0; fi

  # 3. Substring match on name field
  match="$(awk -F: -v q="$normalized" 'tolower($1) ~ q {print; exit}' "$pfile")" || true
  if [ -n "$match" ]; then printf '%s' "$match"; return 0; fi

  # 4. Multi-word fuzzy: all hyphen-delimited words must appear in project name
  local words=""
  local old_ifs="$IFS"
  IFS='-'
  # shellcheck disable=SC2086
  set -- $normalized
  IFS="$old_ifs"
  local _fpbn_all_matched _fpbn_word _fpbn_pname _fpbn_line
  while IFS= read -r _fpbn_line || [ -n "$_fpbn_line" ]; do
    [ -z "$_fpbn_line" ] && continue
    _fpbn_pname="$(printf '%s' "$_fpbn_line" | cut -d: -f1 | tr '[:upper:]' '[:lower:]')"
    _fpbn_all_matched=true
    for _fpbn_word in "$@"; do
      case "$_fpbn_pname" in
        *"$_fpbn_word"*) ;;
        *) _fpbn_all_matched=false; break ;;
      esac
    done
    if [ "$_fpbn_all_matched" = true ]; then
      printf '%s' "$_fpbn_line"
      return 0
    fi
  done < "$pfile"

  return 1
}

# < /dev/null prevents tmux from consuming stdin in read loops
session_exists() {
  tmux has-session -t "$1" < /dev/null 2>/dev/null
}

read_team_windows() {
  _env_val "$1/session.env" TEAM_WINDOWS
}

# ── Team State Accessors ────────────────────────────────────────────
# Read a single key from a team env file.
# Usage: val=$(team_state_get <runtime_dir> <window_index> <KEY> [default])
team_state_get() {
  _env_val "${1}/team_${2}.env" "$3" "${4:-}"
}

# Atomically update a single key in a team env file.
# Preserves all other keys.  Creates the key if not found.
# Usage: team_state_set <runtime_dir> <window_index> <KEY> <VALUE>
team_state_set() {
  local _tss_file="${1}/team_${2}.env"
  local _tss_key="$3" _tss_val="$4"
  local _tss_tmp="${_tss_file}.tmp.$$"
  local _tss_found=0 _tss_line
  {
    if [ -f "$_tss_file" ]; then
      while IFS= read -r _tss_line || [ -n "$_tss_line" ]; do
        case "$_tss_line" in
          "${_tss_key}="*)
            printf '%s="%s"\n' "$_tss_key" "$_tss_val"
            _tss_found=1
            ;;
          *) printf '%s\n' "$_tss_line" ;;
        esac
      done < "$_tss_file"
    fi
    [ "$_tss_found" -eq 0 ] && printf '%s="%s"\n' "$_tss_key" "$_tss_val"
  } > "$_tss_tmp"
  mv "$_tss_tmp" "$_tss_file"
}

# ── Config Reload ───────────────────────────────────────────────────
# Reload configuration after changing to a project directory.
# Called in launch functions after cd'ing to the project dir so that
# project-local .doey/config.sh overrides take effect.
#
# Idempotent — safe to call multiple times.  Config files are sourced
# in hierarchy order (global → project-local); last assignment wins.
#
# Before: config reflects only previously-loaded sources
# After:  config includes project-local overrides from cwd's .doey/config.sh
_doey_reload_config() {
  _doey_load_config
}
