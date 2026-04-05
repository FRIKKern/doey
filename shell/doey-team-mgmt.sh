#!/usr/bin/env bash
# doey-team-mgmt.sh — Team management functions for Doey.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_team_mgmt_sourced:-}" = "1" ] && return 0
__doey_team_mgmt_sourced=1

# shellcheck source=doey-helpers.sh
TEAM_MGMT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TEAM_MGMT_SCRIPT_DIR}/doey-helpers.sh"
source "${TEAM_MGMT_SCRIPT_DIR}/doey-ui.sh"
source "${TEAM_MGMT_SCRIPT_DIR}/doey-grid.sh"
source "${TEAM_MGMT_SCRIPT_DIR}/doey-roles.sh"
source "${TEAM_MGMT_SCRIPT_DIR}/doey-send.sh"

# ── Team Env ──────────────────────────────────────────────────────────

write_team_env() {
  local runtime_dir="$1" window_index="$2" grid="$3"
  local worker_panes="$4" worker_count="$5"
  local manager_pane="${6:-0}"
  local worktree_dir="${7:-}"
  local worktree_branch="${8:-}"
  local team_name="${9:-}"
  local team_role="${10:-}"
  local worker_model="${11:-}"
  local manager_model="${12:-}"
  local session_name
  session_name=$(_env_val "${runtime_dir}/session.env" SESSION_NAME)
  local team_type="${13:-}"
  local team_def="${14:-}"
  local reserved="${15:-}"
  local task_id="${16:-}"
  local _tmp="${runtime_dir}/team_${window_index}.env.tmp.$$"
  cat > "$_tmp" << TEAMEOF
WINDOW_INDEX="${window_index}"
GRID="${grid}"
MANAGER_PANE="${manager_pane}"
WORKER_PANES="${worker_panes}"
WORKER_COUNT="${worker_count}"
SESSION_NAME="${session_name}"
WORKTREE_DIR="${worktree_dir}"
WORKTREE_BRANCH="${worktree_branch}"
TEAM_NAME="${team_name}"
TEAM_ROLE="${team_role}"
WORKER_MODEL="${worker_model}"
MANAGER_MODEL="${manager_model}"
TEAM_TYPE="${team_type}"
TEAM_DEF="${team_def}"
RESERVED="${reserved}"
TASK_ID="${task_id}"
TEAMEOF
  mv "$_tmp" "${runtime_dir}/team_${window_index}.env"
}

# ── Team Agent Generation ─────────────────────────────────────────────

generate_team_agent() {
  local base_name="$1" team_num="$2"
  local role="${base_name#doey-}"
  local new_name="t${team_num}-${role}"
  local src="$HOME/.claude/agents/${base_name}.md"
  local dst="$HOME/.claude/agents/${new_name}.md"
  if [ -f "$src" ]; then
    cp "$src" "$dst"
    sed "s/name: ${base_name}/name: ${new_name}/" "$dst" > "${dst}.tmp"
    mv "${dst}.tmp" "$dst"
  fi
  echo "$new_name"
}

# ── Team Definition Lookup ───────────────────────────────────────��────

# Search hierarchy for team definition file
# Prints path to stdout on success, returns 1 if not found
_find_team_def() {
  local name="$1"
  local fname="${name}.team.md"

  # 1. Project-level teams/ (repo-shipped definitions)
  if [ -f "teams/${fname}" ]; then
    echo "teams/${fname}"; return 0
  fi
  # 2. Project-level .doey/teams/
  if [ -f ".doey/teams/${fname}" ]; then
    echo ".doey/teams/${fname}"; return 0
  fi
  # 3. Installed premade teams
  if [ -f "$HOME/.local/share/doey/teams/${fname}" ]; then
    echo "$HOME/.local/share/doey/teams/${fname}"; return 0
  fi
  # 4. Legacy user config
  if [ -f "$HOME/.config/doey/teams/${fname}" ]; then
    echo "$HOME/.config/doey/teams/${fname}"; return 0
  fi
  # 5. Doey repo shipped defaults (for non-doey projects using doey)
  local repo_path=""
  [ -f "$HOME/.claude/doey/repo-path" ] && repo_path=$(<"$HOME/.claude/doey/repo-path")
  if [ -n "$repo_path" ] && [ -f "${repo_path}/teams/${fname}" ]; then
    echo "${repo_path}/teams/${fname}"; return 0
  fi
  return 1
}

# ── Team Definition Parser ────────────────────────────────────────────

# Parse a .team.md file into a flat env file at ${runtime_dir}/teamdef_<name>.env
# Also extracts markdown body to ${runtime_dir}/teamdef_<name>_briefing.md
_parse_team_def() {
  local file="$1" runtime_dir="$2"
  local in_frontmatter=0 frontmatter_count=0 in_panes=0 in_workflow=0
  local name="" line_num=0 body_started=0
  local workflow_idx=0
  local env_file="" briefing_file=""

  # First pass: extract name from frontmatter
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "---" ]; then
      frontmatter_count=$((frontmatter_count + 1))
      [ "$frontmatter_count" -ge 2 ] && break
      continue
    fi
    if [ "$frontmatter_count" -eq 1 ]; then
      case "$line" in
        name:*) name=$(echo "$line" | sed 's/^name:[[:space:]]*//' | tr -d '"') ;;
      esac
    fi
  done < "$file"

  [ -z "$name" ] && { echo "ERROR: no name in team def $file" >&2; return 1; }
  env_file="${runtime_dir}/teamdef_${name}.env"
  briefing_file="${runtime_dir}/teamdef_${name}_briefing.md"

  # Reset for second pass
  frontmatter_count=0; in_panes=0; in_workflow=0; body_started=0; workflow_idx=0
  : > "$env_file"
  : > "$briefing_file"

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "---" ]; then
      frontmatter_count=$((frontmatter_count + 1))
      if [ "$frontmatter_count" -ge 2 ]; then
        body_started=1
        continue
      fi
      continue
    fi

    # Markdown body (after second ---)
    if [ "$body_started" -eq 1 ]; then
      # Detect section headers in markdown body for table-format team defs
      case "$line" in
        "## Panes"*) in_panes=1; in_workflow=0; continue ;;
        "## Workflows"*) in_workflow=1; in_panes=0; continue ;;
        "## Team Briefing"*) in_panes=0; in_workflow=0; continue ;;
        "## "*) in_panes=0; in_workflow=0 ;;
      esac

      # Parse markdown pane table: | Pane | Role | Agent | Name | Model |
      if [ "$in_panes" -eq 1 ]; then
        case "$line" in
          "|"*)
            echo "$line" | grep -q '^|[[:space:]]*Pane' && continue
            echo "$line" | grep -q '^|[[:space:]]*-' && continue
            local _tp_pane _tp_role _tp_agent _tp_name _tp_model
            _tp_pane=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tp_role=$(echo "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tp_agent=$(echo "$line" | cut -d'|' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tp_name=$(echo "$line" | cut -d'|' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tp_model=$(echo "$line" | cut -d'|' -f6 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$_tp_pane" ] && continue
            [ -n "$_tp_role" ] && printf 'PANE_%s_ROLE=%s\n' "$_tp_pane" "$_tp_role" >> "$env_file"
            [ -n "$_tp_agent" ] && printf 'PANE_%s_AGENT=%s\n' "$_tp_pane" "$_tp_agent" >> "$env_file"
            [ -n "$_tp_name" ] && printf 'PANE_%s_NAME=%s\n' "$_tp_pane" "$_tp_name" >> "$env_file"
            [ -n "$_tp_model" ] && printf 'PANE_%s_MODEL=%s\n' "$_tp_pane" "$_tp_model" >> "$env_file"
            ;;
        esac
        continue
      fi

      # Parse markdown workflow table: | Trigger | From | To | Subject |
      if [ "$in_workflow" -eq 1 ]; then
        case "$line" in
          "|"*)
            echo "$line" | grep -q '^|[[:space:]]*Trigger' && continue
            echo "$line" | grep -q '^|[[:space:]]*-' && continue
            local _tw_trigger _tw_from _tw_to _tw_subject
            _tw_trigger=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tw_from=$(echo "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tw_to=$(echo "$line" | cut -d'|' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            _tw_subject=$(echo "$line" | cut -d'|' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$_tw_trigger" ] && continue
            printf 'WORKFLOW_%s=%s|%s|%s|%s\n' "$workflow_idx" "$_tw_trigger" "$_tw_from" "$_tw_to" "$_tw_subject" >> "$env_file"
            workflow_idx=$((workflow_idx + 1))
            ;;
        esac
        continue
      fi

      # Everything else in body goes to briefing file
      printf '%s\n' "$line" >> "$briefing_file"
      continue
    fi

    # Inside frontmatter
    if [ "$frontmatter_count" -eq 1 ]; then
      # Detect section starts
      case "$line" in
        "panes:") in_panes=1; in_workflow=0; continue ;;
        "workflow:") in_workflow=1; in_panes=0; continue ;;
      esac

      # Pane entries:  N: { role: X, agent: Y, name: "Z" }
      if [ "$in_panes" -eq 1 ]; then
        case "$line" in
          *"{"*"}"*)
            local pane_num role="" agent="" pane_name=""
            pane_num=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
            role=$(echo "$line" | sed -n 's/.*role:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d ' ')
            agent=$(echo "$line" | sed -n 's/.*agent:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d ' ')
            pane_name=$(echo "$line" | sed -n 's/.*name:[[:space:]]*"\([^"]*\)".*/\1/p')
            [ -n "$role" ] && printf 'PANE_%s_ROLE=%s\n' "$pane_num" "$role" >> "$env_file"
            [ -n "$agent" ] && printf 'PANE_%s_AGENT=%s\n' "$pane_num" "$agent" >> "$env_file"
            [ -n "$pane_name" ] && printf 'PANE_%s_NAME=%s\n' "$pane_num" "$pane_name" >> "$env_file"
            ;;
          *) [ -z "$(echo "$line" | tr -d '[:space:]')" ] || { in_panes=0; } ;;
        esac
        [ "$in_panes" -eq 1 ] && continue
      fi

      # Workflow entries:  - on: X, from: Y, to: Z, subject: W
      if [ "$in_workflow" -eq 1 ]; then
        case "$line" in
          *"- on:"*)
            local wf_on="" wf_from="" wf_to="" wf_subject=""
            wf_on=$(echo "$line" | sed -n 's/.*on:[[:space:]]*\([^,]*\).*/\1/p' | tr -d ' ')
            wf_from=$(echo "$line" | sed -n 's/.*from:[[:space:]]*\([^,]*\).*/\1/p' | tr -d ' ')
            wf_to=$(echo "$line" | sed -n 's/.*to:[[:space:]]*\([^,]*\).*/\1/p' | tr -d ' ')
            wf_subject=$(echo "$line" | sed -n 's/.*subject:[[:space:]]*\([^,}[:space:]]*\).*/\1/p')
            printf 'WORKFLOW_%s=%s|%s|%s|%s\n' "$workflow_idx" "$wf_on" "$wf_from" "$wf_to" "$wf_subject" >> "$env_file"
            workflow_idx=$((workflow_idx + 1))
            ;;
          *) [ -z "$(echo "$line" | tr -d '[:space:]')" ] || { in_workflow=0; } ;;
        esac
        [ "$in_workflow" -eq 1 ] && continue
      fi

      # Simple key: value lines
      case "$line" in
        *:*)
          local key val
          key=$(echo "$line" | cut -d: -f1 | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
          val=$(echo "$line" | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d '"')
          [ -n "$key" ] && [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$env_file"
          ;;
      esac
    fi
  done < "$file"

  printf 'BRIEFING_FILE=%s\n' "$briefing_file" >> "$env_file"
  echo "$env_file"
}

# ── Worktree Management ──────────────────────────────────────────────

create_team_worktree() {
  local project_dir="$1" team_window="$2" branch_name="${3:-}"
  if [ -z "$branch_name" ]; then
    branch_name="doey/team-${team_window}-$(date +%m%d-%H%M)"
  fi
  local project_name
  project_name="$(basename "$project_dir")"
  local wt_path="${TMPDIR:-/tmp}/doey/${project_name}/worktrees/team-${team_window}"

  # Clean up stale worktree state from prior runs
  git -C "$project_dir" worktree prune 2>/dev/null || true
  # If a stale worktree dir exists at the target path, remove it properly
  if [ -d "$wt_path" ]; then
    git -C "$project_dir" worktree remove "$wt_path" --force 2>/dev/null || true
    git -C "$project_dir" worktree prune 2>/dev/null || true
    # Last resort: nuke the directory if git couldn't clean it
    [ -d "$wt_path" ] && rm -rf "$wt_path"
  fi
  # Remove stale branch if it exists from a prior run
  git -C "$project_dir" branch -D "$branch_name" 2>/dev/null || true

  mkdir -p "$(dirname "$wt_path")"
  if ! git -C "$project_dir" worktree add "$wt_path" -b "$branch_name" >/dev/null 2>&1; then
    if ! git -C "$project_dir" worktree add "$wt_path" "$branch_name" >/dev/null 2>&1; then
      if ! git -C "$project_dir" worktree add --force "$wt_path" -b "$branch_name" >/dev/null 2>&1; then
        echo "Error: failed to create worktree at $wt_path for branch $branch_name" >&2
        return 1
      fi
    fi
  fi
  # Copy hook settings into the worktree so Claude Code picks them up
  if [ -f "$project_dir/.claude/settings.local.json" ]; then
    mkdir -p "$wt_path/.claude"
    cp "$project_dir/.claude/settings.local.json" "$wt_path/.claude/"
  fi
  echo "$wt_path"
}

remove_team_worktree() {
  local project_dir="$1" worktree_dir="$2"
  [ -z "$worktree_dir" ] && return 0
  [ -d "$worktree_dir" ] || return 0
  git -C "$project_dir" worktree remove "$worktree_dir" --force 2>/dev/null || true
  git -C "$project_dir" worktree prune 2>/dev/null || true
}

_worktree_safe_remove() {
  local project_dir="$1" worktree_dir="$2" force="${3:-false}"
  { [ -z "$worktree_dir" ] || [ ! -d "$worktree_dir" ]; } && return 0

  local branch_name
  branch_name=$(git -C "$worktree_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  # Auto-commit uncommitted changes unless forced
  if [ "$force" != "true" ]; then
    local dirty=""
    dirty=$(git -C "$worktree_dir" status --porcelain 2>/dev/null) || true
    if [ -n "$dirty" ]; then
      git -C "$worktree_dir" add -A 2>/dev/null || true
      git -C "$worktree_dir" commit -m "doey: auto-save before teardown $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
      printf '  Worktree had uncommitted changes — auto-saved to branch: %s\n' "$branch_name"
    fi
  fi

  # Report unmerged commits
  if [ -n "$branch_name" ] && [ "$branch_name" != "HEAD" ] && [ "$branch_name" != "unknown" ]; then
    local commits_ahead
    commits_ahead=$(git -C "$project_dir" rev-list --count "HEAD..${branch_name}" 2>/dev/null || echo "0")
    if [ "$commits_ahead" -gt 0 ] 2>/dev/null; then
      printf '  Branch %s has %s commit(s). Merge with: git merge %s\n' "$branch_name" "$commits_ahead" "$branch_name"
    fi
  fi

  remove_team_worktree "$project_dir" "$worktree_dir"
}

# ── Boot Timeout Watchdog ────────────────────────────────────���────────

_check_boot_timeouts() {
  local runtime_dir="$1" session="$2" team_window="$3"
  shift 3

  local timeout="${DOEY_BOOT_TIMEOUT:-60}"
  local now pair pane_idx safe status_file status updated_str updated_epoch age
  now=$(date '+%s')

  for pair in "$@"; do
    pane_idx="${pair%%:*}"
    safe="${session}:${team_window}.${pane_idx}"
    safe="${safe//[-:.]/_}"
    status_file="${runtime_dir}/status/${safe}.status"

    [ -f "$status_file" ] || continue
    status=$(grep '^STATUS: ' "$status_file" 2>/dev/null | head -1 | cut -d' ' -f2-) || continue
    [ "$status" = "BOOTING" ] || continue

    # Parse the UPDATED timestamp
    updated_str=$(grep '^UPDATED: ' "$status_file" 2>/dev/null | head -1 | cut -d' ' -f2-) || continue
    [ -n "$updated_str" ] || continue
    # Cross-platform: GNU date -d, BSD date -j, python3 fallback
    updated_epoch=$(date -d "$updated_str" '+%s' 2>/dev/null) \
      || updated_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$updated_str" '+%s' 2>/dev/null) \
      || updated_epoch=$(python3 -c "import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))" "$updated_str" 2>/dev/null) \
      || updated_epoch=""
    [ -n "$updated_epoch" ] || continue

    age=$(( now - updated_epoch ))
    if [ "$age" -ge "$timeout" ]; then
      mkdir -p "${runtime_dir}/logs"
      printf '%s WARN: pane %s:%s.%s stuck in BOOTING for %ds (timeout=%ds) — forcing READY\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$session" "$team_window" "$pane_idx" "$age" "$timeout" \
        >> "${runtime_dir}/logs/boot-timeout.log"
      write_pane_status "$runtime_dir" "${session}:${team_window}.${pane_idx}" "READY"
    fi
  done
}

# ── Batch Worker Boot ────────────────────────────────────────────────

# Boot multiple workers in parallel: send all launch commands, then wait once.
# Usage: _batch_boot_workers <session> <runtime_dir> <team_window> <pane_idx:worker_num> ...
# Each trailing arg is a pane_idx:worker_num pair (e.g. "1:1" "2:2" "5:3").
_batch_boot_workers() {
  local session="$1" runtime_dir="$2" team_window="$3"
  shift 3

  # Bulk-read env values (avoids ~12 forks from _env_val calls)
  local _bbw_acronym="" _bbw_worker_model="" _bbw_team_type="" _bbw_reserved=""
  local _bbw_env_key _bbw_env_raw
  if [ -f "${runtime_dir}/session.env" ]; then
    while IFS='=' read -r _bbw_env_key _bbw_env_raw; do
      case "$_bbw_env_key" in
        PROJECT_ACRONYM) _bbw_acronym="${_bbw_env_raw//\"/}" ;;
      esac
    done < "${runtime_dir}/session.env"
  fi
  local _bbw_team_env="${runtime_dir}/team_${team_window}.env"
  if [ -f "$_bbw_team_env" ]; then
    while IFS='=' read -r _bbw_env_key _bbw_env_raw; do
      case "$_bbw_env_key" in
        WORKER_MODEL) _bbw_worker_model="${_bbw_env_raw//\"/}" ;;
        TEAM_TYPE) _bbw_team_type="${_bbw_env_raw//\"/}" ;;
        RESERVED) _bbw_reserved="${_bbw_env_raw//\"/}" ;;
      esac
    done < "$_bbw_team_env"
  fi
  [ -z "$_bbw_worker_model" ] && _bbw_worker_model="$DOEY_WORKER_MODEL"
  local _bbw_is_freelancer="false"
  [ "$_bbw_team_type" = "freelancer" ] && _bbw_is_freelancer="true"

  # Phase 1: Prepare all workers — build prompt files and command strings
  local _bbw_pane_arr=() _bbw_cmd_arr=() _bbw_count=0
  local pair pane_idx worker_num
  for pair in "$@"; do
    pane_idx="${pair%%:*}"
    worker_num="${pair##*:}"
    local prompt_suffix="w${team_window}-${worker_num}"
    local prompt_file="${runtime_dir}/worker-system-prompt-${prompt_suffix}.md"
    cp "${runtime_dir}/worker-system-prompt.md" "$prompt_file"
    local _bbw_role_label="$DOEY_ROLE_WORKER" _bbw_id_prefix="w"
    if [ "$_bbw_is_freelancer" = "true" ]; then
      _bbw_role_label="$DOEY_ROLE_FREELANCER" _bbw_id_prefix="f"
    fi
    local _bbw_pane_id="t${team_window}-${_bbw_id_prefix}${worker_num}"
    [ -n "$_bbw_acronym" ] && _bbw_pane_id="${_bbw_acronym}-${_bbw_pane_id}"
    printf '\n\n## Identity\nYou are %s %s (%s) in pane %s.%s of session %s.\n' \
      "$_bbw_role_label" "$worker_num" "$_bbw_pane_id" "$team_window" "$pane_idx" "$session" >> "$prompt_file"
    if [ "$_bbw_is_freelancer" = "true" ]; then
      printf 'You are part of the Freelancer pool — independent workers available to any team.\n' >> "$prompt_file"
    fi

    local _bbw_name_prefix="W"
    [ "$_bbw_is_freelancer" = "true" ] && _bbw_name_prefix="F"
    local cmd="claude --dangerously-skip-permissions --effort high --model $_bbw_worker_model --name \"T${team_window} ${_bbw_name_prefix}${worker_num}\""
    _append_settings cmd "$runtime_dir"
    cmd+=" --append-system-prompt-file \"${prompt_file}\""

    # Store pane index and command for phase 2
    _bbw_pane_arr+=("$pane_idx")
    _bbw_cmd_arr+=("$cmd")
    _bbw_count=$(( _bbw_count + 1 ))
  done

  # Phase 2: Launch ALL workers rapidly — no sleep between sends
  local _bbw_i=0
  while [ "$_bbw_i" -lt "$_bbw_count" ]; do
    local _bbw_cur_pane _bbw_cur_cmd
    _bbw_cur_pane="${_bbw_pane_arr[$_bbw_i]}"
    _bbw_cur_cmd="${_bbw_cmd_arr[$_bbw_i]}"
    doey_send_command "$session:${team_window}.${_bbw_cur_pane}" "${_DRAIN_STDIN}${_bbw_cur_cmd}"
    if [ "$_bbw_reserved" = "true" ] || [ "$_bbw_is_freelancer" = "true" ]; then
      write_pane_status "$runtime_dir" "${session}:${team_window}.${_bbw_cur_pane}" "RESERVED"
      local _bbw_safe="${session}:${team_window}.${_bbw_cur_pane}"
      _bbw_safe="${_bbw_safe//[-:.]/_}"
      echo "permanent" > "${runtime_dir}/status/${_bbw_safe}.reserved"
    else
      write_pane_status "$runtime_dir" "${session}:${team_window}.${_bbw_cur_pane}" "READY"
    fi
    _bbw_i=$(( _bbw_i + 1 ))
  done

  # Phase 3: Single sleep for auth stagger (O(1) instead of O(N))
  if [ "$_bbw_count" -gt 0 ]; then
    sleep $DOEY_WORKER_LAUNCH_DELAY
  fi

  # Phase 4: Schedule background boot-timeout watchdog
  if [ "$_bbw_count" -gt 0 ]; then
    (
      sleep "${DOEY_BOOT_TIMEOUT:-60}"
      _check_boot_timeouts "$runtime_dir" "$session" "$team_window" "$@"
    ) &
  fi
}

# ── Column Management ────────────────────────────────────────────────

doey_add_column() {
  local session="$1" runtime_dir="$2" dir="$3" team_window="${4:-1}"

  safe_source_session_env "${runtime_dir}/session.env"

  # Read team state via accessors (no _ts_* globals)
  local grid worker_count team_type work_dir wt_dir
  grid="$(team_state_get "$runtime_dir" "$team_window" "GRID" "dynamic")"
  worker_count="$(team_state_get "$runtime_dir" "$team_window" "WORKER_COUNT" "0")"
  team_type="$(team_state_get "$runtime_dir" "$team_window" "TEAM_TYPE")"
  wt_dir="$(team_state_get "$runtime_dir" "$team_window" "WORKTREE_DIR")"
  work_dir="$dir"
  [ -n "$wt_dir" ] && [ -d "$wt_dir" ] && work_dir="$wt_dir"

  if [[ "$grid" != "dynamic" ]]; then
    doey_error "Team window $team_window is not using dynamic grid mode"
    return 1
  fi
  if (( worker_count >= DOEY_MAX_WORKERS )); then
    doey_error "Max workers reached ($DOEY_MAX_WORKERS)"
    return 1
  fi

  # Pre-check: can we fit another column?
  local _dac_win_w
  _dac_win_w="$(tmux display-message -t "$session:$team_window" -p '#{window_width}' 2>/dev/null)" || true
  if [ -n "$_dac_win_w" ]; then
    local _dac_pane_count
    _dac_pane_count="$(tmux list-panes -t "$session:$team_window" 2>/dev/null | wc -l)"
    _dac_pane_count="${_dac_pane_count// /}"
    local _dac_min_col_w=40
    # Calculate width per column with current panes
    local _dac_cols_now=$(( (_dac_pane_count + 1) / 2 ))  # rough: 2 panes per column
    local _dac_needed_w=$(( (_dac_cols_now + 1) * _dac_min_col_w ))
    if [ "$_dac_needed_w" -gt "$_dac_win_w" ]; then
      printf "  %s Terminal too narrow for another column (%s available, need %s+)%s\n" \
        "${WARN:-}" "$_dac_win_w" "$_dac_needed_w" "${RESET:-}" >&2
      return 1
    fi
  fi

  doey_info "Adding worker column to team ${team_window}..."

  local last_pane new_pane_top new_pane_bottom
  last_pane="$(tmux list-panes -t "$session:$team_window" -F '#{pane_index}' | tail -1)"
  # Use -P -F to atomically capture new pane index (avoids sleep + list-panes race)
  new_pane_top="$(tmux split-window -h -t "$session:$team_window.${last_pane}" -c "$work_dir" -P -F '#{pane_index}')"
  new_pane_bottom="$(tmux split-window -v -t "$session:$team_window.${new_pane_top}" -c "$work_dir" -P -F '#{pane_index}')"

  local _pane_prefix="W"
  [ "$team_type" = "freelancer" ] && _pane_prefix="F"

  local _dac_panes_added=2

  # Name panes sequentially
  local _dac_w_i=1
  local w1_num=$(( worker_count + _dac_w_i ))
  tmux select-pane -t "$session:$team_window.${new_pane_top}" -T "T${team_window} ${_pane_prefix}${w1_num}"
  _dac_w_i=$((_dac_w_i + 1))

  local w2_num=$(( worker_count + _dac_w_i ))
  tmux select-pane -t "$session:$team_window.${new_pane_bottom}" -T "T${team_window} ${_pane_prefix}${w2_num}"
  _dac_w_i=$((_dac_w_i + 1))

  local _rps_include_p0="false"
  [ "$team_type" = "freelancer" ] && _rps_include_p0="true"
  rebuild_pane_state "$session:$team_window" "$_rps_include_p0"

  local new_worker_count=$(( worker_count + _dac_panes_added ))
  team_state_set "$runtime_dir" "$team_window" "WORKER_PANES" "$_worker_panes"
  team_state_set "$runtime_dir" "$team_window" "WORKER_COUNT" "$new_worker_count"

  _batch_boot_workers "$session" "$runtime_dir" "$team_window" "${new_pane_top}:${w1_num}" "${new_pane_bottom}:${w2_num}"
  rebalance_grid_layout "$session" "$team_window" "$runtime_dir"

  # Compute current column count for status message
  local _dac_pane_total
  _dac_pane_total="$(tmux list-panes -t "$session:$team_window" 2>/dev/null | wc -l)"
  _dac_pane_total="${_dac_pane_total// /}"
  local _dac_cols_final=$(( (_dac_pane_total - 1) / 2 ))
  [ "$_dac_cols_final" -lt 1 ] && _dac_cols_final=1

  doey_ok "Added ${_pane_prefix}${w1_num} and ${_pane_prefix}${w2_num} — ${new_worker_count} workers in ${_dac_cols_final} columns"
}

doey_remove_column() {
  local session="$1" runtime_dir="$2" col_index="${3:-}" team_window="${4:-1}"

  safe_source_session_env "${runtime_dir}/session.env"

  # Read team state via accessors (no _ts_* globals)
  local grid worker_count worker_panes team_type
  grid="$(team_state_get "$runtime_dir" "$team_window" "GRID" "dynamic")"
  worker_count="$(team_state_get "$runtime_dir" "$team_window" "WORKER_COUNT" "0")"
  worker_panes="$(team_state_get "$runtime_dir" "$team_window" "WORKER_PANES")"
  team_type="$(team_state_get "$runtime_dir" "$team_window" "TEAM_TYPE")"

  if [[ "$grid" != "dynamic" ]]; then
    doey_error "Team window $team_window is not using dynamic grid mode"
    return 1
  fi
  if (( worker_count == 0 )); then
    doey_error "No worker columns to remove"
    return 1
  fi

  [[ -z "$col_index" ]] && col_index="last"

  # Parse worker panes into positional params (bash 3.2 safe)
  local _old_ifs="$IFS"; IFS=','; set -- $worker_panes; IFS="$_old_ifs"
  if [ "$#" -lt 2 ]; then
    doey_error "Not enough worker panes to remove a column"
    return 1
  fi

  local remove_top remove_bottom
  if [ "$col_index" = "last" ]; then
    eval "remove_top=\${$(( $# - 1 ))}"
    eval "remove_bottom=\${$#}"
  else
    local ci=$(( col_index ))
    if [ "$ci" -lt 1 ] || [ "$ci" -gt $(( worker_count / 2 )) ]; then
      doey_error "Invalid column: $col_index (valid: 1-$(( worker_count / 2 )))"
      return 1
    fi
    local pair_start=$(( (ci - 1) * 2 + 1 ))
    eval "remove_top=\${${pair_start}}"
    eval "remove_bottom=\${$(( pair_start + 1 ))}"
  fi

  doey_info "Removing panes ${team_window}.${remove_top} and ${team_window}.${remove_bottom}..."

  # Resolve pane indices to stable pane IDs before killing
  local remove_top_id remove_bottom_id
  remove_top_id=$(tmux display-message -t "$session:$team_window.${remove_top}" -p '#{pane_id}' 2>/dev/null || true)
  remove_bottom_id=$(tmux display-message -t "$session:$team_window.${remove_bottom}" -p '#{pane_id}' 2>/dev/null || true)

  # Stop processes in both panes (using stable pane IDs)
  local _rc_pid _rc_ppid
  for _rc_pid in "$remove_top_id" "$remove_bottom_id"; do
    [ -z "$_rc_pid" ] && continue
    _rc_ppid=$(tmux display-message -t "$_rc_pid" -p '#{pane_pid}' 2>/dev/null || true)
    [ -n "$_rc_ppid" ] && pkill -P "$_rc_ppid" 2>/dev/null || true
  done
  sleep 0.2  # Wait for process termination

  # Kill using stable pane IDs (no index shift issues)
  [ -n "$remove_top_id" ] && tmux kill-pane -t "$remove_top_id" 2>/dev/null || true
  [ -n "$remove_bottom_id" ] && tmux kill-pane -t "$remove_bottom_id" 2>/dev/null || true
  sleep 0.2

  local _rps_include_p0="false"
  [ "$team_type" = "freelancer" ] && _rps_include_p0="true"
  rebuild_pane_state "$session:$team_window" "$_rps_include_p0"

  local new_worker_count=$(( worker_count - 2 ))
  team_state_set "$runtime_dir" "$team_window" "WORKER_PANES" "$_worker_panes"
  team_state_set "$runtime_dir" "$team_window" "WORKER_COUNT" "$new_worker_count"
  rebalance_grid_layout "$session" "$team_window" "$runtime_dir"

  doey_ok "Removed worker column — ${new_worker_count} workers remaining"
}

# ── Team Border Theme ────────────────────────────────────────────────

_apply_team_border_theme() {
  local session="$1" window_index="$2"
  local target="${session}:${window_index}"
  local border_fmt=" #{?pane_active,#[fg=cyan bold],#[fg=colour245]}#('${TEAM_MGMT_SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index}) #[default]"
  tmux set-window-option -t "$target" pane-border-status top
  tmux set-window-option -t "$target" pane-border-format "$border_fmt"
  tmux set-window-option -t "$target" pane-border-style 'fg=colour238'
  tmux set-window-option -t "$target" pane-active-border-style 'fg=cyan'
  tmux set-window-option -t "$target" pane-border-lines heavy
}

# ── Session Env ──────────────────────────────────────────────────────

# Atomically update a field in session.env
_set_session_env() {
  local runtime_dir="$1" field="$2" value="$3"
  local _lock="${runtime_dir}/.session_env_lock"
  local _retries=0
  while ! mkdir "$_lock" 2>/dev/null; do
    _retries=$((_retries + 1))
    if [ "$_retries" -gt 20 ]; then
      rmdir "$_lock" 2>/dev/null
      break
    fi
    sleep 0.1
  done
  local _tmp="${runtime_dir}/session.env.tmp.$$"
  # Escape sed metacharacters in value to prevent injection (/, &, \)
  local _escaped_value
  _escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
  sed "s/^${field}=.*/${field}=\"${_escaped_value}\"/" "${runtime_dir}/session.env" > "$_tmp"
  mv "$_tmp" "${runtime_dir}/session.env"
  rmdir "$_lock" 2>/dev/null || true
}

# ── Team Window Registration ────────────────────────────────────────

_register_team_window() {
  local runtime_dir="$1" window_index="$2"
  local current
  current=$(read_team_windows "$runtime_dir")
  if [ -z "$current" ]; then
    _set_session_env "$runtime_dir" TEAM_WINDOWS "$window_index"
  else
    _set_session_env "$runtime_dir" TEAM_WINDOWS "${current},${window_index}"
  fi
}

_unregister_team_window() {
  local runtime_dir="$1" window="$2"
  local current new_windows="" w
  current=$(read_team_windows "$runtime_dir")
  local _old_ifs="$IFS"; IFS=','
  for w in $current; do
    [ "$w" = "$window" ] && continue
    [ -n "$new_windows" ] && new_windows="${new_windows},"
    new_windows="${new_windows}${w}"
  done
  IFS="$_old_ifs"
  _set_session_env "$runtime_dir" TEAM_WINDOWS "$new_windows"
}

_ensure_worker_prompt() {
  local runtime_dir="$1" team_dir="$2"
  [ -f "${runtime_dir}/worker-system-prompt.md" ] && return 0
  local project_name
  project_name=$(_env_val "${runtime_dir}/session.env" PROJECT_NAME)
  write_worker_system_prompt "$runtime_dir" "$project_name" "$team_dir"
}

# ── Team Manager Launch ─────────────────────────────────────────────

_launch_team_manager() {
  local session="$1" runtime_dir="$2" window_index="$3"
  local mgr_model="${4:-}" mgr_agent_override="${5:-}"
  local mgr_name_override="${6:-}" mgr_pane_title_override="${7:-}"
  [ -z "$mgr_model" ] && mgr_model=$(_env_val "${runtime_dir}/team_${window_index}.env" MANAGER_MODEL)
  [ -z "$mgr_model" ] && mgr_model="$DOEY_MANAGER_MODEL"
  local mgr_agent
  if [ -n "$mgr_agent_override" ]; then
    mgr_agent="$mgr_agent_override"
  else
    mgr_agent=$(generate_team_agent "doey-subtaskmaster" "$window_index")
  fi
  local _proj="${session#doey-}"
  local _mgr_name="${mgr_name_override:-T${window_index} ${DOEY_ROLE_TEAM_LEAD}}"
  local _mgr_pane_title="${mgr_pane_title_override:-${_proj} T${window_index} Mgr}"
  local _mgr_cmd="claude --dangerously-skip-permissions --model $mgr_model --name \"${_mgr_name}\" --agent \"$mgr_agent\""
  _append_settings _mgr_cmd "$runtime_dir"
  doey_send_command "${session}:${window_index}.0" "${_DRAIN_STDIN}${_mgr_cmd}"
  tmux select-pane -t "${session}:${window_index}.0" -T "$_mgr_pane_title"
  write_pane_status "$runtime_dir" "${session}:${window_index}.0" "READY"

  # Background boot-timeout watchdog for manager pane
  (
    sleep "${DOEY_BOOT_TIMEOUT:-60}"
    _check_boot_timeouts "$runtime_dir" "$session" "$window_index" "0:0"
  ) &
}

# ── Team Briefing & Window Naming ────────────────────────────────────

_brief_team() {
  local session="$1" window_index="$2" wp_list="$3"
  local worker_count="$4" grid_desc="$5" wt_brief="${6:-}"
  local team_name="${7:-}" team_role="${8:-}"
  local _role_brief=""
  [ -n "$team_role" ] && _role_brief=" Team role: ${team_role}."
  (
    sleep "$DOEY_MANAGER_BRIEF_DELAY"
    doey_send_verified "${session}:${window_index}.0" \
      "Team is online in window ${window_index}. ${grid_desc} — ${worker_count} workers. Your workers are in panes ${wp_list}. ${DOEY_ROLE_COORDINATOR} monitors all teams from the Core Team window. Session: ${session}.${wt_brief}${_role_brief} All workers are idle and awaiting tasks. What should we work on?" || true
  ) &
}

_name_team_window() {
  local session="$1" window_index="$2" wt_dir="$3" runtime_dir="${4:-}"
  local _proj="${session#doey-}" _te="${runtime_dir:+${runtime_dir}/team_${window_index}.env}"
  _apply_team_border_theme "$session" "$window_index"
  tmux select-pane -t "${session}:${window_index}.0" -T "${_proj} T${window_index} Mgr"
  local label=""
  if [ -n "$_te" ] && [ -f "$_te" ]; then
    label=$(_env_val "$_te" TEAM_NAME)
    [ "$label" = "generic" ] && label=""
    if [ -z "$label" ]; then
      local _ntw_tt
      _ntw_tt=$(_env_val "$_te" TEAM_TYPE)
      if [ "$_ntw_tt" = "freelancer" ]; then label="Freelancers"
      elif [ -z "$wt_dir" ]; then label="Regular Team"
      else label="Worktree Team"; fi
    fi
  fi
  [ -z "$label" ] && label="Regular Team"
  tmux rename-window -t "${session}:${window_index}" "$label"
}

_worktree_brief() {
  [ -n "$1" ] || return 0
  echo " ISOLATED WORKTREE: branch ${2}, dir ${1}. Workers operate on this isolated copy — changes do NOT affect the main repo until merged."
}

_print_team_created() {
  local window_index="$1" grid_desc="$2" worker_count="$3"
  local wt_dir="${4:-}" wt_branch="${5:-}"
  if [ -n "$wt_dir" ]; then
    printf "  ${SUCCESS}Team window %s created${RESET} — %s, %s workers, ${BOLD}worktree${RESET} (%s)\n" "$window_index" "$grid_desc" "$worker_count" "$wt_branch"
  else
    printf "  ${SUCCESS}Team window %s created${RESET} — %s, %s workers\n" "$window_index" "$grid_desc" "$worker_count"
  fi
}

# ── Team Creation ─────────────────────────────────────────────────────

add_team_from_def() {
  local session="$1" runtime_dir="$2" dir="$3" team_name="$4" type_override="${5:-}"

  # Find and parse definition
  local def_file
  if ! def_file=$(_find_team_def "$team_name"); then
    printf "  ${ERROR}Team definition '%s' not found${RESET}\n" "$team_name" >&2
    printf "  Searched: .doey/teams/ → teams/ → ~/.config/doey/teams/ → repo teams/\n" >&2
    return 1
  fi
  printf "  ${DIM}Loading team definition: %s${RESET}\n" "$def_file"

  local env_file
  env_file=$(_parse_team_def "$def_file" "$runtime_dir") || return 1

  # Read parsed values
  local td_name td_grid td_workers td_type
  local td_manager_model td_worker_model td_briefing
  td_name=$(_env_val "$env_file" NAME)
  td_grid=$(_env_val "$env_file" GRID "dynamic")
  td_workers=$(_env_val "$env_file" WORKERS "3")
  if [ -n "$type_override" ]; then
    td_type="$type_override"
  else
    td_type=$(_env_val "$env_file" TYPE "local")
  fi
  td_manager_model=$(_env_val "$env_file" MANAGER_MODEL "")
  td_worker_model=$(_env_val "$env_file" WORKER_MODEL "")
  td_briefing=$(_env_val "$env_file" BRIEFING_FILE "")

  # Create tmux window
  local window_index
  window_index=$(tmux new-window -t "$session" -c "$dir" -P -F '#{window_index}')
  printf "  ${DIM}Creating team '%s' in window %s...${RESET}\n" "$td_name" "$window_index"

  # Determine pane count from definition (find highest PANE_N key)
  # Also detect whether any pane has role=manager for fast-path decision
  local max_pane=0 _p_idx=0 _has_manager="false"
  while [ "$_p_idx" -le 20 ]; do
    if grep -q "^PANE_${_p_idx}_ROLE=" "$env_file" 2>/dev/null; then
      max_pane="$_p_idx"
      local _p_role
      _p_role=$(_env_val "$env_file" "PANE_${_p_idx}_ROLE" "")
      [ "$_p_role" = "manager" ] && _has_manager="true"
    fi
    _p_idx=$((_p_idx + 1))
  done

  # ── Fast-path: managerless (freelancer) teams ─────────────────────────
  # All panes are workers — no manager launch, no briefing delay.
  if [ "$_has_manager" = "false" ]; then
    # Pre-split all panes at once (pane 0 already exists from new-window)
    local _fp_i=1
    while [ "$_fp_i" -le "$max_pane" ]; do
      tmux split-window -t "${session}:${window_index}" -c "$dir" -h 2>/dev/null || \
        tmux split-window -t "${session}:${window_index}" -c "$dir" -v 2>/dev/null
      _fp_i=$((_fp_i + 1))
    done
    tmux select-layout -t "${session}:${window_index}" tiled 2>/dev/null || true

    # Build pane list covering ALL panes (0..max_pane)
    local _fp_pane_list="" _fp_count=0 _fp_j=0
    while [ "$_fp_j" -le "$max_pane" ]; do
      [ -n "$_fp_pane_list" ] && _fp_pane_list="${_fp_pane_list},"
      _fp_pane_list="${_fp_pane_list}${_fp_j}"
      _fp_count=$((_fp_count + 1))
      _fp_j=$((_fp_j + 1))
    done

    # Write team env: MANAGER_PANE="" and TEAM_TYPE="freelancer"
    write_team_env "$runtime_dir" "$window_index" "$td_grid" \
      "$_fp_pane_list" "$_fp_count" "" "" "" "$td_name" "" \
      "$td_worker_model" "$td_manager_model" "freelancer" "$td_name"
    _register_team_window "$runtime_dir" "$window_index"
    _ensure_worker_prompt "$runtime_dir" "$dir"

    # Boot all panes as workers via _batch_boot_workers (pane 0 through max_pane)
    local _fp_pairs="" _fp_k=0
    while [ "$_fp_k" -le "$max_pane" ]; do
      _fp_pairs="${_fp_pairs} ${_fp_k}:${_fp_k}"
      _fp_k=$((_fp_k + 1))
    done
    _batch_boot_workers "$session" "$runtime_dir" "$window_index" $_fp_pairs

    rebalance_grid_layout "$session" "$window_index" "$runtime_dir"
    _name_team_window "$session" "$window_index" "" "$runtime_dir"

    printf "  \033[0;32mTeam '%s' created in window %s (%s workers, managerless)\033[0m\n" \
      "$td_name" "$window_index" "$_fp_count"
    return 0
  fi

  # ── Standard path: teams with a manager ───────────────────────────────

  # Build worker panes (pane 0 = manager, rest are workers)
  local worker_pane_list="" worker_count=0 _wp_i=1
  while [ "$_wp_i" -le "$max_pane" ]; do
    # Split window to create worker panes
    tmux split-window -t "${session}:${window_index}" -c "$dir" -h 2>/dev/null || \
      tmux split-window -t "${session}:${window_index}" -c "$dir" -v 2>/dev/null
    [ -n "$worker_pane_list" ] && worker_pane_list="${worker_pane_list},"
    worker_pane_list="${worker_pane_list}${_wp_i}"
    worker_count=$(( worker_count + 1 ))
    _wp_i=$((_wp_i + 1))
  done
  # Apply initial tiled layout, then rebalance after workers are launched
  tmux select-layout -t "${session}:${window_index}" tiled 2>/dev/null || true

  # Write team env with TEAM_DEF field
  write_team_env "$runtime_dir" "$window_index" "$td_grid" \
    "$worker_pane_list" "$worker_count" "0" "" "" "$td_name" "" \
    "$td_worker_model" "$td_manager_model" "$td_type" "$td_name"
  _register_team_window "$runtime_dir" "$window_index"
  _ensure_worker_prompt "$runtime_dir" "$dir"

  # Launch manager (pane 0)
  local mgr_agent="" mgr_name=""
  mgr_agent=$(_env_val "$env_file" PANE_0_AGENT "doey-subtaskmaster")
  mgr_name=$(_env_val "$env_file" PANE_0_NAME "Manager")
  local mgr_agent_name
  mgr_agent_name=$(generate_team_agent "$mgr_agent" "$window_index")
  local mgr_model="${td_manager_model:-$DOEY_MANAGER_MODEL}"
  local _mgr_cmd="claude --dangerously-skip-permissions --model $mgr_model --agent \"$mgr_agent_name\" --name \"${mgr_name}\""
  _append_settings _mgr_cmd "$runtime_dir"
  doey_send_command "${session}:${window_index}.0" "${_DRAIN_STDIN}${_mgr_cmd}"
  tmux select-pane -t "${session}:${window_index}.0" -T "$mgr_name"

  # Launch workers (panes 1+)
  local _w_i=1
  while [ "$_w_i" -le "$max_pane" ]; do
    local w_agent w_name w_model w_agent_name
    w_agent=$(_env_val "$env_file" "PANE_${_w_i}_AGENT" "")
    w_name=$(_env_val "$env_file" "PANE_${_w_i}_NAME" "Worker ${_w_i}")
    w_model="${td_worker_model:-$DOEY_WORKER_MODEL}"

    local _w_cmd="claude --dangerously-skip-permissions --effort high --model $w_model --name \"${w_name}\""
    if [ -n "$w_agent" ]; then
      w_agent_name=$(generate_team_agent "$w_agent" "$window_index")
      _w_cmd+=" --agent \"$w_agent_name\""
    fi
    local _w_prompt
    _w_prompt=$(ls "${runtime_dir}"/worker-system-prompt-*.md 2>/dev/null | head -1)
    [ -n "$_w_prompt" ] && _w_cmd+=" --append-system-prompt-file \"$_w_prompt\""
    _append_settings _w_cmd "$runtime_dir"

    sleep "${DOEY_WORKER_LAUNCH_DELAY:-2}"
    doey_send_command "${session}:${window_index}.${_w_i}" "${_DRAIN_STDIN}${_w_cmd}"
    tmux select-pane -t "${session}:${window_index}.${_w_i}" -T "$w_name"
    # Write READY status so Taskmaster/Subtaskmaster can dispatch immediately
    write_pane_status "$runtime_dir" "${session}:${window_index}.${_w_i}" "READY"
    _w_i=$((_w_i + 1))
  done

  # Write READY for manager pane (matches _launch_team_manager pattern)
  write_pane_status "$runtime_dir" "${session}:${window_index}.0" "READY"

  # Schedule background boot-timeout watchdog (matches _batch_boot_workers Phase 4)
  if [ "$max_pane" -gt 0 ]; then
    local _atd_pairs="" _atd_k=1
    while [ "$_atd_k" -le "$max_pane" ]; do
      _atd_pairs="${_atd_pairs} ${_atd_k}:${_atd_k}"
      _atd_k=$((_atd_k + 1))
    done
    (
      sleep "${DOEY_BOOT_TIMEOUT:-60}"
      _check_boot_timeouts "$runtime_dir" "$session" "$window_index" $_atd_pairs
    ) &
  fi

  # Apply manager-left layout and name window
  rebalance_grid_layout "$session" "$window_index" "$runtime_dir"
  _name_team_window "$session" "$window_index" "" "$runtime_dir"

  # Brief manager with team layout + briefing content
  if [ -n "$td_briefing" ] && [ -f "$td_briefing" ]; then
    local _brief_text _layout=""
    _layout="Team: ${td_name} | Window: ${window_index} | Workers: ${worker_count}\nPanes:"
    local _b_i=0
    while [ "$_b_i" -le "$max_pane" ]; do
      local _b_role _b_name
      _b_role=$(_env_val "$env_file" "PANE_${_b_i}_ROLE" "")
      _b_name=$(_env_val "$env_file" "PANE_${_b_i}_NAME" "")
      [ -n "$_b_role" ] && _layout="${_layout}\n  Pane ${_b_i}: ${_b_name} (${_b_role})"
      _b_i=$((_b_i + 1))
    done
    _brief_text=$(printf '%b\n\n%s' "$_layout" "$(cat "$td_briefing")")

    (
      sleep "$DOEY_MANAGER_BRIEF_DELAY"
      doey_send_verified "${session}:${window_index}.0" "$_brief_text" || true
    ) &
  fi

  printf "  \033[0;32mTeam '%s' created in window %s (%s workers)\033[0m\n" \
    "$td_name" "$window_index" "$worker_count"
}

add_dynamic_team_window() {
  local session="$1" runtime_dir="$2" dir="$3" initial_cols="${4:-$DOEY_INITIAL_WORKER_COLS}"
  local worktree_spec="${5:-}"
  local team_name="${6:-}" team_role="${7:-}" worker_model="${8:-}" manager_model="${9:-}"
  local team_type="${10:-}"
  local reserved="${11:-false}"
  local task_id="${12:-}"
  # --reserved implies freelancer team type if not already set
  if [ "$reserved" = "true" ] && [ -z "$team_type" ]; then
    team_type="freelancer"
  fi
  local team_dir="$dir" worktree_branch="" wt_dir_for_env=""
  local is_freelancer="false"
  [ "$team_type" = "freelancer" ] && is_freelancer="true"

  # Freelancer teams: panes 0+1 form the base column (F0, F1).
  # Extra columns beyond the base are added by the loop below.
  # If caller specified columns (e.g. --grid 3x2 → initial_cols=3), subtract 1
  # for the base column. If no columns specified, default to 0 extra.
  if [ "$is_freelancer" = "true" ]; then
    if [ -n "${4:-}" ] && [ "$initial_cols" -gt 0 ] 2>/dev/null; then
      initial_cols=$((initial_cols - 1))
    else
      initial_cols=0
    fi
  fi

  local window_index
  window_index=$(tmux new-window -t "$session" -c "$dir" -P -F '#{window_index}')

  if [ -n "$worktree_spec" ]; then
    local _wt_branch_arg=""
    [ "$worktree_spec" = "auto" ] || _wt_branch_arg="$worktree_spec"
    team_dir=$(create_team_worktree "$dir" "$window_index" "$_wt_branch_arg") || {
      printf "  ${WARN}Worktree creation failed for team %s — falling back to shared repo${RESET}\n" "$window_index"
      team_dir="$dir"; worktree_spec=""
    }
    if [ -n "$worktree_spec" ]; then
      worktree_branch=$(git -C "$team_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "doey/team-${window_index}")
      wt_dir_for_env="$team_dir"
    fi
  fi

  # Install hooks + skills in worktree dir (main project already has them from session launch)
  [ -n "$wt_dir_for_env" ] && [ -d "$wt_dir_for_env" ] && install_doey_hooks "$wt_dir_for_env" "  "

  local _team_label="team"
  [ "$is_freelancer" = "true" ] && _team_label="freelancer team"
  printf "  ${DIM}Creating dynamic %s window %s...${RESET}\n" "$_team_label" "$window_index"

  # Freelancer teams: no manager, all panes are workers. MANAGER_PANE is empty.
  local mgr_pane="0"
  [ "$is_freelancer" = "true" ] && mgr_pane=""

  write_team_env "$runtime_dir" "$window_index" "dynamic" "" "0" "$mgr_pane" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model" "$team_type" "" "$reserved" "$task_id"
  _name_team_window "$session" "$window_index" "$wt_dir_for_env" "$runtime_dir"
  _register_team_window "$runtime_dir" "$window_index"
  _ensure_worker_prompt "$runtime_dir" "$team_dir"

  # Only launch manager for non-freelancer teams
  if [ "$is_freelancer" = "true" ]; then
    # Freelancer: pane 0 is F0, split vertically for additional rows based on _DOEY_GRID_ROWS
    local _fl_grid_rows="${_DOEY_GRID_ROWS:-2}"
    [ "$_fl_grid_rows" -lt 1 ] 2>/dev/null && _fl_grid_rows=2

    # First split: F0 + F1
    tmux split-window -v -t "$session:${window_index}.0" -c "$team_dir"
    local _fl_p1
    _fl_p1="$(tmux list-panes -t "$session:$window_index" -F '#{pane_index}' | tail -1)"

    # Name base panes
    tmux select-pane -t "$session:${window_index}.0" -T "T${window_index} F0"
    tmux select-pane -t "$session:${window_index}.${_fl_p1}" -T "T${window_index} F1"

    local _fl_boot_args="0:0 ${_fl_p1}:1"
    local _fl_worker_count=1
    local _fl_row_i=2

    # Add extra rows beyond 2 if _fl_grid_rows > 2
    while [ "$_fl_row_i" -lt "$_fl_grid_rows" ]; do
      local _fl_extra
      _fl_extra="$(tmux split-window -v -t "$session:${window_index}.${_fl_p1}" -c "$team_dir" -P -F '#{pane_index}')"
      tmux select-pane -t "$session:${window_index}.${_fl_extra}" -T "T${window_index} F${_fl_row_i}"
      _fl_boot_args="${_fl_boot_args} ${_fl_extra}:${_fl_row_i}"
      _fl_worker_count=$((_fl_worker_count + 1))
      _fl_p1="$_fl_extra"
      _fl_row_i=$((_fl_row_i + 1))
    done

    # Batch-boot all freelancers in base column
    _batch_boot_workers "$session" "$runtime_dir" "$window_index" $_fl_boot_args

    # Update worker count: F0 is uncounted (like manager pane), others add to count
    write_team_env "$runtime_dir" "$window_index" "dynamic" "" "$_fl_worker_count" "$mgr_pane" "$wt_dir_for_env" "$worktree_branch" "$team_name" "$team_role" "$worker_model" "$manager_model" "$team_type" "" "$reserved" "$task_id"
  else
    _launch_team_manager "$session" "$runtime_dir" "$window_index"
  fi

  # Calculate max feasible columns
  local _feasibility _feasible_max_cols=99
  if _feasibility=$(_check_grid_feasibility "$session" "$window_index" 40 8 2>/dev/null); then
    _feasible_max_cols="${_feasibility%% *}"
  fi
  if [ "$_feasible_max_cols" -lt "$initial_cols" ]; then
    printf "  %s Requested %s worker columns but only %s fit — reducing%s\n" \
      "${WARN:-}" "$initial_cols" "$_feasible_max_cols" "${RESET:-}" >&2
    initial_cols="$_feasible_max_cols"
  fi

  local _col_i
  for (( _col_i=0; _col_i<initial_cols; _col_i++ )); do
    doey_add_column "$session" "$runtime_dir" "$team_dir" "$window_index"

  done

  local _wpl_result
  _wpl_result=$(_build_worker_pane_list "$session" "$window_index")

  # Mark all worker panes as reserved if --reserved was passed
  if [ "$reserved" = "true" ] && [ -n "$_wpl_result" ]; then
    local _rv_pane _rv_safe
    local _rv_old_ifs="$IFS"
    IFS=', '
    for _rv_pane in $_wpl_result; do
      [ -z "$_rv_pane" ] && continue
      write_pane_status "$runtime_dir" "${session}:${_rv_pane}" "RESERVED"
      _rv_safe="${session}:${_rv_pane}"
      _rv_safe="${_rv_safe//[-:.]/_}"
      echo "permanent" > "${runtime_dir}/status/${_rv_safe}.reserved"
    done
    IFS="$_rv_old_ifs"
  fi

  local worker_count wt_brief
  worker_count=$(_env_val "${runtime_dir}/team_${window_index}.env" WORKER_COUNT)
  wt_brief=$(_worktree_brief "$wt_dir_for_env" "$worktree_branch")

  if [ "$is_freelancer" = "true" ]; then
    _print_team_created "$window_index" "freelancer pool" "$worker_count" "$wt_dir_for_env" "$worktree_branch"
  else
    _brief_team "$session" "$window_index" "$_wpl_result" "$worker_count" "Dynamic grid, auto-expands when all are busy" "$wt_brief" "$team_name" "$team_role"
    _print_team_created "$window_index" "dynamic grid" "$worker_count" "$wt_dir_for_env" "$worktree_branch"
  fi
}

# ── Team Teardown & Listing ───────────────────────────────────────────

kill_team_window() {
  local session="$1" runtime_dir="$2" window="$3"
  local team_env="${runtime_dir}/team_${window}.env"

  [ -f "$team_env" ] || { printf "  ${ERROR}No team env for window %s${RESET}\n" "$window"; return 1; }
  [ "$window" != "0" ] || { printf "  ${ERROR}Cannot kill window 0 — use 'doey stop'${RESET}\n"; return 1; }

  printf "  ${DIM}Killing team window %s...${RESET}\n" "$window"

  local pane_id pane_pid
  for pane_id in $(tmux list-panes -t "${session}:${window}" -F '#{pane_id}' 2>/dev/null); do
    pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null) || continue
    [ -n "$pane_pid" ] || continue
    pkill -P "$pane_pid" 2>/dev/null || true
    kill -- -"$pane_pid" 2>/dev/null || true
  done
  sleep 0.3
  tmux kill-window -t "${session}:${window}" 2>/dev/null || true

  local _wt_dir
  _wt_dir=$(_env_val "$team_env" WORKTREE_DIR)
  if [ -n "$_wt_dir" ]; then
    local _proj_dir
    _proj_dir=$(_env_val "${runtime_dir}/session.env" PROJECT_DIR)
    [ -z "$_proj_dir" ] || _worktree_safe_remove "$_proj_dir" "$_wt_dir"
  fi

  rm -f "$team_env"
  rm -f "$HOME/.claude/agents/t${window}-manager.md" 2>/dev/null || true
  local safe_prefix="${session//[-:.]/_}_${window}_"
  rm -f "${runtime_dir}/status/${safe_prefix}"* 2>/dev/null || true
  rm -f "${runtime_dir}/results/"*"_${window}_"* 2>/dev/null || true
  _unregister_team_window "$runtime_dir" "$window"

  printf "  ${SUCCESS}Team window %s killed and cleaned up${RESET}\n" "$window"
}

list_team_windows() {
  local session="$1" runtime_dir="$2"

  doey_header "Doey — Team Windows"
  printf '\n'

  local team_windows
  team_windows=$(read_team_windows "$runtime_dir")

  if [ -z "$team_windows" ] || { [ "$team_windows" = "0" ] && [ ! -f "${runtime_dir}/team_0.env" ]; }; then
    printf "  ${DIM}(no team windows — single-window mode)${RESET}\n\n"
    return 0
  fi

  printf "  ${BOLD}%-8s %-8s %-10s %-8s %-20s${RESET}\n" "Window" "Grid" "Workers" "Status" "Team Env"
  printf "  ${DIM}%-8s %-8s %-10s %-8s %-20s${RESET}\n" "------" "----" "-------" "------" "--------"

  local _saved_ifs="$IFS" w
  IFS=','
  for w in $team_windows; do
    local team_env="${runtime_dir}/team_${w}.env"
    if [ -f "$team_env" ]; then
      local t_grid t_workers status="active"
      t_grid=$(_env_val "$team_env" GRID)
      t_workers=$(_env_val "$team_env" WORKER_COUNT)
      tmux list-panes -t "${session}:${w}" >/dev/null 2>&1 || status="dead"
      printf "  %-8s %-8s %-10s %-8s %-20s\n" "$w" "$t_grid" "$t_workers" "$status" "team_${w}.env"
    else
      printf "  %-8s ${DIM}(no env file)${RESET}\n" "$w"
    fi
  done
  IFS="$_saved_ifs"

  printf '\n'
}
