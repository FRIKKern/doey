#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# claude-team — Launch a TMUX Claude Team session
#
# Usage:
#   claude-team              # 6x2 grid (12 panes) in current directory
#   claude-team 4x3          # 4x3 grid (12 panes)
#   claude-team 8x1          # 8x1 grid (8 panes)
#
# Environment:
#   CLAUDE_TEAM_DIR   — Working directory (default: $PWD)
#   CLAUDE_TEAM_NAME  — tmux session name (default: "claude-team")
#
# Alias suggestion:
#   alias ct="claude-team"
# ──────────────────────────────────────────────────────────────────────

dir="${CLAUDE_TEAM_DIR:-$PWD}"
grid="${1:-6x2}"
cols="${grid%x*}"
rows="${grid#*x}"
total=$(( cols * rows ))
watchdog_pane=$cols
session="${CLAUDE_TEAM_NAME:-claude-team}"

# ── Clean up ─────────────────────────────────────────────────
tmux kill-session -t "$session" 2>/dev/null
rm -rf /tmp/claude-team
mkdir -p /tmp/claude-team/{messages,broadcasts,status}

tmux new-session -d -s "$session" -c "$dir"

# ── Theme: pane borders with titles ──────────────────────────
tmux set-option -t "$session" pane-border-status top
tmux set-option -t "$session" pane-border-format \
  ' #{?pane_active,#[fg=green#,bold],#[fg=colour245]}#{pane_index} #{pane_title} #[default]'
tmux set-option -t "$session" pane-border-style 'fg=colour238'
tmux set-option -t "$session" pane-active-border-style 'fg=green'
tmux set-option -t "$session" pane-border-lines heavy

# ── Status bar ───────────────────────────────────────────────
tmux set-option -t "$session" status-position top
tmux set-option -t "$session" status-style 'bg=colour235,fg=colour248'
tmux set-option -t "$session" status-left-length 40
tmux set-option -t "$session" status-right-length 60
tmux set-option -t "$session" status-left \
  '#[fg=colour235,bg=green,bold]  CLAUDE TEAM #[fg=green,bg=colour235] '
tmux set-option -t "$session" status-right \
  '#[fg=colour245] #{pane_title} #[fg=colour235,bg=colour245] %H:%M #[fg=colour248,bg=colour240] #(echo $(($(ls /tmp/claude-team/messages/*.msg 2>/dev/null | wc -l))) msgs) '
tmux set-option -t "$session" status-interval 5

# ── Split into grid ──────────────────────────────────────────
for (( r=1; r<rows; r++ )); do
  tmux split-window -v -t "$session:0.0" -c "$dir"
done
tmux select-layout -t "$session" even-vertical

for (( r=0; r<rows; r++ )); do
  for (( c=1; c<cols; c++ )); do
    tmux split-window -h -t "$session:0.$((r * cols))" -c "$dir"
  done
done

sleep 2

# ── Name all panes ──────────────────────────────────────────
tmux select-pane -t "$session:0.0" -T "MGR  Manager"
tmux select-pane -t "$session:0.$watchdog_pane" -T "RUN  Watchdog"
wnum=0
for (( i=1; i<total; i++ )); do
  [[ $i -eq $watchdog_pane ]] && continue
  (( wnum++ ))
  tmux select-pane -t "$session:0.$i" -T "W${wnum}  Worker ${wnum}"
done

# ── Launch Manager (pane 0.0) ────────────────────────────────
tmux send-keys -t "$session:0.0" \
  "claude --dangerously-skip-permissions --agent tmux-manager" Enter
sleep 0.5

# Auto-send initial briefing once Manager is ready
(
  sleep 10
  # Build worker pane list (all panes except 0.0 and 0.$watchdog_pane)
  worker_panes=""
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    [[ -n "$worker_panes" ]] && worker_panes+=", "
    worker_panes+="0.$i"
  done
  tmux send-keys -t "$session:0.0" \
    "Team is online. You have $((total - 2)) workers in panes ${worker_panes}. Pane 0.$watchdog_pane is the Watchdog (auto-accepts prompts). All workers are idle and awaiting tasks. What should we work on?" Enter
) &

# ── Launch Watchdog (pane 0.$watchdog_pane) ──────────────────
tmux send-keys -t "$session:0.$watchdog_pane" \
  "claude --dangerously-skip-permissions --agent tmux-watchdog" Enter
sleep 0.5

# Auto-start the watchdog loop
(
  sleep 12
  # Build worker pane list for watchdog
  watch_panes=""
  for (( i=1; i<total; i++ )); do
    [[ $i -eq $watchdog_pane ]] && continue
    [[ -n "$watch_panes" ]] && watch_panes+=", "
    watch_panes+="0.$i"
  done
  tmux send-keys -t "$session:0.$watchdog_pane" \
    "Start monitoring. Total panes: $total. Skip pane 0.0 (Manager) and 0.$watchdog_pane (yourself). Monitor panes ${watch_panes}." Enter
) &

# ── Launch Workers (all panes except Manager and Watchdog) ──
for (( i=1; i<total; i++ )); do
  [[ $i -eq $watchdog_pane ]] && continue
  tmux send-keys -t "$session:0.$i" \
    "claude --dangerously-skip-permissions" Enter
  sleep 0.3
done

# ── Focus on Manager pane, attach ────────────────────────────
tmux select-pane -t "$session:0.0"
tmux attach -t "$session"
