#!/bin/bash
# Doey CLI — Control & Lifecycle Commands
# Sourced by doey.sh — do not run directly.

# ── Stop ──

doey_cli_stop_worker() {
  local wpane="$1"

  if [ -z "$wpane" ]; then
    printf "%s%sUsage:%s doey stop-worker <W.pane>  (e.g. doey stop-worker 1.3)\n" "$BOLD" "$ERROR" "$RESET"
    return 1
  fi

  local window="${wpane%%.*}"
  local pane="${wpane##*.}"

  if [ "$window" = "$wpane" ] || [ "$pane" = "$wpane" ] || [ -z "$window" ] || [ -z "$pane" ]; then
    printf "%s%sError:%s Invalid format '%s'. Expected W.pane (e.g. 1.3)\n" "$BOLD" "$ERROR" "$RESET" "$wpane"
    return 1
  fi

  if [ "$pane" = "0" ]; then
    printf "%s%sError:%s Pane 0 is the Window Manager and cannot be stopped this way.\n" "$BOLD" "$ERROR" "$RESET"
    return 1
  fi

  require_running_session

  local target="${session}:${window}.${pane}"
  local pane_pid
  pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null) || {
    printf "%s%sError:%s Pane %s does not exist.\n" "$BOLD" "$ERROR" "$RESET" "$wpane"
    return 1
  }

  if [ -z "$pane_pid" ]; then
    printf "%s%sError:%s Could not get PID for pane %s.\n" "$BOLD" "$ERROR" "$RESET" "$wpane"
    return 1
  fi

  local child_pid
  child_pid=$(pgrep -P "$pane_pid" | head -1)

  if [ -z "$child_pid" ]; then
    printf "%s%sWarn:%s No child process found in pane %s.\n" "$BOLD" "$WARN" "$RESET" "$wpane"
    write_pane_status "$runtime_dir" "$target" "FINISHED"
    return 0
  fi

  printf "%sStopping worker in pane %s (pid %s)...%s\n" "$DIM" "$wpane" "$child_pid" "$RESET"

  kill -TERM "$child_pid" 2>/dev/null

  local waited=0
  while [ "$waited" -lt 3 ]; do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null
    printf "%s%sForce-killed worker (pid %s).%s\n" "$BOLD" "$WARN" "$child_pid" "$RESET"
  fi

  write_pane_status "$runtime_dir" "$target" "FINISHED"

  printf "%s%sStopped worker in pane %s.%s\n" "$BOLD" "$SUCCESS" "$wpane" "$RESET"
}

doey_cli_stop_all_workers() {
  require_running_session

  local tw
  tw="$(read_team_windows "$runtime_dir")"
  if [ -z "$tw" ]; then
    printf "%s\n" "${WARN}No team windows found.${RESET}"
    return 0
  fi

  local windows_str="${tw//,/ }"
  local total_stopped=0
  local team_count=0

  for w in $windows_str; do
    local team_env="${runtime_dir}/team_${w}.env"
    if [ ! -f "$team_env" ]; then
      printf "%s\n" "${DIM}Skipping window ${w}: no team env${RESET}"
      continue
    fi

    WORKER_PANES=""
    safe_source_session_env "$team_env"

    if [ -z "$WORKER_PANES" ]; then
      printf "%s\n" "${DIM}Skipping window ${w}: no worker panes${RESET}"
      continue
    fi

    local panes_str="${WORKER_PANES//,/ }"
    local window_stopped=0

    for p in $panes_str; do
      local pane_id="${session}:${w}.${p}"
      local pane_pid
      pane_pid="$(tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null)" || continue

      if [ -z "$pane_pid" ]; then
        continue
      fi

      local child_pid
      child_pid="$(pgrep -P "$pane_pid" 2>/dev/null | head -1)" || true

      if [ -n "$child_pid" ]; then
        kill -TERM "$child_pid" 2>/dev/null || true
        local waited=0
        while [ "$waited" -lt 20 ]; do
          if ! kill -0 "$child_pid" 2>/dev/null; then
            break
          fi
          sleep 0.1
          waited=$((waited + 1))
        done
        if kill -0 "$child_pid" 2>/dev/null; then
          kill -KILL "$child_pid" 2>/dev/null || true
        fi
      fi

      write_pane_status "$runtime_dir" "$pane_id" "FINISHED"
      window_stopped=$((window_stopped + 1))
    done

    total_stopped=$((total_stopped + window_stopped))
    team_count=$((team_count + 1))
    printf "%s\n" "${DIM}Window ${w}: stopped ${window_stopped} worker(s)${RESET}"
  done

  printf "%s\n" "${SUCCESS}${BOLD}Stopped ${total_stopped} workers across ${team_count} teams.${RESET}"
}

# ── Kill ──

doey_cli_kill_session() {
    require_running_session

    printf "%s\n" "${WARN}This will kill the entire session: ${BOLD}${session}${RESET}"
    printf "Type 'yes' to confirm: "
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        printf "%s\n" "Cancelled"
        return 0
    fi

    local pane_pids=""
    pane_pids=$(tmux list-panes -t "$session" -a -F '#{pane_pid}' 2>/dev/null)
    for ppid in $pane_pids; do
        local children=""
        children=$(pgrep -P "$ppid" 2>/dev/null) || true
        for child in $children; do
            kill -TERM "$child" 2>/dev/null || true
        done
    done

    sleep 2

    for ppid in $pane_pids; do
        local children=""
        children=$(pgrep -P "$ppid" 2>/dev/null) || true
        for child in $children; do
            kill -KILL "$child" 2>/dev/null || true
        done
    done

    tmux kill-session -t "$session" 2>/dev/null || true
    rm -rf "$runtime_dir"

    printf "%s\n" "${SUCCESS}Session ${BOLD}${session}${RESET}${SUCCESS} killed${RESET}"
}

doey_cli_kill_all() {
    local sessions=""
    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^doey-') || true

    if [ -z "$sessions" ]; then
        printf "%s\n" "No doey sessions running"
        return 0
    fi

    local count=0
    printf "%s\n" "${WARN}Found doey sessions:${RESET}"
    for s in $sessions; do
        printf "  %s\n" "${BOLD}${s}${RESET}"
        count=$((count + 1))
    done

    printf "Type 'yes' to kill all %d session(s): " "$count"
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        printf "%s\n" "Cancelled"
        return 0
    fi

    for s in $sessions; do
        local pane_pids=""
        pane_pids=$(tmux list-panes -t "$s" -a -F '#{pane_pid}' 2>/dev/null) || true
        for ppid in $pane_pids; do
            local children=""
            children=$(pgrep -P "$ppid" 2>/dev/null) || true
            for child in $children; do
                kill -TERM "$child" 2>/dev/null || true
            done
        done
    done

    sleep 2

    for s in $sessions; do
        local pane_pids=""
        pane_pids=$(tmux list-panes -t "$s" -a -F '#{pane_pid}' 2>/dev/null) || true
        for ppid in $pane_pids; do
            local children=""
            children=$(pgrep -P "$ppid" 2>/dev/null) || true
            for child in $children; do
                kill -KILL "$child" 2>/dev/null || true
            done
        done
        tmux kill-session -t "$s" 2>/dev/null || true
    done

    rm -rf /tmp/doey/*/

    printf "%s\n" "${SUCCESS}Killed ${BOLD}${count}${RESET}${SUCCESS} session(s)${RESET}"
}

# ── Restart ──

doey_cli_restart_window() {
  local window="$1"

  if [ -z "$window" ]; then
    printf "%s%sUsage:%s doey restart-window <window-index>\n" "$BOLD" "$ERROR" "$RESET"
    return 1
  fi

  case "$window" in
    *[!0-9]*|"")
      printf "%s%sError:%s window index must be an integer\n" "$BOLD" "$ERROR" "$RESET"
      return 1
      ;;
  esac

  require_running_session

  local team_env="${runtime_dir}/team_${window}.env"
  if [ ! -f "$team_env" ]; then
    printf "%s%sError:%s no team env found at %s\n" "$BOLD" "$ERROR" "$RESET" "$team_env"
    return 1
  fi

  safe_source_session_env "$team_env"

  if [ -z "$WORKER_PANES" ]; then
    printf "%s%sError:%s WORKER_PANES not set in %s\n" "$BOLD" "$ERROR" "$RESET" "$team_env"
    return 1
  fi

  local panes_str="${WORKER_PANES//,/ }"
  local system_prompt="${runtime_dir}/worker-system-prompt.md"

  local result_panes=""
  local result_statuses=""

  for p in $panes_str; do
    local target="${session}:${window}.${p}"
    local status="failed"

    printf "%sChecking pane %s.%s...%s\n" "$DIM" "$window" "$p" "$RESET"

    local pane_pid=""
    pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null) || true

    if [ -n "$pane_pid" ]; then
      local child_pid=""
      child_pid=$(pgrep -P "$pane_pid" 2>/dev/null | head -1) || true

      if [ -z "$child_pid" ]; then
        local tail_output=""
        tail_output=$(tmux capture-pane -t "$target" -p -S -3 2>/dev/null) || true
        case "$tail_output" in
          *"❯"*)
            printf "  %s%s.%s%s  ○ already idle\n" "$DIM" "$window" "$p" "$RESET"
            result_panes="${result_panes} ${p}"
            result_statuses="${result_statuses} skipped"
            continue
            ;;
        esac
      fi

      if [ -n "$child_pid" ]; then
        kill "$child_pid" 2>/dev/null || true

        local attempt=0
        while [ "$attempt" -lt 5 ]; do
          sleep 1
          if ! kill -0 "$child_pid" 2>/dev/null; then
            break
          fi
          attempt=$((attempt + 1))
        done

        if kill -0 "$child_pid" 2>/dev/null; then
          kill -9 "$child_pid" 2>/dev/null || true
          sleep 1
        fi
      fi
    fi

    tmux copy-mode -q -t "$target" 2>/dev/null || true
    tmux send-keys -t "$target" "clear" Enter
    sleep 1

    local launch_cmd="claude --dangerously-skip-permissions --model opus"
    if [ -f "$system_prompt" ]; then
      launch_cmd="claude --dangerously-skip-permissions --model opus --system-prompt ${system_prompt}"
    fi

    tmux send-keys -t "$target" "$launch_cmd" Enter

    local boot_attempt=0
    local booted=0
    while [ "$boot_attempt" -lt 10 ]; do
      sleep 5
      local capture=""
      capture=$(tmux capture-pane -t "$target" -p -S -3 2>/dev/null) || true
      case "$capture" in
        *"❯"*)
          booted=1
          break
          ;;
      esac
      boot_attempt=$((boot_attempt + 1))
    done

    if [ "$booted" -eq 1 ]; then
      status="restarted"
      write_pane_status "$runtime_dir" "${session}:${window}.${p}" "READY" "" 2>/dev/null || true
    else
      status="failed"
    fi

    result_panes="${result_panes} ${p}"
    result_statuses="${result_statuses} ${status}"
  done

  printf "\n%s%sWindow %s restart:%s\n" "$BOLD" "$SUCCESS" "$window" "$RESET"

  set -- $result_panes
  local pane_list="$*"
  set -- $result_statuses
  local status_list="$*"

  local i=1
  for rp in $pane_list; do
    local rs=""
    local j=1
    for s in $status_list; do
      if [ "$j" -eq "$i" ]; then
        rs="$s"
        break
      fi
      j=$((j + 1))
    done

    case "$rs" in
      restarted)
        printf "  %s%s.%s%s  %s✓ restarted%s\n" "$BOLD" "$window" "$rp" "$RESET" "$SUCCESS" "$RESET"
        ;;
      skipped)
        printf "  %s%s.%s%s  %s○ already idle%s\n" "$DIM" "$window" "$rp" "$RESET" "$DIM" "$RESET"
        ;;
      failed)
        printf "  %s%s.%s%s  %s✗ failed%s\n" "$BOLD" "$window" "$rp" "$RESET" "$ERROR" "$RESET"
        ;;
    esac

    i=$((i + 1))
  done
}

doey_cli_restart_workers() {
  printf "%s%sDeprecated:%s doey restart-workers is deprecated. Use: doey restart-window <W>\n" "$BOLD" "$WARN" "$RESET"
  printf "\n  Example: %sdoey restart-window 1%s\n" "$BOLD" "$RESET"
  return 1
}

# ── Watchdog ──

doey_cli_watchdog_compact() {
  require_running_session

  local team_windows
  team_windows="$(read_team_windows "$runtime_dir")"

  local window="${1:-}"
  if [ -z "$window" ]; then
    window="${team_windows%%,*}"
  fi

  if [ -z "$window" ]; then
    printf "%s%sError:%s No team windows found.\n" "$BOLD" "$ERROR" "$RESET"
    return 1
  fi

  local team_env="${runtime_dir}/team_${window}.env"
  if [ ! -f "$team_env" ]; then
    printf "%s%sError:%s Team env not found for window %s\n" "$BOLD" "$ERROR" "$RESET" "$window"
    return 1
  fi

  safe_source_session_env "$team_env"

  if [ -z "${WATCHDOG_PANE:-}" ]; then
    printf "%s%sError:%s No WATCHDOG_PANE defined for team window %s\n" "$BOLD" "$ERROR" "$RESET" "$window"
    return 1
  fi

  tmux copy-mode -q -t "${session}:${WATCHDOG_PANE}" 2>/dev/null
  tmux send-keys -t "${session}:${WATCHDOG_PANE}" "/compact" Enter

  printf "Compacting watchdog for team window %s...\n" "$window"
  sleep 15

  local output
  output="$(tmux capture-pane -t "${session}:${WATCHDOG_PANE}" -p -S -3 2>/dev/null)"

  if [ -n "$output" ]; then
    printf "%s%sSuccess:%s Watchdog for team window %s is running.\n" "$BOLD" "$SUCCESS" "$RESET" "$window"
  else
    printf "%s%sWarning:%s Watchdog for team window %s may not be responding.\n" "$BOLD" "$WARN" "$RESET" "$window"
  fi
}
