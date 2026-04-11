#!/usr/bin/env bash
# shellcheck shell=bash
# ──────────────────────────────────────────────────────────────────────
# doey-stats.sh — Bash 3.2-compatible stats emitter wrapper
#
# Exports:
#   doey_stats_emit <category> <type> [key=val ...]
#   doey_stats_session_id           — echo/cache the per-session UUID
#   doey_stats_canonical_project    — echo canonical absolute project path
#
# Design:
#   - Shells to `doey-ctl stats emit` in a backgrounded subshell; never
#     blocks the caller. Silent-fail everywhere.
#   - Respects DOEY_STATS=0 (kill switch) — early return.
#   - Drops unknown allow-list keys via a portable `case` statement that
#     mirrors shell/doey-stats-allowlist.txt (kept in sync with
#     tui/cmd/doey-ctl/doey-stats-allowlist.txt).
#   - Derives session_id from $DOEY_SESSION_ID, or lazily generates one
#     under ${DOEY_RUNTIME%/}/session_id with a first-writer-wins
#     atomic `mv -n`. Empty session_id → skip emit.
#   - Bash 3.2 + `set -u` safe: no associative arrays, no mapfile, no
#     %(%s)T, no namerefs; empty-array expansions use the +x guard.
# ──────────────────────────────────────────────────────────────────────

# Idempotent guard
if [ -n "${_DOEY_STATS_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_DOEY_STATS_LOADED=1

# ── session_id ────────────────────────────────────────────────────────
doey_stats_session_id() {
  if [ -n "${DOEY_SESSION_ID:-}" ]; then
    printf '%s' "$DOEY_SESSION_ID"
    return 0
  fi
  [ -z "${DOEY_RUNTIME:-}" ] && return 0
  local sid_file="${DOEY_RUNTIME%/}/session_id"
  if [ ! -f "$sid_file" ]; then
    mkdir -p "${DOEY_RUNTIME%/}" 2>/dev/null || return 0
    local tmp="${sid_file}.tmp.$$"
    local id=""
    id=$(uuidgen 2>/dev/null) || id=""
    if [ -z "$id" ]; then
      id="s$(date +%s)-$$-${RANDOM:-0}"
    fi
    printf '%s\n' "$id" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
    mv -n "$tmp" "$sid_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  [ -r "$sid_file" ] || return 0
  local first=""
  IFS= read -r first < "$sid_file" 2>/dev/null || first=""
  [ -n "$first" ] && printf '%s' "$first"
}

# ── canonical project path ────────────────────────────────────────────
doey_stats_canonical_project() {
  local src="${DOEY_PROJECT_DIR:-${DOEY_TEAM_DIR:-}}"
  if [ -z "$src" ]; then
    src=$(git rev-parse --show-toplevel 2>/dev/null) || src=""
  fi
  [ -z "$src" ] && src="$(pwd)"
  local out=""
  if command -v realpath >/dev/null 2>&1; then
    out=$(realpath -- "$src" 2>/dev/null) || out=""
  fi
  if [ -z "$out" ] && command -v python3 >/dev/null 2>&1; then
    out=$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$src" 2>/dev/null) || out=""
  fi
  [ -z "$out" ] && out="$src"
  case "$out" in
    */) out="${out%/}" ;;
  esac
  printf '%s' "$out"
}

# ── allow-list filter ─────────────────────────────────────────────────
# MUST be kept in sync with shell/doey-stats-allowlist.txt and
# tui/cmd/doey-ctl/doey-stats-allowlist.txt.
_doey_stats_key_allowed() {
  case "$1" in
    role|window|pane|mode|status|task_id|files_changed|tool_count|\
version|origin|cmd|dep|mapped_cmd|team|team_type|worker_count|\
reason|duration_ms|exit_code|retry)
      return 0 ;;
  esac
  return 1
}

# ── emit ──────────────────────────────────────────────────────────────
# Usage: doey_stats_emit <category> <type> [key=val ...]
# Silent-fail on every error. Returns 0 always (best-effort).
doey_stats_emit() {
  [ "${DOEY_STATS:-}" = "0" ] && return 0
  command -v doey-ctl >/dev/null 2>&1 || return 0

  local category="${1:-}"
  local etype="${2:-}"
  if [ -z "$category" ] || [ -z "$etype" ]; then
    return 0
  fi
  shift 2 2>/dev/null || true

  case "$category" in
    session|task|worker|skill) ;;
    *) return 0 ;;
  esac

  local sid=""
  sid=$(doey_stats_session_id 2>/dev/null) || sid=""
  [ -z "$sid" ] && return 0

  local proj=""
  proj=$(doey_stats_canonical_project 2>/dev/null) || proj=""

  # Build positional data-flag list in a bash 3.2 + set-u safe way.
  # We use a single string accumulator with a separator because empty
  # arrays under `set -u` require awkward guards in bash 3.2.
  local data_args=""
  local kv k v esc
  for kv in "$@"; do
    case "$kv" in
      *=*)
        k="${kv%%=*}"
        v="${kv#*=}"
        if _doey_stats_key_allowed "$k"; then
          # Guard against embedded single quotes in v (privacy test
          # bans shell-substitution values anyway, but be defensive).
          esc=$(printf '%s' "$v" | sed "s/'/'\\\\''/g")
          data_args="${data_args} --data '${k}=${esc}'"
        fi
        ;;
    esac
  done

  # Fire-and-forget. `eval` is needed because data_args is a
  # whitespace-concatenated string with embedded single quotes; the
  # outer subshell + backgrounding ensures the parent never waits.
  (
    eval "doey-ctl stats emit \
      --category '$category' \
      --type '$etype' \
      --session-id '$sid' \
      --project '$proj' \
      --project-dir '$proj' \
      ${data_args} \
      >/dev/null 2>&1 &"
  ) 2>/dev/null

  return 0
}
