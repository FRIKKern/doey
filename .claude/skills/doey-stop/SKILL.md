---
name: doey-stop
description: Stop a worker by pane number — kills Claude process, updates status
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team config: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; [ -f "$RD/team_${W}.env" ] && cat "$RD/team_${W}.env" 2>/dev/null|| true`
- Worker statuses: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; W="${DOEY_WINDOW_INDEX:-0}"; for f in "$RD"/status/*_${W}_*.status; do [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""; done 2>/dev/null || true`

If no pane number given, list workers from injected data and ask which to stop. Then validate and execute:

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
source "$RD/session.env"
W="${DOEY_WINDOW_INDEX:-0}"
[ -f "$RD/team_${W}.env" ] && source "$RD/team_${W}.env"

TARGET="$PANE_NUMBER"  # from user argument
[ "$TARGET" = "0" ] && { echo "ERROR: Cannot stop pane ${W}.0 (Window Manager)"; exit 1; }

VALID=false
for i in $(echo "$WORKER_PANES" | tr ',' ' '); do [ "$i" = "$TARGET" ] && VALID=true; done
[ "$VALID" = "false" ] && { echo "ERROR: Pane ${W}.${TARGET} not a worker. Valid: ${WORKER_PANES}"; exit 1; }

PANE="${SESSION_NAME}:${W}.${TARGET}"
tmux copy-mode -q -t "$PANE" 2>/dev/null
PANE_PID=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)

if [ -z "$CHILD_PID" ]; then
  echo "No Claude process in pane ${W}.${TARGET} — already stopped"
else
  kill "$CHILD_PID" 2>/dev/null; sleep 3
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && { kill -9 "$CHILD_PID" 2>/dev/null; sleep 1; }
  CHILD_PID=$(pgrep -P "$PANE_PID" 2>/dev/null)
  [ -n "$CHILD_PID" ] && { echo "ERROR: Failed to stop — manual intervention needed"; exit 1; }
fi

PANE_SAFE=$(echo "$PANE" | tr ':.' '_')
mkdir -p "${RD}/status"
cat > "${RD}/status/${PANE_SAFE}.status" << EOF
PANE: ${PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: FINISHED
TASK: manually stopped
EOF
echo "Stopped pane ${W}.${TARGET} — status set to FINISHED"
```

### Rules
- Never stop Window Manager (pane 0) or Watchdog
- Kill by PID, never via `/exit` or `send-keys`
- Always update status after stopping
- Pane shell stays alive for restart via `/doey-dispatch` or `/doey-clear`
