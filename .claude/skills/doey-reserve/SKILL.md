---
name: doey-reserve
description: Reserve/unreserve the current pane to prevent Window Manager dispatch
---

## Usage
`/doey-reserve` — reserve this pane
`/doey-reserve off` — unreserve
`/doey-reserve list` — list all reservations

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Current pane: !`tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null|| true`
- Current reservations: !`RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"; for f in "$RD"/status/*.reserved; do [ -f "$f" ] && echo "RESERVED: $(basename $f .reserved)"; done 2>/dev/null || true`

## Prompt

**Do NOT ask for confirmation — just do it.** Parse arguments: no arg → reserve, `off`/`unreserve` → unreserve, `list` → list.

### Reserve

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RD}/status"
echo "permanent" > "${RD}/status/${SAFE}.reserved"
cat > "${RD}/status/${SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: RESERVED
TASK:
EOF
echo "Pane ${MY_PANE} reserved"
```

### Unreserve

```bash
RD="$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
SAFE=$(echo "$MY_PANE" | tr ':.' '_')
rm -f "${RD}/status/${SAFE}.reserved"
cat > "${RD}/status/${SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: READY
TASK:
EOF
echo "Pane ${MY_PANE} unreserved"
```

### List

Display the injected reservation data. If none, say "No active reservations".

### Rules
- Always target THIS pane (`$MY_PANE`) — never ask which pane
- Do NOT ask for confirmation
