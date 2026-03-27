#!/usr/bin/env bash
set -euo pipefail

# doey-msg — Message utility for Doey IPC
# Replaces inline bash patterns for sending, draining, and triggering messages.

usage() {
  printf 'Usage: doey-msg <command> [args...]\n\n'
  printf 'Commands:\n'
  printf '  drain [PANE_SAFE]          Read, print, and delete all messages for a pane\n'
  printf '  send TARGET FROM SUBJ BODY Write a message file and touch trigger\n'
  printf '  trigger TARGET_SAFE        Touch the trigger file for a pane\n'
  printf '\nEnvironment: RUNTIME_DIR must be set.\n'
  exit 1
}

# --- Validation ---

if [ $# -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  usage
fi

if [ -z "${RUNTIME_DIR:-}" ]; then
  printf 'Error: RUNTIME_DIR is not set\n' >&2
  exit 1
fi

CMD="$1"
shift

# --- Commands ---

cmd_drain() {
  local pane_safe="${1:-}"

  # Auto-derive from environment if not provided
  if [ -z "$pane_safe" ]; then
    if [ -n "${DOEY_PANE_SAFE:-}" ]; then
      pane_safe="$DOEY_PANE_SAFE"
    elif [ -n "${SESSION_NAME:-}" ] && [ -n "${DOEY_WINDOW_INDEX:-}" ] && [ -n "${DOEY_PANE_INDEX:-}" ]; then
      pane_safe="${SESSION_NAME//[-:.]/_}_${DOEY_WINDOW_INDEX}_${DOEY_PANE_INDEX}"
    else
      printf 'Error: PANE_SAFE required (or set DOEY_PANE_SAFE / SESSION_NAME+DOEY_WINDOW_INDEX+DOEY_PANE_INDEX)\n' >&2
      exit 1
    fi
  fi

  # Use bash subshell with nullglob for zsh safety
  bash -c 'shopt -s nullglob; for f in "$1"/messages/"$2"_*.msg; do cat "$f"; printf "%s\n" "---"; rm -f "$f"; done' _ "$RUNTIME_DIR" "$pane_safe"
  exit 0
}

cmd_send() {
  if [ $# -lt 4 ]; then
    printf 'Usage: doey-msg send TARGET_SAFE FROM SUBJECT BODY\n' >&2
    exit 1
  fi

  local target_safe="$1"
  local from="$2"
  local subject="$3"
  local body="$4"
  local msg_dir="${RUNTIME_DIR}/messages"
  local trig_dir="${RUNTIME_DIR}/triggers"

  mkdir -p "$msg_dir" "$trig_dir"

  local ts
  ts=$(date +%s)
  local dest="${msg_dir}/${target_safe}_${ts}_$$.msg"
  local tmp="${dest}.tmp"

  printf 'FROM: %s\nSUBJECT: %s\n%s\n' "$from" "$subject" "$body" > "$tmp"
  mv "$tmp" "$dest"

  touch "${trig_dir}/${target_safe}.trigger" 2>/dev/null || true
  exit 0
}

cmd_trigger() {
  if [ $# -lt 1 ]; then
    printf 'Usage: doey-msg trigger TARGET_SAFE\n' >&2
    exit 1
  fi

  local target_safe="$1"
  local trig_dir="${RUNTIME_DIR}/triggers"
  mkdir -p "$trig_dir"
  touch "${trig_dir}/${target_safe}.trigger" 2>/dev/null || true
  exit 0
}

# --- Dispatch ---

case "$CMD" in
  drain)   cmd_drain "$@" ;;
  send)    cmd_send "$@" ;;
  trigger) cmd_trigger "$@" ;;
  *)       printf 'Unknown command: %s\n' "$CMD" >&2; usage ;;
esac
