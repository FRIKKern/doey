#!/usr/bin/env bash
# shellcheck shell=bash
# ──────────────────────────────────────────────────────────────────────
# doey-stats-emit.sh — standalone CLI wrapper around doey_stats_emit
#
# Usage:
#   doey-stats-emit.sh <category> <type> [key=val ...]
#
# Contract:
#   - Silent-fail on every error. Always returns 0.
#   - Respects DOEY_STATS=0 (kill switch).
#   - Sources shell/doey-stats.sh via fallback resolution so it works
#     from the repo checkout AND from ~/.local/bin/.
#   - When invoked for `session session_start …`, also handles a
#     first-run install_run sentinel emit (once per runtime dir).
#
# Called from:
#   - .claude/hooks/on-session-start.sh   (one-line fire-and-forget call)
#   - shell/doey.sh entry points          (session_launched mode=…)
#   - install.sh                          (install_run once on install)
# ──────────────────────────────────────────────────────────────────────

set -u

# ── locate library ────────────────────────────────────────────────────
_doey_stats_lib=""
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _self_dir=""

# 1) Same directory as this wrapper (works both in repo and ~/.local/bin)
if [ -n "$_self_dir" ] && [ -f "${_self_dir}/doey-stats.sh" ]; then
  _doey_stats_lib="${_self_dir}/doey-stats.sh"
fi

# 2) Installed copy
if [ -z "$_doey_stats_lib" ] && [ -f "$HOME/.local/bin/doey-stats.sh" ]; then
  _doey_stats_lib="$HOME/.local/bin/doey-stats.sh"
fi

# 3) Repo path saved by install.sh
if [ -z "$_doey_stats_lib" ] && [ -f "$HOME/.claude/doey/repo-path" ]; then
  _doey_repo=""
  _doey_repo=$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null) || _doey_repo=""
  if [ -n "$_doey_repo" ] && [ -f "${_doey_repo}/shell/doey-stats.sh" ]; then
    _doey_stats_lib="${_doey_repo}/shell/doey-stats.sh"
  fi
  unset _doey_repo
fi
unset _self_dir

if [ -z "$_doey_stats_lib" ]; then
  exit 0
fi

# shellcheck disable=SC1090
. "$_doey_stats_lib" 2>/dev/null || exit 0
unset _doey_stats_lib

# ── install_run sentinel (once per runtime dir) ───────────────────────
# Only fires on the first session_start emit after a runtime dir is
# created. Lets us count unique install/first-launch events without a
# dedicated code path in install.sh.
_doey_stats_install_run_sentinel() {
  [ -z "${DOEY_RUNTIME:-}" ] && return 0
  local sentinel="${DOEY_RUNTIME%/}/.install-seen"
  [ -f "$sentinel" ] && return 0
  mkdir -p "${DOEY_RUNTIME%/}" 2>/dev/null || return 0
  : > "$sentinel" 2>/dev/null || return 0

  local ver=""
  if [ -n "${DOEY_VERSION:-}" ]; then
    ver="$DOEY_VERSION"
  elif [ -f "$HOME/.claude/doey/version" ]; then
    ver=$(cat "$HOME/.claude/doey/version" 2>/dev/null) || ver=""
  fi
  local origin="${DOEY_INSTALL_ORIGIN:-local}"

  doey_stats_emit skill install_run "version=${ver}" "origin=${origin}" 2>/dev/null || true
}

# ── dispatch ──────────────────────────────────────────────────────────
if [ "${DOEY_STATS:-}" = "0" ]; then
  exit 0
fi

if [ $# -lt 2 ]; then
  exit 0
fi

_cat="$1"
_type="$2"
shift 2 2>/dev/null || true

doey_stats_emit "$_cat" "$_type" "$@" 2>/dev/null || true

# Fire install_run sentinel ONLY after a session_start to keep the
# fast-path cheap for every other event type.
if [ "$_cat" = "session" ] && [ "$_type" = "session_start" ]; then
  _doey_stats_install_run_sentinel 2>/dev/null || true
fi

exit 0
