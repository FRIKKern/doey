# Skill: doey-stop-all

Stop all running Doey sessions at once.

## Usage
`/doey-stop-all`

## Prompt
You need to stop all running Doey tmux sessions.

### Steps

1. **Resolve tmux path first** — inside `while read` loops, `tmux` may not resolve from PATH. Always capture the full path upfront:

   ```bash
   TMUX_BIN=$(command -v tmux)
   ```

2. Read the projects registry and find running sessions:

   ```bash
   PROJECTS_FILE="$HOME/.claude/doey/projects"
   TMUX_BIN=$(command -v tmux)
   while IFS=: read -r name path; do
     [ -z "$name" ] && continue
     SESSION="doey-${name}"
     if "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
       echo "Stopping $SESSION ($path)..."
       "$TMUX_BIN" kill-session -t "$SESSION"
       echo "  ✓ Stopped"
     else
       echo "  ○ $SESSION — not running"
     fi
   done < "$PROJECTS_FILE"
   ```

3. Report what was stopped and what was already offline.
