# Skill: doey-kill-all-sessions

Kill ALL Doey tmux sessions, processes, and runtime files.

## Usage
`/doey-kill-all-sessions`

## Prompt

**Confirm first:** "This will kill ALL Doey sessions, processes, and remove `/tmp/doey/*/`. Proceed?"
Do NOT proceed without explicit yes.

### Find and kill all sessions

```bash
SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^doey-' || true)
if [ -z "$SESSIONS" ]; then echo "No Doey sessions found."; exit 0; fi

echo "Found:"; for s in $SESSIONS; do echo "  - $s"; done; echo ""

TOTAL_KILLED=0; TOTAL_SESSIONS=0
for SESSION in $SESSIONS; do
  echo "Killing ${SESSION}..."
  TOTAL_SESSIONS=$((TOTAL_SESSIONS + 1))
  for w in $(tmux list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null); do
    for pane_pid in $(tmux list-panes -t "${SESSION}:${w}" -F '#{pane_pid}' 2>/dev/null); do
      CHILD_PID=$(pgrep -P "$pane_pid" 2>/dev/null)
      if [ -n "$CHILD_PID" ]; then kill "$CHILD_PID" 2>/dev/null; TOTAL_KILLED=$((TOTAL_KILLED + 1)); fi
    done
  done
done
echo "Sent SIGTERM to ${TOTAL_KILLED} processes"; sleep 2

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

for SESSION in $SESSIONS; do tmux kill-session -t "$SESSION" 2>/dev/null; echo "  ${SESSION} killed"; done
```

### Clean up and report

```bash
rm -rf /tmp/doey/*/
echo "Runtime removed: /tmp/doey/*/"
```

Report: sessions killed, processes killed, runtime cleaned.

### Rules
- **Always confirm** — destructive and irreversible
- Kill processes before sessions (prevents orphans)
- Handle zero sessions gracefully
