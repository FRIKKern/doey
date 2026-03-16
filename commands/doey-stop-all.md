# Skill: doey-stop-all

Stop all running Doey sessions at once.

## Usage
`/doey-stop-all`

## Prompt

> ⚠️ **DEPRECATED:** Replaced by `/doey-kill-all-sessions`. This command will be removed in a future version.

Stop all running Doey tmux sessions.

### Steps

1. **Read projects registry and kill running sessions:**
   ```bash
   TMUX_BIN=$(command -v tmux)
   while IFS=: read -r name path; do
     [ -z "$name" ] && continue
     SESSION="doey-${name}"
     if "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
       echo "Stopping $SESSION ($path)..."
       "$TMUX_BIN" kill-session -t "$SESSION"
       rm -rf "/tmp/doey/${name}"
       echo "  Stopped (session killed, runtime cleaned)"
     else
       echo "  $SESSION — not running"
     fi
   done < "$HOME/.claude/doey/projects"
   ```

2. Report what was stopped and what was already offline.
