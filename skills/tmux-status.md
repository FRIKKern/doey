# Skill: tmux-status

Share your status or check the status of other Claude instances.

## Usage
`/tmux-status`

## Prompt
You are managing status updates across Claude Code instances in TMUX.

### Steps

1. Identify yourself:
   ```bash
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   MY_PANE_SAFE=${MY_PANE//[:.]/_}
   ```

2. Ask the user: **set** your status or **view** all statuses?

### Setting status
Write your current status:
```bash
cat > "/tmp/claude-team/status/${MY_PANE_SAFE}.status" <<EOF
PANE: $MY_PANE
UPDATED: $(date -Iseconds)
STATUS: $STATUS_TEXT
TASK: $CURRENT_TASK
EOF
```

### Viewing statuses
Read all status files:
```bash
for f in /tmp/claude-team/status/*.status; do
  echo "---"
  cat "$f"
done
```

Display a summary table showing each pane, its status, and what task it's working on.
