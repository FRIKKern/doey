#!/bin/bash
# Doey CLI — Task Dispatch Commands
# Sourced by doey.sh — do not run directly.

doey_cli_dispatch() {
  local task="$1"
  local target_spec="$2"

  if [ -z "$task" ] || [ -z "$target_spec" ]; then
    echo "${ERROR}Usage:${RESET} doey dispatch \"task text\" <W.pane>"
    echo "  Example: doey dispatch \"Fix the login bug\" 1.3"
    return 1
  fi

  # Split W.pane on "." into window_idx and pane_idx
  local window_idx pane_idx
  case "$target_spec" in
    *.*)
      window_idx="${target_spec%%.*}"
      pane_idx="${target_spec##*.}"
      ;;
    *)
      echo "${ERROR}Invalid pane format:${RESET} $target_spec (expected W.pane, e.g. 1.3)"
      return 1
      ;;
  esac

  # Validate window_idx and pane_idx are numeric
  case "$window_idx" in
    ''|*[!0-9]*) echo "${ERROR}Invalid window index:${RESET} $window_idx"; return 1 ;;
  esac
  case "$pane_idx" in
    ''|*[!0-9]*) echo "${ERROR}Invalid pane index:${RESET} $pane_idx"; return 1 ;;
  esac

  # Get session info
  require_running_session
  local target="${session}:${window_idx}.${pane_idx}"

  # Load session env for PROJECT_NAME and PROJECT_DIR
  safe_source_session_env "${runtime_dir}/session.env"

  # Load team env (warn if missing but continue)
  local team_env="${runtime_dir}/team_${window_idx}.env"
  if [ -f "$team_env" ]; then
    safe_source_session_env "$team_env"
  else
    echo "${WARNING}Warning:${RESET} Team env not found: $team_env (continuing anyway)"
  fi

  # Validate pane is a worker (not pane 0 = Window Manager)
  if [ "$pane_idx" = "0" ]; then
    echo "${ERROR}Error:${RESET} Pane ${window_idx}.0 is the Window Manager, not a worker"
    return 1
  fi

  # Check reservation
  local reserved_file="${runtime_dir}/status/${session}_${window_idx}_${pane_idx}.reserved"
  if [ -f "$reserved_file" ]; then
    echo "${ERROR}Error:${RESET} Pane ${window_idx}.${pane_idx} is reserved"
    return 1
  fi

  # Check if idle (look for prompt indicator)
  local pane_output
  pane_output="$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null)" || true
  if ! echo "$pane_output" | grep -q '❯'; then
    echo "${WARNING}Warning:${RESET} Worker appears busy (proceeding anyway)"
  fi

  # Write task to tmpfile
  local tmpfile
  tmpfile="$(mktemp "${runtime_dir}/task_cli_XXXXXX.txt")"

  cat > "$tmpfile" <<TASKEOF
You are a worker on Doey for project: ${PROJECT_NAME:-unknown}
Project directory: ${PROJECT_DIR:-unknown}
All file paths should be absolute.

${task}
TASKEOF

  # Dispatch
  tmux copy-mode -q -t "$target" 2>/dev/null || true
  tmux load-buffer "$tmpfile"
  tmux paste-buffer -t "$target"
  sleep 0.5
  tmux send-keys -t "$target" Enter

  # Verify dispatch started
  sleep 5
  local verify_output
  verify_output="$(tmux capture-pane -t "$target" -p -S -10 2>/dev/null)" || true

  # Clean up tmpfile
  rm -f "$tmpfile"

  # Report result
  if echo "$verify_output" | grep -qE "thinking|working|Read|Edit|Bash|Write|Grep|Glob"; then
    echo "${SUCCESS}Dispatched task to ${window_idx}.${pane_idx}${RESET}"
  else
    echo "${WARNING}Warning:${RESET} Task sent to ${window_idx}.${pane_idx} but dispatch may not have started"
  fi
}

doey_cli_delegate() {
  local task_text="$1"
  local window="${2:-}"

  if [ -z "$task_text" ]; then
    echo "${ERROR}Usage: doey delegate \"task text\" [window]${RESET}"
    echo "${DIM}  window  Team window number (default: first team window)${RESET}"
    return 1
  fi

  require_running_session

  safe_source_session_env "${runtime_dir}/session.env"

  # Default to first team window if not specified
  if [ -z "$window" ]; then
    window="$(echo "$TEAM_WINDOWS" | cut -d',' -f1)"
    if [ -z "$window" ]; then
      echo "${ERROR}No team windows found${RESET}"
      return 1
    fi
  fi

  local target="${session}:${window}.0"

  # Check if WM is idle
  local pane_output
  pane_output="$(tmux capture-pane -t "${target}" -p -S -5 2>/dev/null || true)"
  if ! echo "$pane_output" | grep -q '❯'; then
    echo "${WARNING}Window Manager appears busy${RESET}"
  fi

  # Write task to tmpfile
  local tmpfile
  tmpfile="$(mktemp "${runtime_dir}/task_cli_XXXXXX.txt")"
  printf '%s' "$task_text" > "$tmpfile"

  # Dispatch via paste-buffer
  tmux copy-mode -q -t "${target}" 2>/dev/null || true
  tmux load-buffer "$tmpfile"
  tmux paste-buffer -t "${target}"
  sleep 0.5
  tmux send-keys -t "${target}" Enter

  # Verify dispatch
  sleep 5
  local verify_output
  verify_output="$(tmux capture-pane -t "${target}" -p -S -5 2>/dev/null || true)"

  # Clean up tmpfile
  rm -f "$tmpfile"

  if echo "$verify_output" | grep -qE "thinking|working|Read|Edit|Bash|dispatch|Dispatch"; then
    echo "${SUCCESS}Delegated to Window Manager ${window}.0${RESET}"
  else
    echo "${WARNING}Task sent to Window Manager ${window}.0 but activity not yet detected${RESET}"
  fi
}

doey_cli_broadcast() {
  local message="$1"
  if [ -z "$message" ]; then
    echo "${ERROR}Usage: doey broadcast \"message\"${RESET}" >&2
    return 1
  fi

  require_running_session

  safe_source_session_env "${runtime_dir}/session.env"

  mkdir -p "${runtime_dir}/broadcasts"
  mkdir -p "${runtime_dir}/messages"

  local broadcast_id="broadcast_$(date +%s)_$$"

  # Write broadcast file with metadata header
  printf "timestamp: %s\nsource: cli\n---\n%s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$message" \
    > "${runtime_dir}/broadcasts/${broadcast_id}.txt"

  local count=0
  local windows
  IFS=',' read -r -a windows <<< "$TEAM_WINDOWS"

  local w
  for w in "${windows[@]}"; do
    safe_source_session_env "${runtime_dir}/team_${w}.env"

    local panes
    IFS=',' read -r -a panes <<< "$WORKER_PANES"

    # Deliver to WM (pane 0)
    printf "%s\n" "$message" > "${runtime_dir}/messages/${session}_${w}_0_broadcast_${broadcast_id}.txt"
    count=$((count + 1))

    # Deliver to each worker pane
    local p
    for p in "${panes[@]}"; do
      printf "%s\n" "$message" > "${runtime_dir}/messages/${session}_${w}_${p}_broadcast_${broadcast_id}.txt"
      count=$((count + 1))
    done
  done

  echo "${SUCCESS}Broadcast delivered to ${count} panes${RESET}"
}

doey_cli_research() {
  local topic="$1"
  local window_idx="$2"

  if [ -z "$topic" ]; then
    echo "${ERROR}Usage:${RESET} doey research \"topic\" [W]"
    echo "  Example: doey research \"How does the hook system work?\" 1"
    return 1
  fi

  # Get session info
  require_running_session

  # Load session env for TEAM_WINDOWS
  safe_source_session_env "${runtime_dir}/session.env"

  # Default window to first team window from TEAM_WINDOWS
  if [ -z "$window_idx" ]; then
    # TEAM_WINDOWS is comma-separated, take first
    window_idx="${TEAM_WINDOWS%%,*}"
    if [ -z "$window_idx" ]; then
      echo "${ERROR}Error:${RESET} No team windows found in session.env"
      return 1
    fi
  fi

  # Validate window_idx is numeric
  case "$window_idx" in
    ''|*[!0-9]*) echo "${ERROR}Invalid window index:${RESET} $window_idx"; return 1 ;;
  esac

  local target="${session}:${window_idx}.0"

  # Check if WM is idle (look for prompt indicator)
  local pane_output
  pane_output="$(tmux capture-pane -t "$target" -p -S -5 2>/dev/null)" || true
  if ! echo "$pane_output" | grep -q '❯'; then
    echo "${WARNING}Warning:${RESET} Window Manager ${window_idx}.0 appears busy (proceeding anyway)"
  fi

  # Build delegation text
  local delegation_text="Run /doey-research on the following topic: ${topic}"

  # Write delegation text to tmpfile
  local tmpfile
  tmpfile="$(mktemp "${runtime_dir}/task_cli_XXXXXX.txt")"
  printf '%s' "$delegation_text" > "$tmpfile"

  # Dispatch
  tmux copy-mode -q -t "$target" 2>/dev/null || true
  tmux load-buffer "$tmpfile"
  tmux paste-buffer -t "$target"
  sleep 0.5
  tmux send-keys -t "$target" Enter

  # Verify dispatch started
  sleep 5
  local verify_output
  verify_output="$(tmux capture-pane -t "$target" -p -S -10 2>/dev/null)" || true

  # Clean up tmpfile
  rm -f "$tmpfile"

  # Report result
  if echo "$verify_output" | grep -qE "thinking|working|Read|Edit|Bash|Write|Grep|Glob|research"; then
    echo "${SUCCESS}Research dispatched to Window Manager ${window_idx}.0${RESET}: ${topic}"
  else
    echo "${WARNING}Warning:${RESET} Research sent to Window Manager ${window_idx}.0 but may not have started: ${topic}"
  fi
}
