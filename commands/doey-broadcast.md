# Skill: doey-broadcast

Broadcast a message to ALL other Claude instances in TMUX.

## Usage
`/doey-broadcast`

## Prompt
You are broadcasting a message to all other Claude Code instances in your TMUX session.

### Steps

1. Discover runtime directory and identify yourself:
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   ```

2. Ask the user for the broadcast message (if not already provided).

3. Write a broadcast file:
   ```bash
   TIMESTAMP=$(date +%s%N)
   cat > "${RUNTIME_DIR}/broadcasts/${TIMESTAMP}.broadcast" <<EOF
   FROM: $MY_PANE
   TIME: $(date -Iseconds)
   ---
   $MESSAGE
   EOF
   ```

4. Send the `/doey-inbox` trigger to every OTHER pane in the session:
   ```bash
   for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
     if [ "$pane" != "$MY_PANE" ]; then
       # Also write a per-pane message so they see it in inbox
       PANE_SAFE=${pane//[:.]/_}
       cp "${RUNTIME_DIR}/broadcasts/${TIMESTAMP}.broadcast" "${RUNTIME_DIR}/messages/${PANE_SAFE}_${TIMESTAMP}.msg"
       tmux send-keys -t "$pane" "/doey-inbox" Enter
     fi
   done
   ```

This notifies all other panes to check their inbox.
