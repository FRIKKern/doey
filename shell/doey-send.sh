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

# Resolve grep to an absolute path for prompt/activity detection. Worker shells
# (Claude Code Bash sandbox) define a `grep` function that wraps the `claude -G`
# ugrep binary; under some sandbox conditions that wrapper does not behave like
# real grep on stdin pipes, breaking ❯ detection (task 634). Use $DOEY_GREP in
# pipe-based detection only — file-reading greps (e.g. status files) keep plain
# `grep` since the wrapper handles file arguments correctly.
: "${DOEY_GREP:=$(command -v /bin/grep 2>/dev/null || command -v /usr/bin/grep 2>/dev/null || echo grep)}"

# _doey_send_check_activity <captured_output>
# Returns 0 if the pane output shows signs of Claude processing.
_doey_send_check_activity() {
  local captured="$1"
  printf '%s' "$captured" | "$DOEY_GREP" -qE '(⏳|thinking|Thinking|╭─|● |Reading|Writing|Editing|Searching|Running|Bash|Glob|Grep|Agent)' 2>/dev/null
}

# _doey_send_check_submitted <status_file> <pre_mtime>
# Authoritative: returns 0 iff status file shows STATUS=BUSY AND mtime advanced
# past pre_mtime (proves a fresh on-prompt-submit fire, not a stale BUSY).
_doey_send_check_submitted() {
  local sf="$1" pre="$2"
  [ -n "$sf" ] && [ -f "$sf" ] || return 1
  local cur_mtime cur_status
  cur_mtime=$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null || echo 0)
  [ "$cur_mtime" -gt "$pre" ] || return 1
  cur_status=$(grep '^STATUS:' "$sf" 2>/dev/null | head -1 | sed 's/^STATUS:[[:space:]]*//' || true)
  [ "$cur_status" = "BUSY" ]
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
    return 2
  fi

  # Check reservation status — reserved panes cannot receive dispatched work
  # Exception: intra-team sends (same tmux window) are allowed through reservation
  if [ -f "${runtime}/status/${target_safe}.reserved" ]; then
    local sender_window="" target_window=""
    sender_window="${DOEY_WINDOW_INDEX:-}"
    if [ -z "$sender_window" ]; then
      local pane_id="${PANE:-}"
      if [ -n "$pane_id" ]; then
        sender_window="${pane_id#*:}"
        sender_window="${sender_window%%.*}"
      fi
    fi
    target_window="${target#*:}"
    target_window="${target_window%%.*}"
    if [ -z "$sender_window" ] || [ "$sender_window" != "$target_window" ]; then
      echo "doey_send_verified: target $target is RESERVED — skipping (cross-team)" >&2
      return 2
    fi
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
  # capture-pane kept: visual ❯ prompt is the only reliable way to confirm Claude CLI is at input
  local captured
  captured=$(tmux capture-pane -t "$target" -p -S -10 2>/dev/null) || captured=""
  if printf '%s' "$captured" | "$DOEY_GREP" -qF '❯' 2>/dev/null; then
    return 0
  fi

  while [ "$elapsed" -lt "$timeout" ]; do
    sleep "$interval"
    elapsed=$((elapsed + interval))
    captured=$(tmux capture-pane -t "$target" -p -S -10 2>/dev/null) || captured=""
    if printf '%s' "$captured" | "$DOEY_GREP" -qF '❯' 2>/dev/null; then
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

  # Authoritative submit signal: status file mtime+value transition.
  # Captured ONCE before any send so per-attempt polls can detect a fresh BUSY.
  local target_safe_inner
  target_safe_inner=$(printf '%s' "$target" | tr ':.-' '_')
  local status_file="${DOEY_RUNTIME:-${RUNTIME_DIR:-}}/status/${target_safe_inner}.status"
  local pre_mtime=0
  if [ -f "$status_file" ]; then
    pre_mtime=$(stat -c %Y "$status_file" 2>/dev/null || stat -f %m "$status_file" 2>/dev/null || echo 0)
  fi

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

    # ── Step 1.5: Bracketed-paste readiness settle (task 647) ──
    # Even after `❯` is visible, the Claude TUI parser may still be in a
    # transient state where the leading ESC byte of an upcoming bracketed-
    # paste open sequence (\e[200~) is interpreted as bare ESC = clear-input —
    # wiping the brief that arrives milliseconds later. A small deterministic
    # delay ensures the parser is past its input-loop boundary and that
    # \e[?2004h has been acknowledged before any paste bytes arrive.
    # LC_ALL=C: avoid LC_NUMERIC producing "0,100" instead of "0.100" (task 617).
    local gate_s
    gate_s=$(LC_ALL=C awk 'BEGIN {printf "%.3f", '"${PASTE_GATE_MS:-100}"'/1000}')
    sleep "$gate_s"

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
    # LC_ALL=C: avoid LC_NUMERIC producing "0,800" instead of "0.800" — task 617 / feedback_send_verified_locale_bug
    settle_s=$(LC_ALL=C awk 'BEGIN {printf "%.3f", '"${PASTE_SETTLE_MS:-800}"'/1000}')
    sleep "$settle_s"
    # Close any leaked bracketed-paste + Enter as ONE atomic write (task 647).
    # Splitting them risks a parser race where the close ESC is seen alone
    # before `[201~` arrives. tmux concatenates multi-key send-keys into one
    # write to the pane's pty — guaranteeing contiguous delivery.
    tmux send-keys -t "$target" $'\033[201~' Enter 2>/dev/null || true

    # ── Step 5: Confirm submission — fresh BUSY transition is the gold signal ──
    # Poll up to 5s (10 x 0.5s). At v=4 and v=7, send a *plain* Enter
    # (no paste-buffer re-fire, no Escape — paste already landed, only the
    # submit was lost). After full window with no fresh BUSY, fall through
    # to outer retry. NEVER silently return 0.
    local v=0
    local enter_kicks=0
    while [ "$v" -lt 10 ]; do
      sleep 0.5
      v=$((v + 1))
      if _doey_send_check_submitted "$status_file" "$pre_mtime"; then
        return 0
      fi
      # Fallback only when status file is genuinely unavailable.
      if [ -z "$status_file" ] || [ ! -f "$status_file" ]; then
        local post_submit
        post_submit=$(tmux capture-pane -t "$target" -p -S -20 2>/dev/null) || post_submit=""
        if _doey_send_check_activity "$post_submit"; then
          return 0
        fi
      fi
      # Mid-window plain-Enter kicks. NO Escape (would erase a paste that landed).
      if [ "$v" -eq 4 ] || [ "$v" -eq 7 ]; then
        if [ "$enter_kicks" -lt 2 ]; then
          tmux send-keys -t "$target" Enter 2>/dev/null || true
          enter_kicks=$((enter_kicks + 1))
        fi
      fi
    done

    # Window exhausted without fresh BUSY. Log to stderr and let outer retry handle it.
    echo "doey_send_verified: no BUSY transition within 5s on attempt $attempt/$max_retries (target=$target)" >&2
    # fall through to next iteration of outer while — DO NOT return 0 here.
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

# doey_send_launch <target_pane> <cmd_string> [grace_s] [max_kicks]
#
# Posts a long worker-launch shell command (e.g. `claude --dangerously-skip...`)
# to a pane and verifies that the command actually executes. Defends against
# the bracketed-paste-leak race (task 621): when a stray `\e[200~` arrives in
# stdin during shell init, readline enters paste mode and a subsequent Enter
# becomes a literal newline rather than a line-submit — the long claude command
# sits at the prompt typed but never executed.
#
# Strategy:
#   0. Pre-clear: copy-mode off, send `\e[201~` (close any pending paste),
#      send C-c (kill input line). Wait briefly for shell to redraw.
#   1. Send the cmd_string + Enter via tmux send-keys (matches existing pattern).
#   2. Verify by polling for the Claude prompt (`❯`) for up to grace_s seconds.
#   3. If `❯` appears → log "launch ok (kicks=N)" and return 0.
#   4. Otherwise: capture last 5 lines. If the shell prompt and command text
#      are still visible, kick by sending `\e[201~` + Enter (close any open
#      paste then submit), and repeat the verify step.
#   5. After max_kicks failed kicks, log a clear failure stage and return 1.
#
# Args:
#   target     — tmux pane target (session:window.pane)
#   cmd_string — the shell command line to execute
#   grace_s    — seconds to wait for `❯` per iteration (default 5)
#   max_kicks  — number of Enter kicks to attempt after the initial send (default 3)
#
# Returns 0 on success, non-zero on failure.
doey_send_launch() {
  local target="$1"
  local cmd_string="$2"
  local grace_s="${3:-5}"
  local max_kicks="${4:-3}"

  # ── Step 0: Pre-clear input state ──
  # Close any pending bracketed paste (\e[201~) then SIGINT to clear the line.
  # This is the defense against the task-621 bracketed-paste leak.
  # Atomic: combine \e[201~ + C-c into one send-keys so the close ESC isn't
  # parsed alone before `[201~` arrives (task 647).
  tmux copy-mode -q -t "$target" 2>/dev/null || true
  tmux send-keys -t "$target" $'\033[201~' C-c 2>/dev/null || true
  sleep 0.15

  # ── Step 1: Send the command + Enter ──
  if ! tmux send-keys -t "$target" "$cmd_string" Enter 2>/dev/null; then
    echo "doey_send_launch: send-keys failed at stage=sent target=$target" >&2
    return 1
  fi

  # First-word fingerprint of the command — used to detect whether the line
  # is still typed at the prompt (i.e. Enter was dropped).
  local cmd_head
  cmd_head="${cmd_string%% *}"
  # Strip any leading `read -t 1 ...; ` _DRAIN_STDIN prefix so the fingerprint
  # picks the actual binary (e.g. `claude` or `/path/to/marker.sh`).
  case "$cmd_head" in
    read) cmd_head="${cmd_string##*; }"; cmd_head="${cmd_head%% *}" ;;
  esac

  # ── Step 2..4: Verify-then-kick loop ──
  local kicks=0
  while [ "$kicks" -le "$max_kicks" ]; do
    local elapsed=0
    local interval=1
    # First check immediately (after the initial send most launches are fast)
    local cap
    cap=$(tmux capture-pane -t "$target" -p -S -50 2>/dev/null) || cap=""
    if printf '%s' "$cap" | "$DOEY_GREP" -qF '❯' 2>/dev/null; then
      echo "doey_send_launch: launch ok (kicks=$kicks) target=$target" >&2
      return 0
    fi
    while [ "$elapsed" -lt "$grace_s" ]; do
      sleep "$interval"
      elapsed=$((elapsed + interval))
      cap=$(tmux capture-pane -t "$target" -p -S -50 2>/dev/null) || cap=""
      if printf '%s' "$cap" | "$DOEY_GREP" -qF '❯' 2>/dev/null; then
        echo "doey_send_launch: launch ok (kicks=$kicks) target=$target" >&2
        return 0
      fi
    done

    if [ "$kicks" -eq 0 ]; then
      echo "doey_send_launch: stage=first_grace_no_prompt target=$target — kicking" >&2
    fi

    if [ "$kicks" -ge "$max_kicks" ]; then
      break
    fi

    # Kick decision: only kick if shell prompt AND typed command are visible.
    local last5
    last5=$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null) || last5=""
    local prompt_visible=0 cmd_visible=0
    if printf '%s' "$last5" | "$DOEY_GREP" -qE '(\$|#|>) *$' 2>/dev/null; then
      prompt_visible=1
    fi
    if [ -n "$cmd_head" ] && printf '%s' "$last5" | "$DOEY_GREP" -qF "$cmd_head" 2>/dev/null; then
      cmd_visible=1
    fi
    if [ "$prompt_visible" = "1" ] && [ "$cmd_visible" = "1" ]; then
      # Close any open bracketed paste, then Enter to submit — ONE atomic
      # write so the close ESC isn't parsed alone (task 647).
      tmux send-keys -t "$target" $'\033[201~' Enter 2>/dev/null || true
      kicks=$((kicks + 1))
      continue
    fi

    # Neither prompt+cmd visible nor `❯` found — something else is happening
    # (e.g. shell still booting, command running but not yet at ❯). Loop again
    # to keep polling for `❯` rather than kicking blindly.
    kicks=$((kicks + 1))
  done

  echo "doey_send_launch: stage=kicks_exhausted target=$target after $max_kicks kicks" >&2
  return 1
}
