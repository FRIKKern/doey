---
name: doey-debug
description: Toggle debug flight-recorder mode for Doey hooks. Use `/doey-debug on` to start recording, `/doey-debug off` to stop, `/doey-debug status` to view state. Captures hook timing, state transitions, lifecycle events, and IPC messages.
---

- Runtime dir: !`tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true`
- Debug config: !`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); [ -f "$RD/debug.conf" ] && cat "$RD/debug.conf" || echo "OFF (no debug.conf)"`
- Debug log sizes: !`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); if [ -d "$RD/debug" ]; then find "$RD/debug" -name '*.jsonl' -exec ls -lh {} \; 2>/dev/null | awk '{print $5, $NF}'; else echo "No debug/ directory"; fi`
- Last entries: !`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); if [ -d "$RD/debug" ]; then for f in $(find "$RD/debug" -name '*.jsonl' 2>/dev/null | head -8); do echo "=== $(basename "$f") ==="; tail -1 "$f" 2>/dev/null; done; else echo "No debug logs"; fi`

Default operation is `on`. Parse the user's argument to determine: `on`, `off`, or `status`.

## Operations

### `on` (default)

Enable debug mode. Run this bash:

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
if [ -z "$RD" ]; then
  echo "ERROR: Not in a Doey session (DOEY_RUNTIME not set)"
  exit 1
fi
mkdir -p "$RD/debug"
cat > "$RD/debug.conf" <<'CONF'
DOEY_DEBUG=true
DOEY_DEBUG_HOOKS=true
DOEY_DEBUG_WATCHDOG=true
DOEY_DEBUG_LIFECYCLE=true
DOEY_DEBUG_MESSAGES=true
DOEY_DEBUG_STATE=true
DOEY_DEBUG_DISPLAY=false
CONF
echo "Debug mode ON. Config: $RD/debug.conf"
echo "Logs will appear in: $RD/debug/<pane>/*.jsonl"
echo "To view: cat $RD/debug/*/hooks.jsonl | sort -t'\"' -k4"
```

### `off`

Disable debug mode (preserves logs for post-mortem). Run this bash:

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
if [ -z "$RD" ]; then
  echo "ERROR: Not in a Doey session (DOEY_RUNTIME not set)"
  exit 1
fi
if [ -f "$RD/debug.conf" ]; then
  rm -f "$RD/debug.conf"
  echo "Debug mode OFF. Config removed."
  if [ -d "$RD/debug" ]; then
    echo "Logs preserved in: $RD/debug/"
  fi
else
  echo "Debug mode was already off."
fi
```

### `status`

Show current debug state, config, log sizes, and last entry per category. Run this bash:

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
if [ -z "$RD" ]; then
  echo "ERROR: Not in a Doey session (DOEY_RUNTIME not set)"
  exit 1
fi
echo "=== Debug Mode Status ==="
if [ -f "$RD/debug.conf" ]; then
  echo "State: ON"
  echo ""
  echo "--- Config ($RD/debug.conf) ---"
  cat "$RD/debug.conf"
else
  echo "State: OFF"
fi
echo ""
if [ -d "$RD/debug" ]; then
  echo "--- Log Sizes ---"
  total=0
  while IFS= read -r f; do
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    total=$((total + sz))
    lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    echo "  $(echo "$f" | sed "s|$RD/debug/||"): ${lines} lines, ${sz} bytes"
  done <<FIND_EOF
$(find "$RD/debug" -name '*.jsonl' 2>/dev/null | sort)
FIND_EOF
  echo "  Total: ${total} bytes"
  echo ""
  echo "--- Last Entry Per Category ---"
  for cat_name in hooks lifecycle state messages watchdog; do
    latest=""
    while IFS= read -r f; do
      [ -f "$f" ] && latest="$f"
    done <<CAT_EOF
$(find "$RD/debug" -name "${cat_name}.jsonl" 2>/dev/null | head -5)
CAT_EOF
    if [ -n "$latest" ] && [ -f "$latest" ]; then
      echo "  ${cat_name}: $(tail -1 "$latest" 2>/dev/null)"
    fi
  done
else
  echo "No debug/ directory (no logs captured yet)"
fi
```

## Rules

- Debug config is NEVER sourced — it is parsed with `while read`/`case` in `common.sh`
- File existence IS the master toggle: `[ -f "$RUNTIME_DIR/debug.conf" ]`
- Per-pane log directories prevent concurrent write races
- Logs survive `off` — only `debug.conf` is removed
- Zero overhead when off: one `stat()` syscall per hook (~0.05ms)
