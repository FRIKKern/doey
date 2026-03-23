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
$_s status-right "#[fg=colour240]#('${SCRIPT_DIR}/tmux-settings-btn.sh') #[fg=colour245]#('${SCRIPT_DIR}/tmux-statusbar.sh')  #[fg=colour240]%H:%M "
$_s status-interval "$status_interval"

# ── Window tabs ───────────────────────────────────────────────────────
local _wsfmt='#[fg=colour245,bg=default] #I #W '
local _wscfmt='#[fg=cyan,bg=default,bold] #I #W #[nobold]'

for _win in $(tmux list-windows -t "$session" -F '#I'); do
  tmux set-window-option -t "$session:$_win" window-status-separator ''
  tmux set-window-option -t "$session:$_win" window-status-format "$_wsfmt"
  tmux set-window-option -t "$session:$_win" window-status-current-format "$_wscfmt"
  tmux set-window-option -t "$session:$_win" window-status-activity-style 'fg=colour214,bg=colour236,bold'
  tmux set-window-option -t "$session:$_win" monitor-activity on
  tmux set-window-option -t "$session:$_win" allow-rename off
done

# Ensure new windows also get the theme
tmux set-hook -t "$session" after-new-window "set-window-option window-status-separator ''; set-window-option window-status-format \"$_wsfmt\"; set-window-option window-status-current-format \"$_wscfmt\"; set-window-option window-status-activity-style 'fg=colour214,bg=colour236,bold'; set-window-option monitor-activity on; set-window-option allow-rename off"

# ── Misc ──────────────────────────────────────────────────────────────
$_s message-style 'bg=colour233,fg=cyan'
$_s visual-activity off
$_s set-titles on
$_s set-titles-string "🤖 #{session_name} — #{pane_title}"
$_s mouse on
$_s set-clipboard on

local _clip_cmd=""
if command -v pbcopy >/dev/null 2>&1; then _clip_cmd="pbcopy"
elif command -v xclip >/dev/null 2>&1; then _clip_cmd="xclip -selection clipboard"
elif command -v xsel >/dev/null 2>&1; then _clip_cmd="xsel --clipboard"
fi
if [ -n "$_clip_cmd" ]; then
  tmux bind-key -T copy-mode    MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$_clip_cmd"
  tmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$_clip_cmd"
fi

$_s allow-passthrough on
$_s bell-action none
$_s visual-bell off
