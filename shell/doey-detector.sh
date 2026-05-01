#!/usr/bin/env bash
# doey-detector.sh — lifecycle commands for the silent-fail-detector daemon.
# Subcommands: start, stop, status, restart.
# All commands operate on the current project's runtime dir.
set -euo pipefail

# Resolve the detector script the same way on-session-start.sh does:
# installed → repo dev path → in-project shell/.
_detector_resolve_bin() {
  local repo=""
  [ -f "$HOME/.claude/doey/repo-path" ] && repo=$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null) || true
  if [ -x "$HOME/.local/bin/silent-fail-detector.sh" ]; then
    echo "$HOME/.local/bin/silent-fail-detector.sh"; return 0
  fi
  if [ -n "$repo" ] && [ -x "${repo}/shell/silent-fail-detector.sh" ]; then
    echo "${repo}/shell/silent-fail-detector.sh"; return 0
  fi
  if [ -n "${PROJECT_DIR:-}" ] && [ -x "${PROJECT_DIR}/shell/silent-fail-detector.sh" ]; then
    echo "${PROJECT_DIR}/shell/silent-fail-detector.sh"; return 0
  fi
  if [ -x "${SCRIPT_DIR:-}/silent-fail-detector.sh" ]; then
    echo "${SCRIPT_DIR}/silent-fail-detector.sh"; return 0
  fi
  return 1
}

_detector_runtime_dir() {
  local rt="${RUNTIME_DIR:-${DOEY_RUNTIME_DIR:-}}"
  if [ -z "$rt" ]; then
    local proj_name
    proj_name=$(basename "${PWD:-doey}")
    rt="${TMPDIR:-/tmp}/doey/${proj_name}"
  fi
  echo "$rt"
}

_detector_pid() {
  local pid_file="$1"
  [ -f "$pid_file" ] || return 1
  local pid
  pid=$(cat "$pid_file" 2>/dev/null || echo "")
  pid="${pid%%[!0-9]*}"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  echo "$pid"
}

_detector_mtime() {
  local f="$1"
  [ -e "$f" ] || { echo ""; return 0; }
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo ""
}

doey_detector_start() {
  local bin rt
  bin=$(_detector_resolve_bin) || { echo "detector: binary not found" >&2; return 1; }
  rt=$(_detector_runtime_dir)
  mkdir -p "$rt"
  RUNTIME_DIR="$rt" bash "$bin" start
  local pid_file="$rt/silent-fail-detector.pid"
  # Brief poll for PID to land.
  local _i=0
  while [ "$_i" -lt 30 ]; do
    if [ -f "$pid_file" ]; then
      local pid
      pid=$(_detector_pid "$pid_file" || echo "")
      if [ -n "$pid" ]; then
        echo "started pid=$pid"
        return 0
      fi
    fi
    sleep 0.1
    _i=$((_i + 1))
  done
  echo "detector: spawn timed out (no live PID after 3s)" >&2
  return 1
}

doey_detector_stop() {
  local rt pid_file pid
  rt=$(_detector_runtime_dir)
  pid_file="$rt/silent-fail-detector.pid"
  if [ ! -f "$pid_file" ]; then
    echo "not running"
    return 0
  fi
  pid=$(cat "$pid_file" 2>/dev/null || echo "")
  pid="${pid%%[!0-9]*}"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    local _i=0
    while [ "$_i" -lt 30 ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
      _i=$((_i + 1))
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file" 2>/dev/null || true
  echo "stopped"
}

doey_detector_status() {
  local bin rt pid_file pid mtime
  bin=$(_detector_resolve_bin) || bin=""
  rt=$(_detector_runtime_dir)
  pid_file="$rt/silent-fail-detector.pid"
  if pid=$(_detector_pid "$pid_file"); then
    if [ -n "$bin" ]; then
      mtime=$(_detector_mtime "$bin")
      printf 'running pid=%s script=%s mtime=%s\n' "$pid" "$bin" "${mtime:-unknown}"
    else
      printf 'running pid=%s\n' "$pid"
    fi
    return 0
  fi
  echo "not running"
  return 0
}

doey_detector_restart() {
  doey_detector_stop >/dev/null 2>&1 || true
  local rt pid_file _i=0
  rt=$(_detector_runtime_dir)
  pid_file="$rt/silent-fail-detector.pid"
  while [ "$_i" -lt 30 ]; do
    [ -f "$pid_file" ] || break
    sleep 0.1
    _i=$((_i + 1))
  done
  doey_detector_start
}

doey_detector_dispatch() {
  local sub="${1:-status}"
  case "$sub" in
    start)   doey_detector_start ;;
    stop)    doey_detector_stop ;;
    status)  doey_detector_status ;;
    restart) doey_detector_restart ;;
    -h|--help|help)
      echo "Usage: doey detector {start|stop|status|restart}"
      ;;
    *)
      echo "Usage: doey detector {start|stop|status|restart}" >&2
      return 1
      ;;
  esac
}
