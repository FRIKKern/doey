#!/bin/sh
# Doey statusline command for Claude Code
# Shows: pane identity | status | context usage
input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
model=$(echo "$input" | jq -r '.model.display_name // ""')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
agent_name=$(echo "$input" | jq -r '.agent.name // empty')

label=""
[ -n "$TMUX_PANE" ] && label=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_title}' 2>/dev/null)
if [ -z "$label" ]; then
  if [ -n "$agent_name" ]; then label="@${agent_name}"; else label=$(basename "$cwd"); fi
fi

status=""
if [ -n "$TMUX_PANE" ] && [ -n "$DOEY_RUNTIME" ] && [ -d "$DOEY_RUNTIME/status" ]; then
  _session_name=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}' 2>/dev/null) || _session_name=""
  _pane_id=$(tmux display-message -t "$TMUX_PANE" -p '#{window_index}_#{pane_index}' 2>/dev/null) || _pane_id=""
  if [ -n "$_session_name" ] && [ -n "$_pane_id" ]; then
    _safe=$(echo "${_session_name}_${_pane_id}" | tr ':.-' '_')
    _status_file="$DOEY_RUNTIME/status/${_safe}.status"
    [ -f "$_status_file" ] && status=$(grep '^STATUS:' "$_status_file" 2>/dev/null | head -1 | cut -d' ' -f2-)
    [ -n "$used" ] && echo "$used" > "$DOEY_RUNTIME/status/context_pct_${_pane_id}" 2>/dev/null
  fi
fi
[ -z "$status" ] && status="$model"

if [ -n "$used" ]; then printf "%s  |  %s  |  ctx: %s%%" "$label" "$status" "$used"
else printf "%s  |  %s" "$label" "$status"; fi
