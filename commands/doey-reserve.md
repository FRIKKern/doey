# Skill: doey-reserve

Reserve the current pane to prevent Window Manager dispatch. Supports reserve, unreserve, and list.

## Usage
`/doey-reserve` — reserve this pane permanently
`/doey-reserve off` — unreserve this pane
`/doey-reserve list` — list all reservations

## Prompt

You are reserving or unreserving the pane where this command was typed. **Do NOT ask for confirmation — just do it immediately.**

### Step 1: Detect current pane

```bash
WIN_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{window_index}.#{pane_index}')
echo "Current pane: $WIN_PANE"
```

### Step 2: Determine action and run CLI

Read the user's argument after `/doey-reserve`:
- No argument or empty → **reserve**
- `off` or `unreserve` → **unreserve**
- `list` → **list**

**Reserve:**
```bash
doey reserve $WIN_PANE
```

**Unreserve:**
```bash
doey reserve $WIN_PANE off
```

**List:**
```bash
doey reserve list
```

Also update the status file to reflect the reservation:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"

cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: RESERVED
TASK:
EOF
```
(For unreserve, set STATUS to READY instead of RESERVED.)

### Rules
- Always target THIS pane — never ask which pane
- Do NOT ask for confirmation — just do it immediately
- Reservations are permanent until explicitly unreserved
