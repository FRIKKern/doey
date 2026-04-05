#!/usr/bin/env bash
# doey-send.sh — Canonical send-keys helper with delivery verification and retry.
# Sourceable library. Provides doey_send_verified() for reliable message delivery
# to tmux panes (primarily Claude Code instances), and doey_send_command() for
# shell commands.
#
# Usage:
#   source doey-send.sh
#   doey_send_verified "$SESSION:$WINDOW.$PANE" "Your message here"
#   doey_send_command "$SESSION:$WINDOW.$PANE" "shell command"
#   doey_wait_for_prompt "$SESSION:$WINDOW.$PANE" 30
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

# doey_wait_for_prompt <target_pane> [timeout_seconds]
#
# Waits for a Claude prompt (❯ character) to appear in the target pane.
# Standalone readiness gate — can be called before doey_send_verified or
# anywhere startup needs to confirm Claude is ready.
#
# Returns: 0 if prompt found, 1 on timeout.
doey_wait_for_prompt() {
  local target="$1"
  local timeout="${2:-30}"
  local elapsed=0
  local interval=1

  # Fast path: check immediately before any sleep
  local captured
  captured=$(tmux capture-pane -t "$target" -p -S -10 2>/dev/null) || captured=""
  if printf '%s' "$captured" | grep -qF '❯' 2>/dev/null; then
    return 0
  fi

  while [ "$elapsed" -lt "$timeout" ]; do
    sleep "$interval"
    elapsed=$((elapsed + interval))
    captured=$(tmux capture-pane -t "$target" -p -S -10 2>/dev/null) || captured=""
    if printf '%s' "$captured" | grep -qF '❯' 2>/dev/null; then
      return 0
    fi
    # Widen interval after initial fast checks to reduce polling
    [ "$elapsed" -ge 5 ] && interval=2
  done

  return 1
}

# doey_send_verified <target_pane> <message>
#
# Sends a message to a target tmux pane with readiness gating, buffer-based
# delivery, and submission verification.
#
#   1. Waits for Claude prompt (❯) to appear (readiness gate)
#   2. Pre-clears: copy-mode -q → Escape → C-u (ensures clean input)
#   3. Injects text via set-buffer + paste-buffer (NOT raw send-keys)
#   4. Captures pane to verify text appeared
#   5. Sends Enter to submit
#   6. Captures pane again to verify prompt changed (submission happened)
#   7. Retries up to 3x if any step fails
#
# Returns: 0 on success, 1 on failure after all retries.
doey_send_verified() {
  local target="$1"
  local message="$2"
  local max_retries=3
  local attempt=0

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))

    # ── Step 1: Wait for visible Claude prompt (❯) ──
    local prompt_timeout=30
    [ "$attempt" -gt 1 ] && prompt_timeout=10  # shorter on retries
    if ! doey_wait_for_prompt "$target" "$prompt_timeout"; then
      echo "doey_send_verified: no prompt at $target (attempt $attempt/$max_retries)" >&2
      # On retry, try C-c to unstick
      if [ "$attempt" -gt 1 ]; then
        tmux send-keys -t "$target" C-c 2>/dev/null || true
        sleep 0.5
      fi
      continue
    fi

    # ── Step 2: Pre-clear input ──
    tmux copy-mode -q -t "$target" 2>/dev/null || true
    tmux send-keys -t "$target" Escape 2>/dev/null || true
    sleep 0.1
    tmux send-keys -t "$target" C-u 2>/dev/null || true
    sleep 0.1

    if [ "$attempt" -gt 1 ]; then
      tmux send-keys -t "$target" C-c 2>/dev/null || true
      sleep 0.3
      tmux send-keys -t "$target" Escape 2>/dev/null || true
      sleep 0.1
      tmux send-keys -t "$target" C-u 2>/dev/null || true
      sleep 0.1
    fi

    # ── Step 3: Inject text via set-buffer + paste-buffer ──
    local buf_name="doey_send_$$_${attempt}"
    if ! tmux set-buffer -b "$buf_name" -- "$message" 2>/dev/null; then
      echo "doey_send_verified: set-buffer failed (attempt $attempt)" >&2
      continue
    fi
    if ! tmux paste-buffer -b "$buf_name" -t "$target" -d 2>/dev/null; then
      tmux delete-buffer -b "$buf_name" 2>/dev/null || true
      echo "doey_send_verified: paste-buffer failed (attempt $attempt)" >&2
      continue
    fi

    # ── Step 4: Verify text appeared in pane ──
    sleep 0.3
    local captured
    captured=$(tmux capture-pane -t "$target" -p -S -10 2>/dev/null) || captured=""
    local snippet
    if [ ${#message} -gt 40 ]; then
      snippet="${message:0:40}"
    else
      snippet="$message"
    fi
    snippet=$(printf '%s' "$snippet" | tr '\n' ' ')

    if ! printf '%s' "$captured" | grep -qF "$snippet" 2>/dev/null; then
      # Text didn't appear — Escape to ensure focus, re-check
      tmux send-keys -t "$target" Escape 2>/dev/null || true
      sleep 0.2
      captured=$(tmux capture-pane -t "$target" -p -S -10 2>/dev/null) || captured=""
      if ! printf '%s' "$captured" | grep -qF "$snippet" 2>/dev/null; then
        echo "doey_send_verified: text not visible (attempt $attempt)" >&2
        continue
      fi
    fi

    # Capture pre-submit state for change detection
    local pre_submit
    pre_submit=$(tmux capture-pane -t "$target" -p -S -3 2>/dev/null) || pre_submit=""

    # ── Step 5: Send Enter to submit ──
    tmux send-keys -t "$target" Escape 2>/dev/null || true
    sleep 0.15
    tmux send-keys -t "$target" Enter 2>/dev/null || true

    # ── Step 6: Verify prompt changed (submission happened) ──
    local verify_delay
    case "$attempt" in
      1) verify_delay="0.5" ;;
      2) verify_delay="1" ;;
      *) verify_delay="2" ;;
    esac
    sleep "$verify_delay"

    local post_submit
    post_submit=$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null) || post_submit=""

    # Submission confirmed if Claude is active (thinking, tool use, etc.)
    if _doey_send_check_activity "$post_submit"; then
      return 0
    fi

    # Submission confirmed if status file shows BUSY
    if _doey_send_check_busy "$target"; then
      return 0
    fi

    # Submission confirmed if pane content changed after Enter
    if [ "$pre_submit" != "$post_submit" ]; then
      return 0
    fi

    # ── Stuck-text recovery: exit modal + resubmit ──
    tmux copy-mode -q -t "$target" 2>/dev/null || true
    tmux send-keys -t "$target" Escape 2>/dev/null || true
    sleep 0.15
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep 0.5

    post_submit=$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null) || post_submit=""
    if _doey_send_check_activity "$post_submit"; then
      return 0
    fi
    if _doey_send_check_busy "$target"; then
      return 0
    fi

    [ "$attempt" -ge "$max_retries" ] && break
    echo "doey_send_verified: attempt $attempt failed for $target, retrying..." >&2
  done

  echo "doey_send_verified: delivery failed after $max_retries attempts to $target" >&2
  return 1
}

# doey_send_command <target_pane> <command>
#
# Sends a shell command to a pane (for launching processes, not Claude messages).
# No readiness gate — fire-and-forget. Exits copy-mode first.
doey_send_command() {
  local target="$1"
  local cmd="$2"
  tmux copy-mode -q -t "$target" 2>/dev/null || true
  tmux send-keys -t "$target" "$cmd" Enter 2>/dev/null || true
}
