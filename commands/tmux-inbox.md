# Skill: tmux-inbox

Check and read messages from other Claude instances.

## Usage
`/tmux-inbox`

## Prompt
You are checking your inbox for messages from other Claude Code instances in TMUX.

### Steps

1. Identify your pane:
   ```bash
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   MY_PANE_SAFE=${MY_PANE//[:.]/_}
   ```

2. List and read all messages addressed to you:
   ```bash
   ls -t /tmp/claude-team/messages/${MY_PANE_SAFE}_*.msg 2>/dev/null
   ```

3. For each message file found, read it and display it to the user.

4. After reading, archive the messages:
   ```bash
   mkdir -p /tmp/claude-team/messages/archive
   mv /tmp/claude-team/messages/${MY_PANE_SAFE}_*.msg /tmp/claude-team/messages/archive/ 2>/dev/null
   ```

5. If no messages found, tell the user the inbox is empty.

6. If a message requires a response, ask the user if they want to reply using `/tmux-send`.
