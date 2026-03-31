#!/usr/bin/env bash
# Doey tmux theme — status bar, pane borders, window styling, keybindings
# Sourced by doey.sh inside apply_doey_theme()
#
# Expected variables (set by caller):
#   session          — tmux session name
#   pane_border_fmt  — pane border format string
#   status_interval  — refresh interval (seconds)
#   SCRIPT_DIR       — path to shell/ directory
#
# Performance: all tmux options are batched into a single source-file call
# (~3ms) instead of ~26 individual tmux invocations (~75-125ms).

# Detect clipboard command for copy-mode bindings
local _clip_cmd=""
local _try; for _try in "pbcopy" "xclip -selection clipboard" "xsel --clipboard"; do
  command -v "${_try%% *}" >/dev/null 2>&1 && { _clip_cmd="$_try"; break; }
done

local _clip_lines=""
if [ -n "$_clip_cmd" ]; then
  _clip_lines="bind-key -T copy-mode    MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel \"$_clip_cmd\"
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel \"$_clip_cmd\""
fi

local _theme_file
_theme_file=$(mktemp "${TMPDIR:-/tmp}/doey_theme_XXXXXX.conf") || {
  printf '%s\n' "tmux-theme: failed to create temp file" >&2
  return 1
}

# Build a single tmux conf with all theme commands.
# The heredoc is UNQUOTED so shell variables expand before writing.
cat > "$_theme_file" <<THEME_EOF
# ── Pane borders ──────────────────────────────────────────────────────
set-option -t $session pane-border-status top
set-option -t $session pane-border-format "$pane_border_fmt"
set-option -t $session pane-border-style 'fg=colour238'
set-option -t $session pane-active-border-style 'fg=cyan'
set-option -t $session pane-border-lines heavy

# ── Status bar ────────────────────────────────────────────────────────
set-option -t $session status-position bottom
set-option -t $session status-style 'bg=default,fg=colour240'
set-option -t $session status-left-length 10
set-option -t $session status-right-length 80
set-option -t $session status-left "#[fg=cyan,dim] DOEY #[default] "
set-option -t $session status-right "#[range=user|settings,fg=colour240]⚙ Settings #[norange] #[fg=colour245]#('${SCRIPT_DIR}/tmux-statusbar.sh')  #[fg=colour240]%H:%M "
set-option -t $session status-interval $status_interval

# ── Click: ⚙ Settings button ─────────────────────────────────────────
bind-key -n MouseDown1Status if-shell -F '#{==:#{mouse_status_range},settings}' "run-shell -b '${SCRIPT_DIR}/tmux-settings-btn.sh #{session_name}'" "switch-client -t ="

# ── Window tabs (global) ─────────────────────────────────────────────
set-window-option -g -t $session window-status-separator ''
set-window-option -g -t $session window-status-format '#[fg=colour245,bg=default] #I #W #(${SCRIPT_DIR}/tmux-window-workers.sh #I)#[default] '
set-window-option -g -t $session window-status-current-format '#[fg=cyan,bg=default,bold] #I #W#[nobold] #(${SCRIPT_DIR}/tmux-window-workers.sh #I)#[default] '
set-window-option -g -t $session window-status-activity-style 'fg=colour214,bg=colour236,bold'
set-window-option -g -t $session monitor-activity on
set-window-option -g -t $session allow-rename off

# ── Misc ──────────────────────────────────────────────────────────────
set-option -t $session message-style 'bg=colour233,fg=cyan'
set-option -t $session visual-activity off
set-option -t $session activity-action none
set-option -t $session set-titles on
set-option -t $session set-titles-string "🤖 #{session_name} — #{pane_title}"
set-option -t $session mouse on
set-option -t $session set-clipboard on
$_clip_lines
set-option -t $session allow-passthrough on
set-option -t $session bell-action none
set-option -t $session visual-bell off

# ── Paste reliability ────────────────────────────────────────────────
# 10ms escape-time eliminates clipboard paste garbling
set-option -s escape-time 10
THEME_EOF

tmux source-file "$_theme_file" 2>/dev/null
local _rc=$?
rm -f "$_theme_file"

if [ "$_rc" -ne 0 ]; then
  printf '%s\n' "tmux-theme: source-file failed (rc=$_rc), session=$session" >&2
fi
