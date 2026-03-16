# Skill: doey-inbox

Check and read messages from other Claude instances.

## Usage
`/doey-inbox`

## Prompt
Check your inbox for messages from other Claude Code instances.

### Read and archive all messages

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=${MY_PANE//[:.]/_}

mkdir -p "${RUNTIME_DIR}/messages/delivered"

COUNT=0
for msg in "${RUNTIME_DIR}/messages/${MY_PANE_SAFE}_"*.msg; do
  [ -f "$msg" ] || continue
  COUNT=$((COUNT + 1))
  echo "=== Message ${COUNT} ==="
  cat "$msg"
  echo "---"
  mv "$msg" "${RUNTIME_DIR}/messages/delivered/"
done

if [ "$COUNT" -eq 0 ]; then
  echo "Inbox empty — no unread messages."
else
  echo "Read and archived ${COUNT} message(s)."
fi
```

If messages were found, display them to the user. If any message requests a response, suggest using `/doey-send`.
