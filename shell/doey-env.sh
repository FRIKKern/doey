#!/usr/bin/env bash
# doey-env.sh — resolve session env for bash-tool / out-of-tmux contexts.
#
# Agents call: eval "$(doey env)"
# Output: `export KEY=VALUE` lines suitable for `eval`.
#
# Resolution order for RUNTIME_DIR:
#   1. $DOEY_RUNTIME (already inherited)
#   2. tmux show-environment DOEY_RUNTIME (if inside tmux)
#   3. walk CWD up to the nearest .git, then /tmp/doey/<project_name>
#
# Exit 1 silently when no session env can be located — callers can
# append `|| true` without surfacing noise.

set -euo pipefail

_doey_env_slug() {
  printf '%s' "$1" | tr '[:upper:] .' '[:lower:]--' \
    | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//;s/-$//'
}

_doey_env_resolve_runtime() {
  if [ -n "${DOEY_RUNTIME:-}" ] && [ -d "$DOEY_RUNTIME" ]; then
    printf '%s\n' "$DOEY_RUNTIME"
    return 0
  fi

  if [ -n "${TMUX:-}" ]; then
    local rt
    rt="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)"
    if [ -n "$rt" ] && [ -d "$rt" ]; then
      printf '%s\n' "$rt"
      return 0
    fi
  fi

  local dir="${PWD:-$(pwd)}"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -e "$dir/.git" ]; then
      local name slug candidate
      if [ -f "$dir/.doey-name" ]; then
        name="$(head -1 "$dir/.doey-name")"
      else
        name="${dir##*/}"
      fi
      slug="$(_doey_env_slug "$name")"
      [ -z "$slug" ] && return 1
      candidate="/tmp/doey/${slug}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      return 1
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

doey_env_cmd() {
  local rt sfile
  rt="$(_doey_env_resolve_runtime)" || return 1
  sfile="${rt}/session.env"
  [ -f "$sfile" ] || return 1

  printf 'export RUNTIME_DIR=%q\n' "$rt"
  printf 'export DOEY_RUNTIME=%q\n' "$rt"

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      [A-Za-z_]*=*) printf 'export %s\n' "$line" ;;
    esac
  done < "$sfile"
  return 0
}

# Direct invocation: `bash doey-env.sh`
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  doey_env_cmd || exit 1
fi
