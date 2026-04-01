---
name: doey-debug
description: Toggle debug flight-recorder mode for Doey hooks. Use `/doey-debug on` to start recording, `/doey-debug off` to stop, `/doey-debug status` to view state. Captures hook timing, state transitions, lifecycle events, and IPC messages.
---

- Debug config: !`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); [ -f "$RD/debug.conf" ] && cat "$RD/debug.conf" || echo "OFF"`
- Log sizes: !`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); [ -d "$RD/debug" ] && find "$RD/debug" -name '*.jsonl' -exec ls -lh {} \; 2>/dev/null | awk '{print $5, $NF}' || echo "No logs"`

Parse argument: `on` (default) | `off` | `status`. All ops start with:
`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); [ -z "$RD" ] && { echo "ERROR: DOEY_RUNTIME not set"; exit 1; }`

### `on` (default)
```bash
mkdir -p "$RD/debug"
cat > "$RD/debug.conf" <<'CONF'
DOEY_DEBUG=true
DOEY_DEBUG_HOOKS=true
DOEY_DEBUG_SM=true
DOEY_DEBUG_LIFECYCLE=true
DOEY_DEBUG_MESSAGES=true
DOEY_DEBUG_STATE=true
DOEY_DEBUG_DISPLAY=false
CONF
echo "Debug ON. Logs: $RD/debug/<pane>/*.jsonl"
```

### `off`
```bash
[ -f "$RD/debug.conf" ] && { rm -f "$RD/debug.conf"; echo "Debug OFF. Logs preserved in $RD/debug/"; } || echo "Already off."
```

### `status`
```bash
echo "=== Debug Status ==="
[ -f "$RD/debug.conf" ] && { echo "State: ON"; cat "$RD/debug.conf"; } || echo "State: OFF"
if [ -d "$RD/debug" ]; then
  find "$RD/debug" -name '*.jsonl' 2>/dev/null | sort | while IFS= read -r f; do
    echo "  $(echo "$f" | sed "s|$RD/debug/||"): $(wc -l < "$f" | tr -d ' ') lines"
  done
  for c in hooks lifecycle state messages sm; do
    f=$(find "$RD/debug" -name "${c}.jsonl" 2>/dev/null | tail -1)
    [ -f "$f" ] && echo "  ${c}: $(tail -1 "$f")"
  done
else echo "No logs yet"; fi
```

Config parsed (not sourced) in `common.sh`. File existence = toggle. Per-pane dirs prevent races. Logs survive `off`.
