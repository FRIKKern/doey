# Skill: doey-inbox

Check and read messages from other Claude instances.

## Usage
`/doey-inbox`

## Prompt
You are checking your inbox for messages from other Claude Code instances in TMUX.

### Steps

1. Discover runtime directory and identify your pane:
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   MY_PANE_SAFE=${MY_PANE//[:.]/_}
   ```

2. List and read all messages addressed to you:
   ```bash
   ls -t "${RUNTIME_DIR}/messages/${MY_PANE_SAFE}_"*.msg 2>/dev/null
   ```

3. For each message file found, read it and display it to the user.

4. After reading, archive the messages:
   ```bash
   mkdir -p "${RUNTIME_DIR}/messages/archive"
   mv "${RUNTIME_DIR}/messages/${MY_PANE_SAFE}_"*.msg "${RUNTIME_DIR}/messages/archive/" 2>/dev/null
   ```

5. If no messages found, tell the user the inbox is empty.

6. If a message requires a response, ask the user if they want to reply using `/doey-send`.
