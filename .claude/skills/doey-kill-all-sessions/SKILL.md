---
name: doey-kill-all-sessions
description: Kill ALL Doey tmux sessions, processes, and runtime files. Use when you need to "kill all doey sessions", "shut down everything", or "nuke all doey instances".
---

- Sessions: !`tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^doey-' || echo "No Doey sessions found"`

**Confirm first:** "This kills ALL Doey sessions, processes, and removes `/tmp/doey/*/`. Proceed?"

```bash
SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^doey-' || true)
if [ -z "$SESSIONS" ]; then echo "No Doey sessions found."; exit 0; fi
echo "Found:"; for s in $SESSIONS; do echo "  - $s"; done
for sig in TERM 9; do
  for SESSION in $SESSIONS; do
    for w in $(tmux list-windows -t "$SESSION" -F '#{window_index}' 2>/dev/null); do
      for ppid in $(tmux list-panes -t "${SESSION}:${w}" -F '#{pane_pid}' 2>/dev/null); do
        pid=$(pgrep -P "$ppid" 2>/dev/null) && kill -"$sig" "$pid" 2>/dev/null
      done
    done
  done
  sleep 2
done
for SESSION in $SESSIONS; do tmux kill-session -t "$SESSION" 2>/dev/null; echo "  ${SESSION} killed"; done
rm -rf /tmp/doey/*/
echo "Runtime removed: /tmp/doey/*/"
```
