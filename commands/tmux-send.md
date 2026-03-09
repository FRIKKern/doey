# Skill: tmux-send

Send a message to another Claude instance in TMUX.

## Usage
`/tmux-send`

## Prompt
You are sending a message to another Claude Code instance running in a TMUX pane.

### Steps

1. First, list available panes to find targets:
   ```bash
   tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid}'
   ```

2. Identify your own pane:
   ```bash
   tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}'
   ```

3. Ask the user which pane to message and what to say (if not already specified).

4. Write the message to the shared message bus:
   ```bash
   TIMESTAMP=$(date +%s%N)
   FROM=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   cat > "/tmp/claude-team/messages/${TARGET_PANE//[:.]/_}_${TIMESTAMP}.msg" <<EOF
   FROM: $FROM
   TO: $TARGET_PANE
   TIME: $(date -Iseconds)
   ---
   $MESSAGE
   EOF
   ```

5. Then send a keyboard notification to the target pane so the other Claude sees it:
   ```bash
   tmux send-keys -t "$TARGET_PANE" "/tmux-inbox" Enter
   ```

This triggers the target Claude to check its inbox.
