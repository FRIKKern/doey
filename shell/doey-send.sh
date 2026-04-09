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

# _doey_send_lock <pane_safe>
# Acquires an atomic file-based lock for the target pane.
# Uses mkdir (POSIX atomic). Stale locks (PID dead or >30s) are cleaned.
# Returns 0 on success, 1 on timeout (30s).
_doey_send_lock() {
  local pane_safe="$1"
  local runtime="${DOEY_RUNTIME:-${RUNTIME_DIR:-/tmp/doey}}"
  local lock_dir="${runtime}/locks"
  local lock_path="${lock_dir}/${pane_safe}.lock"

  mkdir -p "$lock_dir" 2>/dev/null || true

  local attempts=0
  while [ "$attempts" -lt 60 ]; do
    if mkdir "$lock_path" 2>/dev/null; then
      echo "$$:$(date +%s)" > "${lock_path}/pid" 2>/dev/null || true
      return 0
    fi
    # Check for stale lock
    local lock_content lock_pid lock_time
    lock_content=$(cat "${lock_path}/pid" 2>/dev/null) || lock_content=""
    lock_pid="${lock_content%%:*}"
    lock_time="${lock_content##*:}"
    local is_stale=false
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      is_stale=true
    fi
    if [ -n "$lock_time" ]; then
      local now_epoch
      now_epoch=$(date +%s)
      if [ $((now_epoch - lock_time)) -gt 30 ]; then
        is_stale=true
      fi
    fi
    if [ "$is_stale" = true ]; then
      rm -rf "$lock_path" 2>/dev/null || true
      continue
    fi
    sleep 0.5
    attempts=$((attempts + 1))
  done
  echo "_doey_send_lock: timeout acquiring lock for $pane_safe" >&2
  return 1
}

# _doey_send_unlock <pane_safe>
# Releases the file-based lock for the target pane.
_doey_send_unlock() {
  local pane_safe="$1"
  local runtime="${DOEY_RUNTIME:-${RUNTIME_DIR:-/tmp/doey}}"
  local lock_path="${runtime}/locks/${pane_safe}.lock"
  rm -rf "$lock_path" 2>/dev/null || true
}

# _doey_send_precheck <target> <message>
# Checks if the target pane is BUSY. If so, queues the message for later delivery.
# Returns: 0 = proceed with send, 2 = message queued (caller should not send).
_doey_send_precheck() {
  local target="$1"
  local message="$2"
  local runtime="${DOEY_RUNTIME:-${RUNTIME_DIR:-/tmp/doey}}"
  [ -n "$runtime" ] || return 0

  local target_safe
  target_safe=$(printf '%s' "$target" | tr ':.-' '_')
  local status_file="${runtime}/status/${target_safe}.status"
  [ -f "$status_file" ] || return 0

  local cur_status
  cur_status=$(grep '^STATUS:' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS:[[:space:]]*//' || true)

  if [ "$cur_status" = "BUSY" ]; then
    local pending_dir="${runtime}/pending"
    mkdir -p "$pending_dir" 2>/dev/null || true
    local msg_file="${pending_dir}/${target_safe}_$(date +%s)_$$.msg"
    {
      echo "FROM=${PANE:-unknown}"
      echo "TO=${target}"
      echo "TIMESTAMP=$(date +%s)"
      echo "---"
      printf '%s' "$message"
    } > "$msg_file"
    return 2
  fi

  # Check reservation status — reserved panes cannot receive dispatched work
  if [ -f "${runtime}/status/${target_safe}.reserved" ]; then
    echo "doey_send_verified: target $target is RESERVED — skipping" >&2
    return 2
  fi

  return 0
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
#   4. Sends Enter after brief settle
#   5. Polls for BUSY status or activity indicators to confirm submission
#   6. Retries up to 3x if prompt/paste-buffer steps fail
#
# Paste-buffer delivery is atomic and reliable — verification confirms
# submission, but trusts delivery if paste-buffer returned 0.
#
# Returns: 0 on success, 1 on failure after all retries.
doey_send_verified() {
  local target="$1"
  local message="$2"
  local skip_precheck="${3:-}"
  local target_safe
  target_safe=$(printf '%s' "$target" | tr ':.-' '_')

  # Pre-send BUSY check with queue fallback
  if [ "$skip_precheck" != "1" ]; then
    _doey_send_precheck "$target" "$message"
    local pc=$?
    if [ "$pc" -eq 2 ]; then return 2; fi
  fi

  # Acquire per-pane lock to prevent concurrent sends
  if ! _doey_send_lock "$target_safe"; then
    echo "doey_send_verified: could not acquire lock for $target" >&2
    return 1
  fi

  _doey_send_verified_inner "$target" "$message"
  local rc=$?

  _doey_send_unlock "$target_safe"
  return $rc
}

# _doey_send_verified_inner <target_pane> <message>
# Internal: performs the actual send with readiness gating, paste-buffer delivery,
# and submission verification. Called by doey_send_verified after lock acquisition.
_doey_send_verified_inner() {
  local target="$1"
  local message="$2"
  local max_retries=4
  local attempt=0

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))

    # Exponential backoff on retries
    if [ "$attempt" -gt 1 ]; then
      local backoff_s
      case "$attempt" in
        2) backoff_s="0.5" ;;
        3) backoff_s="1.0" ;;
        *) backoff_s="2.0" ;;
      esac
      sleep "$backoff_s"
    fi

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

    # ── Step 2: Pre-clear input (every attempt — clears residual text from failed retries) ──
    tmux copy-mode -q -t "$target" 2>/dev/null || true
    tmux send-keys -t "$target" Escape 2>/dev/null || true
    sleep 0.1
    tmux send-keys -t "$target" C-u 2>/dev/null || true
    sleep 0.1

    # ── Step 3: Inject text via paste-buffer (all messages, any length) ──
    local buf_name="doey_send_$$_$(date +%s)_${attempt}"
    if ! tmux set-buffer -b "$buf_name" -- "$message" 2>/dev/null; then
      echo "doey_send_verified: set-buffer failed (attempt $attempt)" >&2
      continue
    fi
    tmux copy-mode -q -t "$target" 2>/dev/null || true
    if ! tmux paste-buffer -t "$target" -b "$buf_name" 2>/dev/null; then
      tmux delete-buffer -b "$buf_name" 2>/dev/null || true
      echo "doey_send_verified: paste-buffer failed (attempt $attempt)" >&2
      continue
    fi
    # Explicit cleanup (no -d flag — we manage buffer lifetime)
    tmux delete-buffer -b "$buf_name" 2>/dev/null || true

    # ── Step 4: Brief settle then submit ──
    # Paste-buffer delivery is atomic — if set-buffer + paste-buffer both
    # returned 0 (no early continue above), the text is in the pane's input.
    # No text-matching verification: by the time capture-pane runs, Claude
    # has often already consumed the input, causing false negatives.
    local settle_s
    settle_s=$(awk "BEGIN {printf \"%.3f\", ${PASTE_SETTLE_MS:-800}/1000}")
    sleep "$settle_s"
    tmux send-keys -t "$target" Enter 2>/dev/null || true

    # ── Step 5: Confirm submission via BUSY status or activity ──
    # Poll for up to 3 seconds. If Enter didn't register (e.g. pane was in
    # copy-mode), try Escape + Enter recovery at the halfway point.
    local v=0
    while [ "$v" -lt 6 ]; do
      sleep 0.5
      v=$((v + 1))
      if _doey_send_check_busy "$target"; then
        return 0
      fi
      local post_submit
      post_submit=$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null) || post_submit=""
      if _doey_send_check_activity "$post_submit"; then
        return 0
      fi
      # Halfway: recovery in case Enter didn't register (modal state)
      if [ "$v" -eq 3 ]; then
        tmux copy-mode -q -t "$target" 2>/dev/null || true
        tmux send-keys -t "$target" Escape 2>/dev/null || true
        sleep 0.15
        tmux send-keys -t "$target" Enter 2>/dev/null || true
      fi
    done

    # Paste-buffer + Enter both succeeded — trust delivery even without
    # explicit BUSY/activity confirmation. Claude may have processed input
    # too quickly for polling to catch the transition, or the status file
    # may not be available (e.g. DOEY_RUNTIME unset).
    return 0
  done

  echo "doey_send_verified: delivery failed after $max_retries attempts to $target" >&2
  return 1
}

# doey_deliver_pending <target_pane>
#
# Delivers queued messages for the target pane (oldest first).
# Called when a pane becomes READY (e.g. from on-prompt-submit.sh).
# Stops on first delivery failure; remaining messages stay queued.
doey_deliver_pending() {
  local target="$1"
  local runtime="${DOEY_RUNTIME:-${RUNTIME_DIR:-/tmp/doey}}"
  local target_safe
  target_safe=$(printf '%s' "$target" | tr ':.-' '_')
  local pending_dir="${runtime}/pending"
  [ -d "$pending_dir" ] || return 0

  local msg_files
  msg_files=$(ls "${pending_dir}/${target_safe}_"*.msg 2>/dev/null | sort) || msg_files=""
  [ -n "$msg_files" ] || return 0

  local f
  printf '%s\n' "$msg_files" | while IFS= read -r f; do
    [ -f "$f" ] || continue
    # Extract message content (everything after --- line)
    local msg
    msg=$(sed '1,/^---$/d' "$f" 2>/dev/null) || msg=""
    if [ -z "$msg" ]; then
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    # skip_precheck=1 to avoid re-queuing
    if doey_send_verified "$target" "$msg" 1; then
      rm -f "$f" 2>/dev/null || true
    else
      break
    fi
  done
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
