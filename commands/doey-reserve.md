# Skill: doey-reserve

Reserve the current pane to prevent Window Manager dispatch. Supports permanent reserve, unreserve, and list.

## Usage
`/doey-reserve` — permanent reserve on this pane
`/doey-reserve off` — unreserve this pane
`/doey-reserve list` — list all reservations

## Prompt

You are reserving or unreserving the pane where this command was typed. **Do NOT ask for confirmation — just do it immediately.**

### Project Context (read once per Bash call)

Every Bash call must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

### Step 1: Determine action

Read the user's argument after `/doey-reserve`:
- No argument or empty → **reserve** (go to Step 2a)
- `off` or `unreserve` → **unreserve** (go to Step 2b)
- `list` → **list** (go to Step 2c)

Then run the appropriate step below. **Do not use a shell variable for the argument** — determine the action yourself from the user's message and jump to the correct step.

### Step 2a: Reserve permanently (when ACTION=permanent)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"

echo "permanent" > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.reserved"

cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: RESERVED
TASK:
EOF

echo "✓ Pane ${MY_PANE} reserved permanently"
```

### Step 2b: Unreserve (when ACTION=unreserve)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')

rm -f "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.reserved"

cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: READY
TASK:
EOF

echo "✓ Pane ${MY_PANE} unreserved"
```

### Step 2c: List all reservations (when ACTION=list)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

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

1. **Always target THIS pane** (`$MY_PANE` / `$MY_PANE_SAFE`) — never ask which pane
2. **Window Manager MUST respect reservations** — never dispatch to RESERVED panes
3. **Reservations are permanent** — `.reserved` file always contains `permanent`
4. **Pane safe names:** replace `:` and `.` with `_`
5. **Do NOT ask for confirmation** — just do it immediately
6. **Always `mkdir -p`** the status directory before writing
