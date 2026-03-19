# Skill: doey-reserve

Reserve/unreserve the current pane to prevent Window Manager dispatch.

## Usage
`/doey-reserve` — reserve this pane
`/doey-reserve off` — unreserve
`/doey-reserve list` — list all reservations

## Prompt

Reserve or unreserve this pane. **Do NOT ask for confirmation — just do it.**

### Preamble (all actions)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"
```

Parse the argument: no arg → **reserve**, `off`/`unreserve` → **unreserve**, `list` → **list**.

### Reserve

```bash
# (preamble)
echo "permanent" > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.reserved"
cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: RESERVED
TASK:
EOF
echo "✓ Pane ${MY_PANE} reserved permanently"
```

### Unreserve

```bash
# (preamble)
rm -f "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.reserved"
cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: READY
TASK:
EOF
echo "✓ Pane ${MY_PANE} unreserved"
```

### List

```bash
# (preamble)
FOUND=0
for f in "${RUNTIME_DIR}/status/"*.reserved; do
  [ -f "$f" ] || continue; FOUND=1
  echo "$(basename "$f" .reserved): RESERVED"
done
[ "$FOUND" -eq 0 ] && echo "No active reservations"
```

### Rules
- Always target THIS pane (`$MY_PANE`) — never ask which pane
- Pane safe names: replace `:` and `.` with `_`
- Do NOT ask for confirmation
