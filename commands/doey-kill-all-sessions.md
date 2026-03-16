# Skill: doey-kill-all-sessions

Kill all running Doey tmux sessions across all projects — processes, sessions, and runtime files.

## Usage
`/doey-kill-all-sessions`

## Prompt
You are killing all running Doey tmux sessions.

### Step 1: Confirm with user

**Before doing anything**, ask the user:

> This will kill ALL running Doey sessions, all their processes, and remove all runtime files under `/tmp/doey/`. Proceed? (yes/no)

**Do NOT proceed without explicit confirmation.**

### Step 2: Find and kill all Doey sessions

```bash
SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^doey-' || true)

if [ -z "$SESSIONS" ]; then
  echo "No Doey sessions found."
  exit 0
fi

echo "Found Doey sessions:"
for s in $SESSIONS; do
  echo "  - $s"
done
echo ""

TOTAL_KILLED=0
TOTAL_SESSIONS=0

for SESSION in $SESSIONS; do
  echo "Killing ${SESSION}..."
  TOTAL_SESSIONS=$((TOTAL_SESSIONS + 1))

  # Kill all pane child processes
  for w in $(tmux list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null); do
    for pane_pid in $(tmux list-panes -t "${SESSION}:${w}" -F '#{pane_pid}' 2>/dev/null); do
      CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
      if [ -n "$CHILD_PID" ]; then
        kill "$CHILD_PID" 2>/dev/null
        TOTAL_KILLED=$((TOTAL_KILLED + 1))
      fi
    done
  done
done

echo "Sent SIGTERM to ${TOTAL_KILLED} processes"
sleep 2

# SIGKILL stragglers
for SESSION in $SESSIONS; do
  for w in $(tmux list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null); do
    for pane_pid in $(tmux list-panes -t "${SESSION}:${w}" -F '#{pane_pid}' 2>/dev/null); do
      CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
      [ -n "$CHILD_PID" ] && kill -9 "$CHILD_PID" 2>/dev/null
    done
  done
done
sleep 1

# Kill all sessions
for SESSION in $SESSIONS; do
  tmux kill-session -t "$SESSION" 2>/dev/null
  echo "  ${SESSION} killed"
done
```

### Step 3: Clean up all runtime directories

```bash
# Remove all Doey runtime directories
rm -rf /tmp/doey/*/
echo "All runtime directories removed: /tmp/doey/*/"
```

### Step 4: Report

```
All Doey sessions torn down.
  Sessions killed: ${TOTAL_SESSIONS}
  Processes killed: ${TOTAL_KILLED}
  Runtime cleaned: /tmp/doey/*/
```

### Rules
- **ALWAYS confirm with the user** before proceeding — this is destructive and irreversible
- **Kill all processes before killing sessions** — prevents orphans
- **Remove all runtime directories** — team files, status, results, messages
- **Handle zero sessions gracefully** — report "No Doey sessions found" and stop
- All bash must be 3.2 compatible
