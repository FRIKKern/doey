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

# _doey_send_check_activity <captured_output>
# Returns 0 if the pane output shows signs of Claude processing.
_doey_send_check_activity() {
  local captured="$1"
  printf '%s' "$captured" | grep -qE '(⏳|thinking|Thinking|╭─|● |Reading|Writing|Editing|Searching|Running|Bash|Glob|Grep|Agent)' 2>/dev/null
}

# _doey_send_check_busy <target>
# Returns 0 if the target pane's status file shows BUSY.
_doey_send_check_busy() {
  local target="$1"
  local runtime_dir="${DOEY_RUNTIME:-${RUNTIME_DIR:-}}"
  [ -n "$runtime_dir" ] || return 1
  local target_safe
  target_safe=$(printf '%s' "$target" | tr ':.-' '_')
  local status_file="${runtime_dir}/status/${target_safe}.status"
  [ -f "$status_file" ] || return 1
  local cur_status
  cur_status=$(grep '^STATUS:' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS:[[:space:]]*//' || true)
  [ "$cur_status" = "BUSY" ]
}

# doey_send_verified <target_pane> <message>
#
# Sends a message to a target tmux pane with delivery verification and retry.
#   - Pre-clears on EVERY attempt: copy-mode -q → Escape → C-u (ensures clean input)
#   - On retries: also sends C-c to cancel any stuck operation
#   - Short messages (<500 chars, single line): send-keys with -- flag, settle, Enter
#   - Long/multi-line messages: tmpfile → load-buffer → paste-buffer → Escape → Enter
#   - Verifies delivery via activity detection, snippet match, or BUSY status
#   - If text appears stuck, attempts Escape → Enter recovery
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

    # --- Pre-clear: ensure clean input state on EVERY attempt ---
    # Exit tmux copy-mode, dismiss Claude Code modal/prompt, clear leftover input
    tmux copy-mode -q -t "$target" 2>/dev/null || true
    tmux send-keys -t "$target" Escape 2>/dev/null || true
    sleep 0.1
    tmux send-keys -t "$target" C-u 2>/dev/null || true
    sleep 0.1

    # On retries, aggressively cancel any stuck operation
    if [ "$attempt" -gt 1 ]; then
      tmux send-keys -t "$target" C-c 2>/dev/null || true
      sleep 0.3
      tmux send-keys -t "$target" Escape 2>/dev/null || true
      sleep 0.1
      tmux send-keys -t "$target" C-u 2>/dev/null || true
      sleep 0.1
    fi

    # Detect multi-line or long message
    local has_newline=false
    case "$message" in
      *"$(printf '\n')"*) has_newline=true ;;
    esac
    local msg_len=${#message}

    if [ "$has_newline" = "false" ] && [ "$msg_len" -lt 500 ]; then
      # Short single-line: type text, settle, then Enter
      tmux send-keys -t "$target" -- "$message" 2>/dev/null || true
      sleep 0.15
      tmux send-keys -t "$target" Enter 2>/dev/null || true
    else
      # Long/multi-line: tmpfile + load-buffer + paste-buffer
      local tmpfile
      tmpfile=$(mktemp "${TMPDIR:-/tmp}/doey_send_XXXXXX.txt")
      printf '%s' "$message" > "$tmpfile"
      if ! tmux load-buffer "$tmpfile" 2>/dev/null; then
        rm -f "$tmpfile"
        continue
      fi
      if ! tmux paste-buffer -t "$target" 2>/dev/null; then
        rm -f "$tmpfile"
        continue
      fi
      rm -f "$tmpfile"
      sleep 0.3
      # Escape ensures cursor is in submit position after paste
      tmux send-keys -t "$target" Escape 2>/dev/null || true
      sleep 0.2
      tmux send-keys -t "$target" Enter 2>/dev/null || true
    fi

    # Verify delivery with exponential backoff
    local verify_delay
    case "$attempt" in
      1) verify_delay="0.5" ;;
      2) verify_delay="1" ;;
      *) verify_delay="2" ;;
    esac
    sleep "$verify_delay"

    # --- Verification checks ---
    local captured
    captured=$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null) || captured=""

    # Check 1: pane shows Claude activity (thinking, tool use, etc.)
    if _doey_send_check_activity "$captured"; then
      return 0
    fi

    # Check 2: message snippet visible in pane output
    local snippet
    if [ "$msg_len" -gt 40 ]; then
      snippet="${message:0:40}"
    else
      snippet="$message"
    fi
    snippet=$(printf '%s' "$snippet" | tr '\n' ' ')
    if printf '%s' "$captured" | grep -qF "$snippet" 2>/dev/null; then
      return 0
    fi

    # Check 3: BUSY status
    if _doey_send_check_busy "$target"; then
      return 0
    fi

    # --- Stuck-text recovery ---
    # Text may be typed but not submitted; exit modal + resubmit
    tmux copy-mode -q -t "$target" 2>/dev/null || true
    tmux send-keys -t "$target" Escape 2>/dev/null || true
    sleep 0.15
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep 0.5

    # Re-verify after recovery attempt
    captured=$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null) || captured=""
    if _doey_send_check_activity "$captured"; then
      return 0
    fi
    if _doey_send_check_busy "$target"; then
      return 0
    fi

    # Retry or fail
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
