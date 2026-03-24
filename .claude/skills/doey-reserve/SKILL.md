---
name: doey-reserve
description: Reserve/unreserve the current pane to prevent Window Manager dispatch. Use when you need to "reserve this pane", "prevent dispatch to my pane", or "unreserve a worker".
---

`/doey-reserve` — reserve | `/doey-reserve off` — unreserve | `/doey-reserve list` — list

- Current pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`

**Do NOT ask for confirmation.** No arg → reserve, `off`/`unreserve` → unreserve, `list` → display injected data.

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RD}/status"
ACTION="${1:-reserve}"  # "reserve" (default) or "unreserve"/"off"
case "$ACTION" in off|unreserve) ACTION="unreserve" ;; *) ACTION="reserve" ;; esac
if [ "$ACTION" = "reserve" ]; then
  echo "permanent" > "${RD}/status/${SAFE}.reserved"
  STATUS="RESERVED"
else
  rm -f "${RD}/status/${SAFE}.reserved"
  STATUS="READY"
fi
cat > "${RD}/status/${SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: ${STATUS}
TASK:
EOF
echo "Pane ${MY_PANE} ${ACTION}d"
```

### Rules
- Always target THIS pane — never ask which pane
- Do NOT ask for confirmation
