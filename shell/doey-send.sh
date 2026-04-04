#!/usr/bin/env bash
# doey-send.sh — Canonical send-keys helper with delivery verification and retry.
# Sourceable library. Provides doey_send_verified() for reliable message delivery
# to tmux panes (primarily Claude Code instances).
#
# Usage:
#   source doey-send.sh
#   doey_send_verified "$SESSION:$WINDOW.$PANE" "Your message here"
#
# Bash 3.2 compatible — no associative arrays, no mapfile, no pipe-ampersand.
set -euo pipefail

# doey_send_verified <target_pane> <message>
#
# Sends a message to a target tmux pane with delivery verification and retry.
#   - Exits copy-mode first
#   - Short messages (<200 chars, single line): send-keys with -- flag
#   - Long/multi-line messages: tmpfile → load-buffer → paste-buffer → Enter
#   - Verifies delivery via capture-pane or BUSY status check
#   - Retries up to 3x with exponential backoff (0.5s, 1s, 2s)
#
# Returns: 0 on success, 1 on failure after all retries
doey_send_verified() {
  local target="$1"
  local message="$2"
  local max_retries=3
  local attempt=0

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))

    # Exit copy-mode
    tmux copy-mode -q -t "$target" 2>/dev/null || true

    # Detect multi-line or long message
    local has_newline=false
    case "$message" in
      *"$(printf '\n')"*) has_newline=true ;;
    esac
    local msg_len=${#message}

    if [ "$has_newline" = "false" ] && [ "$msg_len" -lt 200 ]; then
      # Short single-line: direct send-keys
      tmux send-keys -t "$target" -- "$message" Enter 2>/dev/null || true
    else
      # Long/multi-line: tmpfile + load-buffer + paste-buffer
      local tmpfile
      tmpfile=$(mktemp "${TMPDIR:-/tmp}/doey_send_XXXXXX.txt")
      printf '%s' "$message" > "$tmpfile"
      tmux load-buffer "$tmpfile" 2>/dev/null || { rm -f "$tmpfile"; continue; }
      tmux paste-buffer -t "$target" 2>/dev/null || { rm -f "$tmpfile"; continue; }
      sleep 0.5
      tmux send-keys -t "$target" Escape 2>/dev/null || true
      sleep 0.3
      tmux send-keys -t "$target" Enter 2>/dev/null || true
      rm -f "$tmpfile"
    fi

    # Verify delivery with exponential backoff
    local verify_delay
    case "$attempt" in
      1) verify_delay="0.5" ;;
      2) verify_delay="1" ;;
      *) verify_delay="2" ;;
    esac
    sleep "$verify_delay"

    # Check 1: message text visible in last 5 lines of pane
    local captured
    captured=$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null) || captured=""

    # Use first 40 chars (or full message if shorter) as verification snippet
    local snippet
    if [ "$msg_len" -gt 40 ]; then
      snippet="${message:0:40}"
    else
      snippet="$message"
    fi
    # Strip newlines from snippet for grep matching
    snippet=$(printf '%s' "$snippet" | tr '\n' ' ')

    if printf '%s' "$captured" | grep -qF "$snippet" 2>/dev/null; then
      return 0
    fi

    # Check 2: target pane status changed to BUSY
    local runtime_dir="${DOEY_RUNTIME:-${RUNTIME_DIR:-}}"
    if [ -n "$runtime_dir" ]; then
      local target_safe
      target_safe=$(printf '%s' "$target" | tr ':.-' '_')
      local status_file="${runtime_dir}/status/${target_safe}.status"
      if [ -f "$status_file" ]; then
        local cur_status
        cur_status=$(grep '^STATUS:' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS:[[:space:]]*//' || true)
        if [ "$cur_status" = "BUSY" ]; then
          return 0
        fi
      fi
    fi

    # Last attempt — fail
    if [ "$attempt" -ge "$max_retries" ]; then
      echo "doey_send_verified: delivery failed after $max_retries attempts to $target" >&2
      return 1
    fi

    echo "doey_send_verified: attempt $attempt failed for $target, retrying..." >&2
  done

  return 1
}

# doey_send_command <target_pane> <command>
#
# Sends a shell command to a pane (for launching processes, not Claude messages).
# No verification — fire-and-forget. Exits copy-mode first.
doey_send_command() {
  local target="$1"
  local cmd="$2"
  tmux copy-mode -q -t "$target" 2>/dev/null || true
  tmux send-keys -t "$target" "$cmd" Enter 2>/dev/null || true
}
