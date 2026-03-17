#!/bin/bash
# Doey CLI — Monitoring & Status Commands
# Sourced by doey.sh — do not run directly.
#
# Assumes these are available from doey.sh:
#   Color vars: $BOLD, $RESET, $DIM, $SUCCESS, $ERROR, $WARNING
#   require_running_session — sets $session, $runtime_dir, $dir
#   safe_source_session_env "$file" — sources session.env safely
#   session_exists "$name" — checks if tmux session exists

# ---------------------------------------------------------------------------
# doey status [W] — show worker status for a team window (or all)
# ---------------------------------------------------------------------------
doey_cli_status() {
  local win_filter="${1:-}"
  require_running_session
  safe_source_session_env "${runtime_dir}/session.env"

  local team_windows="${TEAM_WINDOWS:-}"
  if [ -z "$team_windows" ]; then
    echo "${ERROR}No team windows found in session.env${RESET}"
    return 1
  fi

  # If a specific window requested, filter
  if [ -n "$win_filter" ]; then
    local found=0
    local old_ifs="$IFS"
    IFS=","
    for w in $team_windows; do
      if [ "$w" = "$win_filter" ]; then
        found=1
        break
      fi
    done
    IFS="$old_ifs"
    if [ "$found" -eq 0 ]; then
      echo "${ERROR}Window ${win_filter} not found in TEAM_WINDOWS (${team_windows})${RESET}"
      return 1
    fi
    team_windows="$win_filter"
  fi

  local old_ifs="$IFS"
  IFS=","
  local first_window=1
  for W in $team_windows; do
    IFS="$old_ifs"

    # Source team env to get WORKER_PANES
    WORKER_PANES=""
    safe_source_session_env "${runtime_dir}/team_${W}.env"
    local worker_panes="${WORKER_PANES:-}"

    if [ -z "$worker_panes" ]; then
      echo "${WARNING}Window ${W}: no worker panes found${RESET}"
      echo ""
      continue
    fi

    # Print window header
    if [ "$first_window" -eq 0 ]; then
      echo ""
    fi
    first_window=0
    echo "${BOLD}Window ${W}${RESET}"
    printf "  %-8s %-20s %-10s %-10s %-30s %-12s\n" "PANE" "TITLE" "STATUS" "RESERVED" "TASK" "UPDATED"
    printf "  %-8s %-20s %-10s %-10s %-30s %-12s\n" "--------" "--------------------" "----------" "----------" "------------------------------" "------------"

    local inner_ifs="$IFS"
    IFS=","
    for P in $worker_panes; do
      IFS="$inner_ifs"

      local pane_id="${W}.${P}"
      local pane_safe
      pane_safe=$(echo "${session}_${W}_${P}" | sed 's/[:\.]/_/g')

      local status_file="${runtime_dir}/status/${pane_safe}.status"
      local status="UNKNOWN"
      local task="-"
      local updated="-"

      if [ -f "$status_file" ]; then
        local s
        s=$(grep '^STATUS: ' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS: //')
        if [ -n "$s" ]; then
          status="$s"
        fi
        local t
        t=$(grep '^TASK: ' "$status_file" 2>/dev/null | head -1 | sed 's/^TASK: //')
        if [ -n "$t" ]; then
          task="$t"
        fi
        local u
        u=$(grep '^UPDATED: ' "$status_file" 2>/dev/null | head -1 | sed 's/^UPDATED: //')
        if [ -n "$u" ]; then
          updated="$u"
        fi
      fi

      # Check reserved
      local reserved="no"
      if [ -f "${runtime_dir}/status/${pane_safe}.reserved" ]; then
        reserved="yes"
      fi

      # Get pane title
      local title
      title=$(tmux display-message -t "${session}:${W}.${P}" -p '#{pane_title}' 2>/dev/null || echo "-")
      # Truncate title to 18 chars
      if [ ${#title} -gt 18 ]; then
        title=$(echo "$title" | cut -c1-18)".."
      fi

      # Truncate task to 28 chars
      if [ ${#task} -gt 28 ]; then
        task=$(echo "$task" | cut -c1-28)".."
      fi

      # Color based on status
      local color="$DIM"
      case "$status" in
        READY|FINISHED) color="$SUCCESS" ;;
        BUSY)           color="$WARNING" ;;
        ERROR|CRASHED)  color="$ERROR" ;;
      esac

      printf "  ${color}%-8s %-20s %-10s %-10s %-30s %-12s${RESET}\n" \
        "$pane_id" "$title" "$status" "$reserved" "$task" "$updated"

      IFS=","
    done
    IFS="$inner_ifs"

    # Watchdog heartbeat
    local heartbeat_file="${runtime_dir}/status/watchdog_W${W}.heartbeat"
    if [ -f "$heartbeat_file" ]; then
      local hb_time
      hb_time=$(cat "$heartbeat_file" 2>/dev/null)
      if [ -n "$hb_time" ]; then
        local now
        now=$(date +%s)
        local age=$((now - hb_time))
        if [ "$age" -gt 120 ]; then
          echo "  ${ERROR}Watchdog: stale heartbeat (${age}s ago)${RESET}"
        else
          echo "  ${SUCCESS}Watchdog: healthy (${age}s ago)${RESET}"
        fi
      else
        echo "  ${DIM}Watchdog: no heartbeat data${RESET}"
      fi
    else
      echo "  ${DIM}Watchdog: no heartbeat file${RESET}"
    fi

    IFS=","
  done
  IFS="$old_ifs"
}

# ---------------------------------------------------------------------------
# doey monitor [--watch] — status with optional continuous polling
# ---------------------------------------------------------------------------
doey_cli_monitor() {
  require_running_session

  local _show_crashes
  _show_crashes() {
    local crash_file
    for crash_file in "${runtime_dir}/status/crash_pane_"*; do
      [ -f "$crash_file" ] || continue
      local cname
      cname="$(basename "$crash_file")"
      echo "${ERROR}CRASH: ${cname}${RESET}"
      cat "$crash_file"
      echo ""
    done
  }

  if [ "${1:-}" = "--watch" ]; then
    trap 'return 0' INT
    while true; do
      clear
      date
      echo ""
      doey_cli_status
      echo ""
      _show_crashes
      sleep 15
    done
  else
    doey_cli_status
    echo ""
    _show_crashes
  fi
}

# ---------------------------------------------------------------------------
# doey team [W] — full team overview (all panes, all roles)
# ---------------------------------------------------------------------------
doey_cli_team() {
  local filter_win="${1:-}"
  require_running_session
  safe_source_session_env "${runtime_dir}/session.env"

  local header
  header=$(printf "%-8s %-12s %-20s %-10s %-10s %-30s" "PANE" "ROLE" "TITLE" "STATUS" "RESERVED" "TASK")
  echo "${BOLD}${header}${RESET}"
  printf "%-8s %-12s %-20s %-10s %-10s %-30s\n" "--------" "------------" "--------------------" "----------" "----------" "------------------------------"

  tmux list-panes -s -t "$session" -F '#{window_index} #{pane_index} #{pane_title} #{pane_pid}' | while IFS=' ' read -r win pane title pid; do
    # Filter by window if requested
    if [ -n "$filter_win" ] && [ "$win" != "$filter_win" ]; then
      continue
    fi

    # Determine role
    local role=""
    if [ "$win" = "0" ]; then
      if [ "$pane" = "0" ]; then
        role="InfoPanel"
      elif [ "$pane" = "1" ]; then
        role="SessionMgr"
      else
        role="Watchdog"
      fi
    else
      if [ "$pane" = "0" ]; then
        role="Manager"
      else
        role="Worker"
      fi
    fi

    # Build safe pane name for status files
    local pane_safe="${session}_${win}_${pane}"
    pane_safe=$(echo "$pane_safe" | sed 's/[:\.]/_/g')

    # Read status file
    local status_val=""
    local task_val=""
    local status_file="${runtime_dir}/status/${pane_safe}.status"
    if [ -f "$status_file" ]; then
      status_val=$(grep '^STATUS: ' "$status_file" 2>/dev/null | head -1 | sed 's/^STATUS: //')
      task_val=$(grep '^TASK: ' "$status_file" 2>/dev/null | head -1 | sed 's/^TASK: //')
    fi

    # Check reserved
    local reserved=""
    if [ -f "${runtime_dir}/status/${pane_safe}.reserved" ]; then
      reserved="yes"
    fi

    # Pick color based on status
    local color=""
    case "$status_val" in
      READY|FINISHED) color="$SUCCESS" ;;
      BUSY)           color="$WARNING" ;;
      ERROR|CRASHED)  color="$ERROR" ;;
      *)              color="$DIM" ;;
    esac

    # Truncate task to 30 chars
    if [ ${#task_val} -gt 30 ]; then
      task_val="${task_val:0:27}..."
    fi

    # Truncate title to 20 chars
    if [ ${#title} -gt 20 ]; then
      title="${title:0:17}..."
    fi

    local pane_id="${win}.${pane}"
    local line
    line=$(printf "%-8s %-12s %-20s %-10s %-10s %-30s" "$pane_id" "$role" "$title" "$status_val" "$reserved" "$task_val")
    echo "${color}${line}${RESET}"
  done
}

# ---------------------------------------------------------------------------
# doey reserve <W.pane> [off] / doey reserve list
# ---------------------------------------------------------------------------
doey_cli_reserve() {
  require_running_session

  local subcmd="${1:-}"

  # No arguments — print usage
  if [ -z "$subcmd" ]; then
    echo "${BOLD}Usage:${RESET} doey reserve <W.pane> [off]"
    echo "       doey reserve list"
    echo ""
    echo "Reserve a worker pane for human use, or unreserve with 'off'."
    echo "List current reservations with 'list'."
    return 0
  fi

  # Subcommand: list
  if [ "$subcmd" = "list" ]; then
    local found=0
    local f base
    for f in "${runtime_dir}/status/"*.reserved; do
      [ -f "$f" ] || continue
      base="$(basename "$f" .reserved)"
      # Extract W and pane from pane_safe (last two _-separated segments)
      local pane_part w_part rest
      pane_part="${base##*_}"
      rest="${base%_*}"
      w_part="${rest##*_}"
      echo "  Pane ${w_part}.${pane_part}  $(head -1 "$f")"
      found=1
    done
    if [ "$found" -eq 0 ]; then
      echo "No reservations"
    fi
    return 0
  fi

  # Validate W.pane pattern
  case "$subcmd" in
    *.*) ;;
    *)
      echo "${ERROR}Invalid pane format: ${subcmd}${RESET}" >&2
      echo "Expected format: W.pane (e.g. 1.3)" >&2
      return 1
      ;;
  esac

  local w_num pane_num
  w_num="${subcmd%%.*}"
  pane_num="${subcmd#*.}"

  # Validate pane is not 0 (Manager)
  if [ "$pane_num" = "0" ]; then
    echo "${ERROR}Cannot reserve pane 0 — that's the Window Manager${RESET}" >&2
    return 1
  fi

  # Validate pane exists
  if ! tmux display-message -t "${session}:${w_num}.${pane_num}" -p '#{pane_index}' >/dev/null 2>&1; then
    echo "${ERROR}Pane ${w_num}.${pane_num} does not exist in session ${session}${RESET}" >&2
    return 1
  fi

  # Compute pane_safe identifier
  local pane_safe
  pane_safe="$(echo "${session}_${w_num}_${pane_num}" | sed 's/[:\.]/_/g')"

  local reserve_file="${runtime_dir}/status/${pane_safe}.reserved"

  if [ "${2:-}" = "off" ]; then
    # Unreserve
    if [ -f "$reserve_file" ]; then
      rm -f "$reserve_file"
    fi
    echo "${SUCCESS}Unreserved pane ${w_num}.${pane_num}${RESET}"
  else
    # Reserve
    mkdir -p "${runtime_dir}/status"
    printf "RESERVED_BY: cli\nTIMESTAMP: %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" > "$reserve_file"
    echo "${SUCCESS}Reserved pane ${w_num}.${pane_num}${RESET}"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# doey analyze — dispatch /doey-analyze to Window Manager
# ---------------------------------------------------------------------------
doey_cli_analyze() {
  require_running_session
  safe_source_session_env "${runtime_dir}/session.env"

  local first_window
  first_window="$(echo "${TEAM_WINDOWS:-}" | cut -d, -f1)"

  if [ -z "$first_window" ]; then
    echo "${ERROR}No team windows found${RESET}"
    return 1
  fi

  tmux send-keys -t "${session}:${first_window}.0" "/doey-analyze" Enter
  echo "Dispatched /doey-analyze to Window Manager (window ${first_window})"
}
