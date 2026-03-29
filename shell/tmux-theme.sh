#!/usr/bin/env bash
# Doey tmux theme — status bar, pane borders, window styling, keybindings
# Sourced by doey.sh inside apply_doey_theme()
#
# Expected variables (set by caller):
#   session          — tmux session name
#   pane_border_fmt  — pane border format string
#   status_interval  — refresh interval (seconds)
#   SCRIPT_DIR       — path to shell/ directory

local _s="tmux set-option -t $session"

# ── Pane borders ──────────────────────────────────────────────────────
$_s pane-border-status top
$_s pane-border-format "$pane_border_fmt"
$_s pane-border-style 'fg=colour238'
$_s pane-active-border-style 'fg=cyan'
$_s pane-border-lines heavy

# ── Status bar ────────────────────────────────────────────────────────
$_s status-position bottom
$_s status-style 'bg=default,fg=colour240'
$_s status-left-length 10
$_s status-right-length 80
$_s status-left "#[fg=cyan,dim] DOEY #[default] "
$_s status-right "#[range=user|settings,fg=colour240]⚙ Settings #[norange] #[fg=colour245]#('${SCRIPT_DIR}/tmux-statusbar.sh')  #[fg=colour240]%H:%M "
$_s status-interval "$status_interval"

# ── Click: ⚙ Settings button ─────────────────────────────────────────
# tmux routes the settings button area to MouseDown1Status (center), not
# MouseDown1StatusRight.  When the click lands on the "settings" range,
# open the Settings window; otherwise fall through to the default behavior.
tmux bind-key -n MouseDown1Status \
  if-shell -F '#{==:#{mouse_status_range},settings}' \
  "run-shell -b '${SCRIPT_DIR}/tmux-settings-btn.sh #{session_name}'" \
  "switch-client -t ="

# ── Window tabs (global — applies to all existing + future windows) ───
local _sw="tmux set-window-option -g -t $session"
$_sw window-status-separator ''
$_sw window-status-format '#[fg=colour245,bg=default] #I #W '
$_sw window-status-current-format '#[fg=cyan,bg=default,bold] #I #W #[nobold]'
$_sw window-status-activity-style 'fg=colour214,bg=colour236,bold'
$_sw monitor-activity on
$_sw allow-rename off

# ── Misc ──────────────────────────────────────────────────────────────
$_s message-style 'bg=colour233,fg=cyan'
$_s visual-activity off
$_s activity-action none
$_s set-titles on
$_s set-titles-string "🤖 #{session_name} — #{pane_title}"
$_s mouse on
$_s set-clipboard on

local _clip_cmd=""
local _try; for _try in "pbcopy" "xclip -selection clipboard" "xsel --clipboard"; do
  command -v "${_try%% *}" >/dev/null 2>&1 && { _clip_cmd="$_try"; break; }
done
if [ -n "$_clip_cmd" ]; then
  tmux bind-key -T copy-mode    MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$_clip_cmd"
  tmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$_clip_cmd"
fi

$_s allow-passthrough on
$_s bell-action none
$_s visual-bell off

# ── Paste reliability ────────────────────────────────────────────────
# Default escape-time (500ms) causes paste from clipboard to garble —
# tmux can't tell Escape keypresses from escape sequences fast enough.
# 10ms is plenty for terminal escape sequences, eliminates paste issues.
tmux set-option -s escape-time 10
