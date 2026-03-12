# Skill: doey-inbox

Check and read messages from other Claude instances.

## Usage
`/doey-inbox`

## Prompt
Check your inbox for messages from other Claude Code instances.

### Steps

1. **Discover runtime and identity:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   MY_PANE_SAFE=${MY_PANE//[:.]/_}
   ```

2. **Read messages:** `ls -t "${RUNTIME_DIR}/messages/${MY_PANE_SAFE}_"*.msg 2>/dev/null`
   Display each message to user.

3. **Archive:** `mkdir -p "${RUNTIME_DIR}/messages/archive" && mv "${RUNTIME_DIR}/messages/${MY_PANE_SAFE}_"*.msg "${RUNTIME_DIR}/messages/archive/" 2>/dev/null`

4. If no messages, report inbox empty. If message needs response, suggest `/doey-send`.
