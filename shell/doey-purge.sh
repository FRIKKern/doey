#!/usr/bin/env bash
# doey-purge.sh — Purge-related functions shared across Doey scripts.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_purge_sourced:-}" = "1" ] && return 0
__doey_purge_sourced=1

# ── Purge Functions ──────────────────────────────────────────────────

_purge_format_bytes() {
  local bytes="$1"
  if [[ "$bytes" -ge 1048576 ]]; then
    awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
  elif [[ "$bytes" -ge 1024 ]]; then
    awk "BEGIN{printf \"%.1f KB\", $bytes/1024}"
  else
    printf "%d B" "$bytes"
  fi
}

_purge_file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

_purge_collect() {
  local file="$1" list_file="$2"
  local size
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  echo "${size}:${file}" >> "$list_file"
}

_purge_collect_stale() {
  local glob="$1" max_age="$2" now="$3" list_file="$4" label="${5:-}"
  local count=0
  for f in $glob; do
    [[ -f "$f" ]] || continue
    if [[ "$max_age" -eq 0 ]] || [[ $((now - $(_purge_file_mtime "$f"))) -gt "$max_age" ]]; then
      _purge_collect "$f" "$list_file"
      count=$((count + 1))
    fi
  done
  [[ $count -gt 0 ]] && [[ -n "$label" ]] && printf "         Found %d %s\n" "$count" "$label"
}

_purge_scan_runtime() {
  local rt="$1" active="$2" session_name="$3" list_file="$4" now="$5"

  # --- Status files: dead-pane detection ---
  local live_panes="" status_count=0
  if $active; then
    live_panes="$(tmux list-panes -s -t "$session_name" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | tr '\n' '|')"
  fi
  for f in "$rt"/status/*.status; do
    [[ -f "$f" ]] || continue
    if $active; then
      local pane_id
      pane_id="$(head -1 "$f" | sed 's/^PANE: //')"
      echo "$live_panes" | grep -qF "$pane_id" && continue
    fi
    _purge_collect "$f" "$list_file"
    status_count=$((status_count + 1))
  done
  [[ $status_count -gt 0 ]] && printf "         Found %d stale status files\n" "$status_count"

  # --- Always-safe markers ---
  _purge_collect_stale "$rt/status/*.dispatched"     0 "$now" "$list_file" ""
  _purge_collect_stale "$rt/status/notif_cooldown_*" 0 "$now" "$list_file" "cooldown markers"

  # --- Session-stopped-only files ---
  if ! $active; then
    for f in "$rt"/status/pane_map "$rt"/status/col_*.collapsed \
             "$rt"/status/pane_hash_*; do
      [[ -f "$f" ]] || continue
      _purge_collect "$f" "$list_file"
    done
  fi

  # --- Age-based cleanup ---
  _purge_collect_stale "$rt/messages/*.msg"         3600  "$now" "$list_file" "stale undelivered messages"
  _purge_collect_stale "$rt/broadcasts/*.broadcast" 3600  "$now" "$list_file" ""
  _purge_collect_stale "$rt/results/*"              86400 "$now" "$list_file" "old result files (>24h)"
}

_purge_scan_research() {
  local rt="$1" list_file="$2" now="$3"
  local before=0
  [[ -s "$list_file" ]] && before="$(wc -l < "$list_file" | tr -d ' ')"
  _purge_collect_stale "$rt/research/*" 172800 "$now" "$list_file" ""
  _purge_collect_stale "$rt/reports/*"  172800 "$now" "$list_file" ""
  local after=0
  [[ -s "$list_file" ]] && after="$(wc -l < "$list_file" | tr -d ' ')"
  local count=$((after - before))
  if [[ $count -gt 0 ]]; then
    printf "         Found %d research/report files older than 48h\n" "$count"
  else
    printf "         ${DIM}No expired research artifacts${RESET}\n"
  fi
}

_purge_audit_context() {
  local total_bytes=0
  local recommendations=""
  local rec_count=0

  printf '\n'

  # Check installed agents
  for f in "$HOME"/.claude/agents/doey-*.md; do
    [[ -f "$f" ]] || continue
    local size lines short_name
    size=$(wc -c < "$f" | tr -d ' ')
    lines=$(wc -l < "$f" | tr -d ' ')
    short_name="~/.claude/agents/$(basename "$f")"
    printf "         %-45s %s  (%d lines)\n" "$short_name" "$(_purge_format_bytes "$size")" "$lines"
    total_bytes=$((total_bytes + size))
    if [[ $size -gt 8192 ]]; then
      recommendations="${recommendations}         - $(basename "$f") is >8KB — consider splitting rules into memory\n"
      rec_count=$((rec_count + 1))
    fi
  done

  # Check installed commands/skills
  local skill_count=0 skill_bytes=0
  for f in "$PROJECT_DIR"/.claude/skills/doey-*/SKILL.md; do
    [[ -f "$f" ]] || continue
    local size
    size=$(wc -c < "$f" | tr -d ' ')
    skill_bytes=$((skill_bytes + size))
    skill_count=$((skill_count + 1))
    if [[ $size -gt 3072 ]]; then
      recommendations="${recommendations}         - $(basename "$f") is >3KB — consider compressing\n"
      rec_count=$((rec_count + 1))
    fi
  done
  if [[ $skill_count -gt 0 ]]; then
    printf "         %-45s %s total\n" "${skill_count} skills" "$(_purge_format_bytes "$skill_bytes")"
    total_bytes=$((total_bytes + skill_bytes))
  fi
  if [[ $skill_bytes -gt 30720 ]]; then
    recommendations="${recommendations}         - ${skill_count} skills total >30KB — consider per-role skill sets\n"
    rec_count=$((rec_count + 1))
  fi

  # Check project CLAUDE.md
  local project_dir
  project_dir="$(pwd)"
  if [[ -f "$project_dir/CLAUDE.md" ]]; then
    local size lines
    size=$(wc -c < "$project_dir/CLAUDE.md" | tr -d ' ')
    lines=$(wc -l < "$project_dir/CLAUDE.md" | tr -d ' ')
    printf "         %-45s %s  (%d lines)\n" "CLAUDE.md" "$(_purge_format_bytes "$size")" "$lines"
    total_bytes=$((total_bytes + size))
    if [[ $size -gt 5120 ]]; then
      recommendations="${recommendations}         - CLAUDE.md is >5KB — consider moving stable info to memory\n"
      rec_count=$((rec_count + 1))
    fi
  fi

  printf "         %-45s ~%s\n" "Total loaded context:" "$(_purge_format_bytes "$total_bytes")"

  if [[ $rec_count -gt 0 ]]; then
    printf '\n'
    printf "         ${WARN}Recommendations:${RESET}\n"
    printf '%b' "$recommendations"
  fi
  printf '\n'
}

_purge_audit_hooks() {
  local repo_dir
  repo_dir="$(resolve_repo_dir)"
  local audit_script="${repo_dir}/shell/context-audit.sh"

  if [[ ! -x "$audit_script" ]]; then
    printf "         ${DIM}context-audit.sh not found — skipping${RESET}\n"
    return 0
  fi

  local audit_output
  audit_output="$("$audit_script" --installed --no-color 2>&1)" || true

  if [[ -z "$audit_output" ]]; then
    printf "         ${SUCCESS}Context audit: clean${RESET}\n"
  else
    printf "%s\n" "$audit_output"
  fi
}

_purge_summary() {
  local rt_files="$1" rt_bytes="$2" res_files="$3" res_bytes="$4" dry_run="$5"
  local total_files=$((rt_files + res_files))
  local total_bytes=$((rt_bytes + res_bytes))

  printf '\n'
  printf "         ${DIM}%-14s %7s  %-12s${RESET}\n" "Category" "Files" "Size"
  printf "         ${DIM}──────────────────────────────────────${RESET}\n"
  printf "         %-14s %5d  %-12s\n" "Runtime" "$rt_files" "$(_purge_format_bytes "$rt_bytes")"
  printf "         %-14s %5d  %-12s\n" "Research" "$res_files" "$(_purge_format_bytes "$res_bytes")"
  printf "         ${DIM}──────────────────────────────────────${RESET}\n"
  printf "         ${BOLD}%-14s %5d  %-12s${RESET}\n" "Total" "$total_files" "$(_purge_format_bytes "$total_bytes")"

  if $dry_run; then
    printf "         ${DIM}(dry run — no files were deleted)${RESET}\n"
  fi
  printf '\n'
}

_purge_execute() {
  local list_file="$1"
  local count=0 bytes=0

  while IFS=: read -r size path; do
    [[ -z "$path" ]] && continue
    rm -f "$path" 2>/dev/null && {
      count=$((count + 1))
      bytes=$((bytes + size))
    }
  done < "$list_file"

  printf "   ${SUCCESS}Purged %d files, freed %s.${RESET}\n" "$count" "$(_purge_format_bytes "$bytes")"
}

_purge_write_report() {
  local rt="$1" project="$2" active="$3" dry_run="$4" scope="$5"
  local rt_files="$6" rt_bytes="$7" res_files="$8" res_bytes="$9"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

  mkdir -p "$rt/results"
  cat > "$rt/results/purge_report_$(date '+%Y%m%d_%H%M%S').json" << REPORT_EOF
{
  "timestamp": "$ts",
  "project": "$project",
  "session_active": $active,
  "dry_run": $dry_run,
  "scope": "$scope",
  "runtime": { "files_found": $rt_files, "bytes_freed": $rt_bytes },
  "research": { "files_found": $res_files, "bytes_freed": $res_bytes },
  "total_files_purged": $((rt_files + res_files)),
  "total_bytes_freed": $((rt_bytes + res_bytes))
}
REPORT_EOF
  printf "   Report: ${DIM}%s/results/purge_report_*.json${RESET}\n" "$rt"
}

_purge_tally() {
  local list_file="$1"
  _COUNT=0; _BYTES=0
  [[ -s "$list_file" ]] || return 0
  while IFS=: read -r size path; do
    [[ -z "$path" ]] && continue
    _COUNT=$((_COUNT + 1))
    _BYTES=$((_BYTES + size))
  done < "$list_file"
}

purge_usage() {
  cat << 'PURGE_HELP'

  Usage: doey purge [options]

  Scan and clean stale runtime files, audit context bloat.

  Options:
    --dry-run    Report only, no deletions
    --force      Skip confirmation prompt
    --scope X    Limit scope: runtime, context, hooks, all (default: all)
    -h, --help   Show this help

  Examples:
    doey purge                    # Interactive scan and clean
    doey purge --dry-run          # See what would be purged
    doey purge --force            # Purge without asking
    doey purge --scope runtime    # Only clean runtime files

PURGE_HELP
}

doey_purge() {
  local dry_run=false
  local force=false
  local scope="all"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  dry_run=true ;;
      --force)    force=true ;;
      --scope)    scope="${2:?--scope requires a value}"; shift ;;
      -h|--help)  purge_usage; return 0 ;;
      *)          doey_error "Unknown purge flag: $1"; return 1 ;;
    esac
    shift
  done

  # Validate scope
  case "$scope" in
    runtime|context|hooks|all) ;;
    *) doey_error "Invalid scope: $scope (use: runtime, context, hooks, all)"; return 1 ;;
  esac

  # Resolve project
  local dir name session runtime_dir session_active
  dir="$(pwd)"
  PROJECT_DIR="$dir"
  name="$(find_project "$dir")"
  if [[ -z "$name" ]]; then
    doey_info "No project registered for $dir — nothing to purge"
    return 0
  fi

  session="doey-${name}"
  runtime_dir="${TMPDIR:-/tmp}/doey/${name}"
  session_active=false

  if session_exists "$session"; then
    session_active=true
    local tmux_rt
    tmux_rt="$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null)" || true
    tmux_rt="${tmux_rt#*=}"
    [[ -n "$tmux_rt" ]] && runtime_dir="$tmux_rt"
  fi

  if [[ ! -d "$runtime_dir" ]]; then
    printf "  ${DIM}No runtime directory found — nothing to purge${RESET}\n"
    return 0
  fi

  # Header
  local state_label="stopped"; $session_active && state_label="active"
  printf '\n'
  doey_header "Doey — Purge  (session ${state_label})"

  # Calculate step count based on scope
  local step=0
  case "$scope" in
    all) STEP_TOTAL=5 ;;
    *)   STEP_TOTAL=2 ;;
  esac

  # Temp file for collecting stale file list
  local list_file now
  list_file="$(mktemp "${TMPDIR:-/tmp}/doey_purge_XXXXXX")"
  trap "rm -f '$list_file'" RETURN
  now="$(date +%s)"

  local rt_files=0 rt_bytes=0 res_files=0 res_bytes=0

  # Step: Scan runtime files
  if [[ "$scope" == "runtime" || "$scope" == "all" ]]; then
    step=$((step + 1))
    step_start "$step" "Scanning stale runtime files..."
    step_done
    _purge_scan_runtime "$runtime_dir" "$session_active" "$session" "$list_file" "$now"
    _purge_tally "$list_file"
    rt_files=$_COUNT
    rt_bytes=$_BYTES
  fi

  # Step: Scan research artifacts (only for --scope all)
  if [[ "$scope" == "all" ]]; then
    step=$((step + 1))
    local rt_count_before=$_COUNT
    step_start "$step" "Scanning expired research artifacts..."
    step_done
    _purge_scan_research "$runtime_dir" "$list_file" "$now"
    _purge_tally "$list_file"
    res_files=$((_COUNT - rt_count_before))
    res_bytes=$((_BYTES - rt_bytes))
  fi

  # Step: Audit context
  if [[ "$scope" == "context" || "$scope" == "all" ]]; then
    step=$((step + 1))
    step_start "$step" "Auditing context file sizes..."
    step_done
    _purge_audit_context
  fi

  # Step: Audit hooks
  if [[ "$scope" == "hooks" || "$scope" == "all" ]]; then
    step=$((step + 1))
    step_start "$step" "Running context audit..."
    step_done
    _purge_audit_hooks
  fi

  # Step: Summary
  step=$((step + 1))
  step_start "$step" "Summary"
  printf '\n'

  local total_files=$((rt_files + res_files))

  if [[ $total_files -eq 0 ]]; then
    printf "         ${SUCCESS}Nothing to purge — runtime is clean.${RESET}\n\n"
  else
    _purge_summary "$rt_files" "$rt_bytes" "$res_files" "$res_bytes" "$dry_run"
    if ! $dry_run; then
      local do_purge=true
      if ! $force; then
        doey_confirm "Found ${total_files} stale files ($(_purge_format_bytes "$((rt_bytes + res_bytes))")). Purge?" || do_purge=false
      fi
      if $do_purge; then
        _purge_execute "$list_file"
      else
        printf "  ${DIM}Cancelled${RESET}\n"
      fi
    fi
  fi

  _purge_write_report "$runtime_dir" "$name" "$session_active" "$dry_run" "$scope" \
    "$rt_files" "$rt_bytes" "$res_files" "$res_bytes"
}
