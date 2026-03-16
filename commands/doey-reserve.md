# Skill: doey-reserve

Reserve the current pane to prevent Window Manager dispatch. Supports permanent reserve, unreserve, and list.

## Usage
`/doey-reserve` — permanent reserve on this pane
`/doey-reserve off` — unreserve this pane
`/doey-reserve list` — list all reservations

## Prompt

You are reserving or unreserving the pane where this command was typed. **Do NOT ask for confirmation — just do it immediately.**

### Step 1: Read context and determine action

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"
```

Read the user's argument after `/doey-reserve`:
- No argument or empty → **reserve** (Step 2a)
- `off` or `unreserve` → **unreserve** (Step 2b)
- `list` → **list** (Step 2c)

Determine the action yourself from the user's message and jump to the correct step.

### Step 2a: Reserve permanently

```bash
# (vars from step 1)
echo "permanent" > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.reserved"

cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: RESERVED
TASK:
EOF

echo "✓ Pane ${MY_PANE} reserved permanently"
```

### Step 2b: Unreserve

```bash
# (vars from step 1)
rm -f "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.reserved"

cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: READY
TASK:
EOF

echo "✓ Pane ${MY_PANE} unreserved"
```

### Step 2c: List all reservations

```bash
# (vars from step 1)
FOUND=0
for f in "${RUNTIME_DIR}/status/"*.reserved; do
  [ -f "$f" ] || continue
  FOUND=1
  PANE_SAFE=$(basename "$f" .reserved)
  echo "${PANE_SAFE}: RESERVED"
done
[ "$FOUND" -eq 0 ] && echo "No active reservations"
```

### Rules
- Always target THIS pane (`$MY_PANE`) — never ask which pane. Pane safe names: replace `:` and `.` with `_`.
- Reservations are permanent (`.reserved` contains `permanent`). Do NOT ask for confirmation.
- Always `mkdir -p` the status directory before writing.
