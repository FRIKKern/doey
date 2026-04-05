#!/usr/bin/env bash
# doey-grid.sh — Grid layout functions for Doey team windows.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_grid_sourced:-}" = "1" ] && return 0
__doey_grid_sourced=1

# shellcheck source=doey-helpers.sh
GRID_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GRID_SCRIPT_DIR}/doey-helpers.sh"

# ── Worker CSV ──────────────────────────────────────────────────────────
# Build a comma-separated list of worker pane indices (1..total-1).
# Usage: _build_worker_csv <total_panes>
_build_worker_csv() {
  local total="$1" csv="" i
  for (( i=1; i<total; i++ )); do
    [ -n "$csv" ] && csv+=","
    csv+="$i"
  done
  echo "$csv"
}

# ── Grid Feasibility ───────────────────────────────────────────────────
# Check how many columns/rows fit in the terminal window.
# Sets: _FEASIBLE_MAX_COLS, _FEASIBLE_MAX_ROWS
_check_grid_feasibility() {
  local session="$1" window="$2" min_col_w="${3:-40}" min_row_h="${4:-8}"
  local win_dims
  win_dims="$(tmux display-message -t "$session:$window" -p '#{window_width} #{window_height}' 2>/dev/null)" || return 1
  local win_w="${win_dims%% *}"
  local win_h="${win_dims##* }"
  _FEASIBLE_MAX_COLS=$(( (win_w - 1) / (min_col_w + 1) ))
  _FEASIBLE_MAX_ROWS=$(( win_h / (min_row_h + 1) ))
  [ "$_FEASIBLE_MAX_COLS" -lt 1 ] && _FEASIBLE_MAX_COLS=1
  [ "$_FEASIBLE_MAX_ROWS" -lt 1 ] && _FEASIBLE_MAX_ROWS=1
}

# ── Layout Checksum ────────────────────────────────────────────────────
# Compute a 16-bit checksum for a tmux custom layout string.
_layout_checksum() {
  local s="$1" csum=0 i c
  for ((i=0; i<${#s}; i++)); do
    c=$(printf '%d' "'${s:$i:1}")
    csum=$(( ((csum >> 1) + ((csum & 1) << 15) + c) & 0xffff ))
  done
  printf '%04x' "$csum"
}

# ── Rebalance Grid Layout ─────────────────────────────────────────────
# Apply manager-left layout: pane 0 full-height left, workers in 2-row columns.
rebalance_grid_layout() {
  local session="$1" team_window="${2:-1}" runtime_dir="${3:-}" mgr_width=90

  local win_w win_h dims
  dims="$(tmux display-message -t "$session:${team_window}" -p '#{window_width} #{window_height}')"
  win_w="${dims%% *}"
  win_h="${dims##* }"

  local pane_ids=()
  while IFS=$'\t' read -r _idx _pid; do
    pane_ids+=("${_pid#%}")
  done < <(tmux list-panes -t "$session:${team_window}" -F '#{pane_index}	#{pane_id}')

  local num_panes=${#pane_ids[@]}
  if (( num_panes < 3 )); then return 0; fi

  if [ -z "$runtime_dir" ]; then
    runtime_dir=$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || true
  fi

  local _rgl_has_manager="true"
  if [ -n "$runtime_dir" ] && [ -f "${runtime_dir}/team_${team_window}.env" ]; then
    local _rgl_tt
    _rgl_tt="$(_env_val "${runtime_dir}/team_${team_window}.env" TEAM_TYPE)" || true
    [ "$_rgl_tt" = "freelancer" ] && _rgl_has_manager="false"
  fi

  local top_h=$((win_h / 2)) bot_h=$((win_h - win_h / 2 - 1))

  local num_workers worker_cols worker_area body="" x=0

  if [ "$_rgl_has_manager" = "true" ]; then
    local max_mgr=$((win_w / 3))
    (( mgr_width > max_mgr )) && mgr_width=$max_mgr
    num_workers=$((num_panes - 1))
    worker_cols=$(( (num_workers + 1) / 2 ))
    worker_area=$((win_w - mgr_width - 1))
    body="${mgr_width}x${win_h},${x},0,${pane_ids[0]}"
    x=$((mgr_width + 1))
  else
    num_workers=$num_panes
    worker_cols=$(( (num_workers + 1) / 2 ))
    worker_area=$win_w
  fi

  local c w wi
  if [ "$_rgl_has_manager" = "true" ]; then wi=1; else wi=0; fi
  for ((c=0; c<worker_cols; c++)); do
    if ((c == worker_cols - 1)); then
      w=$((win_w - x))
    else
      w=$((worker_area / worker_cols))
    fi
    local tp="${pane_ids[$wi]}"
    [ -n "$body" ] && body+=","
    # Determine panes in this column: 2 (or 1 if remainder)
    local _rgl_col_panes=2
    local _rgl_remaining=$((num_panes - wi))
    (( _rgl_col_panes > _rgl_remaining )) && _rgl_col_panes=$_rgl_remaining
    if (( _rgl_col_panes == 2 )); then
      local bp="${pane_ids[$((wi + 1))]}"
      body+="${w}x${win_h},${x},0[${w}x${top_h},${x},0,${tp},${w}x${bot_h},${x},$((top_h+1)),${bp}]"
    else
      body+="${w}x${win_h},${x},0,${tp}"
    fi
    wi=$((wi + _rgl_col_panes))
    x=$((x + w + 1))
  done

  local layout_str="${win_w}x${win_h},0,0{${body}}"
  tmux select-layout -t "$session:${team_window}" "$(_layout_checksum "$layout_str"),${layout_str}" 2>/dev/null || true
}

# ── Rebuild Pane State ─────────────────────────────────────────────────
# Re-scan panes in a session and build a CSV of worker pane indices.
# Sets: _worker_panes
rebuild_pane_state() {
  local session="$1" include_pane0="${2:-false}"
  _worker_panes=""
  local pidx
  while IFS='' read -r pidx; do
    [ "$pidx" = "0" ] && [ "$include_pane0" != "true" ] && continue
    [ -n "$_worker_panes" ] && _worker_panes+=","
    _worker_panes+="$pidx"
  done < <(tmux list-panes -t "$session" -F '#{pane_index}')
}

# ── Build Worker Pane List ─────────────────────────────────────────────
# Build a display-friendly list of worker panes (e.g. "2.1, 2.2, 2.3").
# Skips pane 0 unless team is freelancer type.
# Sets: _WPL_RESULT
_build_worker_pane_list() {
  local session="$1" window_index="$2"
  _WPL_RESULT=""
  # For freelancer teams, pane 0 is also a worker (no manager)
  local _wpl_skip_pane0="true"
  local _wpl_runtime
  _wpl_runtime=$(tmux show-environment -t "$session" DOEY_RUNTIME 2>/dev/null) || true
  _wpl_runtime="${_wpl_runtime#*=}"
  if [ -n "$_wpl_runtime" ] && [ -f "${_wpl_runtime}/team_${window_index}.env" ]; then
    local _wpl_tt
    _wpl_tt=$(_env_val "${_wpl_runtime}/team_${window_index}.env" TEAM_TYPE)
    [ "$_wpl_tt" = "freelancer" ] && _wpl_skip_pane0="false"
  fi
  local _pi
  for _pi in $(tmux list-panes -t "${session}:${window_index}" -F '#{pane_index}'); do
    [ "$_pi" = "0" ] && [ "$_wpl_skip_pane0" = "true" ] && continue
    [ -n "$_WPL_RESULT" ] && _WPL_RESULT="${_WPL_RESULT}, "
    _WPL_RESULT="${_WPL_RESULT}${window_index}.${_pi}"
  done
}

# ── Bulk Read Team Env ─────────────────────────────────────────────────
# Bulk-read all team env keys in a single pass.
# Sets: _ts_worker_count, _ts_grid, _ts_worker_panes, _ts_wt_dir, _ts_wt_branch,
#       _ts_team_type, _ts_team_name, _ts_team_role, _ts_worker_model,
#       _ts_manager_model, _ts_reserved
_read_team_env_bulk() {
  local _reb_file="$1" _reb_line _reb_val
  _ts_worker_count="" _ts_grid="" _ts_worker_panes=""
  _ts_wt_dir="" _ts_wt_branch="" _ts_team_type=""
  _ts_team_name="" _ts_team_role="" _ts_worker_model="" _ts_manager_model=""
  _ts_reserved=""
  [ ! -f "$_reb_file" ] && return 0
  while IFS= read -r _reb_line || [ -n "$_reb_line" ]; do
    _reb_val="${_reb_line#*=}"
    _reb_val="${_reb_val//\"/}"
    case "$_reb_line" in
      WORKER_COUNT=*)   _ts_worker_count="$_reb_val" ;;
      GRID=*)           _ts_grid="$_reb_val" ;;
      WORKER_PANES=*)   _ts_worker_panes="$_reb_val" ;;
      WORKTREE_DIR=*)   _ts_wt_dir="$_reb_val" ;;
      WORKTREE_BRANCH=*) _ts_wt_branch="$_reb_val" ;;
      TEAM_TYPE=*)      _ts_team_type="$_reb_val" ;;
      TEAM_NAME=*)      _ts_team_name="$_reb_val" ;;
      TEAM_ROLE=*)      _ts_team_role="$_reb_val" ;;
      WORKER_MODEL=*)   _ts_worker_model="$_reb_val" ;;
      MANAGER_MODEL=*)  _ts_manager_model="$_reb_val" ;;
      RESERVED=*)       _ts_reserved="$_reb_val" ;;
    esac
  done < "$_reb_file"
}

# ── Read Team State ────────────────────────────────────────────────────
# Read team state from env file and live pane count.
# Sets: _ts_dir, _ts_wt_dir, _ts_wt_branch, _ts_worker_count, _ts_grid, _ts_cols,
#       _ts_worker_panes (plus all _read_team_env_bulk vars)
_read_team_state() {
  local session="$1" runtime_dir="$2" dir="$3" team_window="$4"
  local team_env="${runtime_dir}/team_${team_window}.env"

  _ts_dir="$dir" _ts_wt_dir="" _ts_wt_branch=""

  if [ ! -f "$team_env" ]; then
    _ts_worker_count=0
    _ts_grid="${GRID:-dynamic}" _ts_cols=1 _ts_worker_panes=""
    return 0
  fi

  _read_team_env_bulk "$team_env"
  _ts_worker_count="${_ts_worker_count:-0}"
  _ts_grid="${_ts_grid:-dynamic}"

  local _pane_count
  _pane_count=$(tmux list-panes -t "$session:$team_window" 2>/dev/null | wc -l)
  _pane_count="${_pane_count// /}"
  _ts_cols=$(( (_pane_count - 1) / 2 ))
  [ "$_ts_cols" -lt 1 ] && _ts_cols=1

  [ -n "$_ts_wt_dir" ] && [ -d "$_ts_wt_dir" ] && _ts_dir="$_ts_wt_dir"
  return 0
}
