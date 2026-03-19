# Skill: doey-kill-all-sessions

Kill ALL running Doey tmux sessions, processes, and runtime files across all projects.

## Usage
`/doey-kill-all-sessions`

## Prompt

### Step 1: Confirm

**Ask user first:** "This will kill ALL Doey sessions and remove all runtime under `/tmp/doey/`. Proceed?" Do NOT proceed without explicit yes.

### Step 2: Find and kill all sessions

```bash
SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^doey-' || true)
[ -z "$SESSIONS" ] && echo "No Doey sessions found." && exit 0

echo "Found:"; for s in $SESSIONS; do echo "  - $s"; done

TOTAL_KILLED=0; TOTAL_SESSIONS=0
for SESSION in $SESSIONS; do
  TOTAL_SESSIONS=$((TOTAL_SESSIONS + 1))
  # SIGTERM all pane children
  for w in $(tmux list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null); do
    for pane_pid in $(tmux list-panes -t "${SESSION}:${w}" -F '#{pane_pid}' 2>/dev/null); do
      CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
      [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null && TOTAL_KILLED=$((TOTAL_KILLED + 1))
    done
  done
done
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

for SESSION in $SESSIONS; do tmux kill-session -t "$SESSION" 2>/dev/null; done
rm -rf /tmp/doey/*/
```

### Step 3: Report

Sessions killed, processes stopped, runtime cleaned. Report counts.
