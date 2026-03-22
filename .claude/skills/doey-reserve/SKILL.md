---
name: doey-reserve
description: Reserve/unreserve the current pane. Use when you need to "reserve this pane", "protect from dispatch", or "unreserve". Prevents Window Manager from dispatching to this pane.
---

`/doey-reserve` — reserve | `/doey-reserve off` — unreserve | `/doey-reserve list` — list

- Current pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- Reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`

**Expected:** 2 bash commands (write reservation, update status), ~1 second.

**Do NOT ask for confirmation.** Parse args: no arg → reserve, `off`/`unreserve` → unreserve, `list` → display injected data.

## Step 1: Identify Current Pane

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RD}/status"
echo "Current pane: ${MY_PANE}"
```

Expected: "Current pane: session:W.N"
**If error:** Check TMUX_PANE is set.

## Step 2: Parse Action

Determine action from user argument:
- No argument → `ACTION=reserve`
- `off` or `unreserve` → `ACTION=unreserve`
- `list` → Display injected reservation data above and stop

## Step 3: Execute

```bash
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
echo "Pane ${MY_PANE} ${ACTION}d — status set to ${STATUS}"
```

Expected: "Pane session:W.N reserved — status set to RESERVED" (or unreserved/READY)
**If error:** Check RD path and permissions.

## Step 4: Confirm

```bash
echo "Pane ${MY_PANE} ${ACTION}d"
```

Expected: "Pane session:W.N reserved" or "Pane session:W.N unreserved"

## Gotchas
- Always target THIS pane — never ask which pane
- Do NOT ask for confirmation

Total: 4 steps, 0 errors expected.
