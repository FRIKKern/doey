# Skill: tmux-team

View the full team of Claude instances and their pane layout.

## Usage
`/tmux-team`

## Prompt
You are showing the team overview of all Claude Code instances running in TMUX.

### Steps

1. Identify yourself:
   ```bash
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   ```

2. List all panes with details:
   ```bash
   tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} | PID: #{pane_pid} | #{pane_width}x#{pane_height} | #{pane_current_command}'
   ```

3. Check for status files:
   ```bash
   for f in /tmp/claude-team/status/*.status; do
     [ -f "$f" ] && cat "$f" && echo "---"
   done
   ```

4. Check for unread messages per pane:
   ```bash
   for pane in $(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}'); do
     PANE_SAFE=${pane//[:.]/_}
     COUNT=$(ls /tmp/claude-team/messages/${PANE_SAFE}_*.msg 2>/dev/null | wc -l)
     echo "$pane: $COUNT unread messages"
   done
   ```

5. Present a formatted team overview table:
   - Pane ID
   - Status (from status files, or "unknown")
   - Current task (from status files, or "unknown")
   - Unread message count
   - Mark YOUR pane with `<-- you` indicator
