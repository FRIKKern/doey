# Skill: doey-reserve

Reserve/unreserve the current pane to prevent Window Manager dispatch.

## Usage
`/doey-reserve` — reserve this pane
`/doey-reserve off` — unreserve
`/doey-reserve list` — list all reservations

## Prompt

**Do NOT ask for confirmation — just do it.** Parse: no arg → reserve, `off`/`unreserve` → unreserve, `list` → list.

### Preamble (all actions)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"
```

### Reserve

```bash
echo "permanent" > "${RUNTIME_DIR}/status/${SAFE}.reserved"
```
Then write status (see below) with `STATUS: RESERVED` and print "Pane ${MY_PANE} reserved".

### Unreserve

```bash
rm -f "${RUNTIME_DIR}/status/${SAFE}.reserved"
```
Then write status (see below) with `STATUS: READY` and print "Pane ${MY_PANE} unreserved".

### Status file (shared by reserve/unreserve)

```bash
cat > "${RUNTIME_DIR}/status/${SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: ${NEW_STATUS}
TASK:
EOF
```

### List

```bash
FOUND=0
for f in "${RUNTIME_DIR}/status/"*.reserved; do
  [ -f "$f" ] || continue; FOUND=1
  echo "$(basename "$f" .reserved): RESERVED"
done
[ "$FOUND" -eq 0 ] && echo "No active reservations"
```

### Rules
- Always target THIS pane (`$MY_PANE`) — never ask which pane
- Do NOT ask for confirmation
