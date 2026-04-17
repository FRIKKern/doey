#!/usr/bin/env bash
# doey-wait.sh — blocking `doey wait-for-ready <pane>` primitive.
#
# Replaces sleep-poll loops in agent prompts. Blocks until the target
# Subtaskmaster / worker has written its ready marker, then exits 0.
# On timeout, exits 124 (same as timeout(1)) so callers can branch.
#
# Marker file: $RUNTIME_DIR/ready/pane_<window>_<pane>
# The marker is written by on-session-start.sh once the pane's Claude
# process is fully booted — not the synchronous spawn-time READY.

set -euo pipefail

_doey_wait_resolve_runtime() {
  if [ -n "${DOEY_RUNTIME:-}" ] && [ -d "$DOEY_RUNTIME" ]; then
    printf '%s\n' "$DOEY_RUNTIME"
    return 0
  fi
  if [ -n "${TMUX:-}" ]; then
    local rt
    rt="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)"
    [ -n "$rt" ] && [ -d "$rt" ] && { printf '%s\n' "$rt"; return 0; }
  fi
  # Delegate to doey-env.sh for the CWD-walk fallback.
  local helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/doey-env.sh"
  if [ -f "$helper" ]; then
    # shellcheck source=doey-env.sh
    . "$helper"
    _doey_env_resolve_runtime && return 0
  fi
  return 1
}

doey_wait_for_ready() {
  local pane="" timeout=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout-sec|--timeout) shift; timeout="${1:-30}" ;;
      --help|-h)
        cat <<USAGE
Usage: doey wait-for-ready <pane> [--timeout-sec N]

  pane    Target in WINDOW.PANE form (e.g. 2.0).
  --timeout-sec N  Give up after N seconds (default: 30). Exit 124 on timeout.

Blocks until \$RUNTIME_DIR/ready/pane_<window>_<pane> exists, then exits 0.
USAGE
        return 0 ;;
      -*)
        printf 'doey wait-for-ready: unknown option %s\n' "$1" >&2
        return 2 ;;
      *) [ -z "$pane" ] && pane="$1" ;;
    esac
    shift || true
  done

  if [ -z "$pane" ]; then
    printf 'Usage: doey wait-for-ready <pane> [--timeout-sec N]\n' >&2
    return 2
  fi

  case "$pane" in
    *.*) ;;
    *)
      printf 'doey wait-for-ready: pane must be WINDOW.PANE (got %s)\n' "$pane" >&2
      return 2 ;;
  esac

  case "$timeout" in
    ''|*[!0-9]*)
      printf 'doey wait-for-ready: --timeout-sec requires an integer\n' >&2
      return 2 ;;
  esac

  local window="${pane%%.*}" pane_idx="${pane#*.}"
  local rt
  rt="$(_doey_wait_resolve_runtime)" || {
    printf 'doey wait-for-ready: no active Doey session found\n' >&2
    return 2
  }

  local ready_dir="${rt}/ready"
  local marker="${ready_dir}/pane_${window}_${pane_idx}"
  mkdir -p "$ready_dir"

  # Fast path
  [ -e "$marker" ] && return 0

  # Prefer inotifywait on Linux for instant wake-up.
  if command -v inotifywait >/dev/null 2>&1; then
    local rc
    # -q quiet, -e create/moved_to, --timeout in seconds; watch the dir
    # because the marker may not exist yet.
    while [ ! -e "$marker" ]; do
      inotifywait -q -e create -e moved_to -e attrib \
        --timeout "$timeout" "$ready_dir" >/dev/null 2>&1
      rc=$?
      [ -e "$marker" ] && return 0
      # rc 2 == timeout per inotifywait(1)
      [ "$rc" -eq 2 ] && return 124
      # Any other rc: fall through to stat-loop for the remainder
      break
    done
  fi

  # Portable stat-loop fallback (macOS, systems without inotify-tools).
  local elapsed=0
  local step_ms=200
  while [ ! -e "$marker" ]; do
    if [ "$elapsed" -ge "$((timeout * 1000))" ]; then
      return 124
    fi
    # `sleep 0.2` is POSIX-valid on modern bash; both Linux and macOS sleep accept it.
    sleep 0.2
    elapsed=$((elapsed + step_ms))
  done
  return 0
}

# Direct invocation
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  doey_wait_for_ready "$@"
fi
