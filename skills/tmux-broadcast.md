# Skill: tmux-broadcast

Broadcast a message to ALL other Claude instances in TMUX.

## Usage
`/tmux-broadcast`

## Prompt
You are broadcasting a message to all other Claude Code instances in your TMUX session.

### Steps

1. Identify yourself:
   ```bash
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   MY_SESSION=$(tmux display-message -p '#{session_name}')
   ```

2. Ask the user for the broadcast message (if not already provided).

3. Write a broadcast file:
   ```bash
   TIMESTAMP=$(date +%s%N)
   cat > "/tmp/claude-team/broadcasts/${TIMESTAMP}.broadcast" <<EOF
   FROM: $MY_PANE
   TIME: $(date -Iseconds)
   ---
   $MESSAGE
   EOF
   ```

4. Send the `/tmux-inbox-broadcast` trigger to every OTHER pane in the session:
   ```bash
   for pane in $(tmux list-panes -s -t "$MY_SESSION" -F '#{session_name}:#{window_index}.#{pane_index}'); do
     if [ "$pane" != "$MY_PANE" ]; then
       # Also write a per-pane message so they see it in inbox
       PANE_SAFE=${pane//[:.]/_}
       cp "/tmp/claude-team/broadcasts/${TIMESTAMP}.broadcast" "/tmp/claude-team/messages/${PANE_SAFE}_${TIMESTAMP}.msg"
       tmux send-keys -t "$pane" "/tmux-inbox" Enter
     fi
   done
   ```

This notifies all other panes to check their inbox.
