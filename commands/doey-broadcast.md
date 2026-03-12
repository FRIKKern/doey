# Skill: doey-broadcast

Broadcast a message to ALL other Claude instances in TMUX.

## Usage
`/doey-broadcast`

## Prompt
You are broadcasting a message to all other Claude Code instances.

### Steps

1. **Discover runtime and identity:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   ```

2. Ask the user for the broadcast message (if not provided).

3. **Write broadcast and notify all other panes:**
   ```bash
   TIMESTAMP=$(date +%s%N)
   cat > "${RUNTIME_DIR}/broadcasts/${TIMESTAMP}.broadcast" <<EOF
   FROM: $MY_PANE
   TIME: $(date -Iseconds)
   ---
   $MESSAGE
   EOF
   for pane in $(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_index}.#{pane_index}'); do
     [ "$pane" != "$MY_PANE" ] && {
       PANE_SAFE=${pane//[:.]/_}
       cp "${RUNTIME_DIR}/broadcasts/${TIMESTAMP}.broadcast" "${RUNTIME_DIR}/messages/${PANE_SAFE}_${TIMESTAMP}.msg"
       tmux send-keys -t "$pane" "/doey-inbox" Enter
     }
   done
   ```
