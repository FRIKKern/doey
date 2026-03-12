# Skill: doey-reserve

Reserve the current pane to prevent Manager dispatch. Supports permanent, timed, unreserve, and list.

## Usage
`/doey-reserve` — permanent reserve on this pane
`/doey-reserve 10m` — reserve for 10 minutes
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

### Step 1: Discover identity and parse argument

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"

# Parse duration string (Nm, Nh, Ns) to seconds
parse_duration() {
  local input="$1"
  local num="${input%[smhSMH]}"
  local unit="${input##*[0-9]}"
  case "$unit" in
    s|S) echo "$num" ;;
    m|M) echo "$(( num * 60 ))" ;;
    h|H) echo "$(( num * 3600 ))" ;;
    *)   echo "" ;;
  esac
}

ARG="$USER_ARGUMENT"  # text after /doey-reserve

case "$ARG" in
  ""|" ")
    ACTION="permanent"
    ;;
  off|unreserve)
    ACTION="unreserve"
    ;;
  list)
    ACTION="list"
    ;;
  *[0-9][smhSMH])
    DURATION_SECONDS=$(parse_duration "$ARG")
    if [ -z "$DURATION_SECONDS" ] || [ "$DURATION_SECONDS" -le 0 ] 2>/dev/null; then
      echo "Invalid duration: $ARG"
      exit 1
    fi
    ACTION="timed"
    ;;
  *)
    echo "Unknown argument: $ARG — use: off, list, or a duration like 5m/1h/30s"
    exit 1
    ;;
esac

echo "Pane: $MY_PANE | Action: $ACTION"
```

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
UPDATED: $(date -Iseconds)
STATUS: RESERVED
TASK:
EOF

echo "✓ Pane ${MY_PANE} reserved permanently"
```

### Step 2b: Reserve with duration (when ACTION=timed)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"

# DURATION_SECONDS set from Step 1
EXPIRY=$(( $(date +%s) + DURATION_SECONDS ))
echo "$EXPIRY" > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.reserved"

cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date -Iseconds)
STATUS: RESERVED
TASK:
EOF

echo "✓ Pane ${MY_PANE} reserved for ${DURATION_SECONDS}s (expires $(date -r "$EXPIRY" '+%H:%M:%S' 2>/dev/null || date -d "@$EXPIRY" '+%H:%M:%S' 2>/dev/null || echo "epoch $EXPIRY"))"
```

### Step 2c: Unreserve (when ACTION=unreserve)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')

rm -f "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.reserved"

cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date -Iseconds)
STATUS: READY
TASK:
EOF

echo "✓ Pane ${MY_PANE} unreserved"
```

### Step 2d: List all reservations (when ACTION=list)

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

FOUND=0
for f in "${RUNTIME_DIR}/status/"*.reserved; do
  [ -f "$f" ] || continue
  FOUND=1
  PANE_SAFE=$(basename "$f" .reserved)
  EXPIRY=$(head -1 "$f")
  if [ "$EXPIRY" = "permanent" ]; then
    echo "${PANE_SAFE}: PERMANENT"
  else
    NOW=$(date +%s)
    REMAINING=$(( EXPIRY - NOW ))
    if [ "$REMAINING" -gt 0 ]; then
      MINS=$(( REMAINING / 60 ))
      SECS=$(( REMAINING % 60 ))
      echo "${PANE_SAFE}: ${MINS}m${SECS}s remaining"
    else
      echo "${PANE_SAFE}: EXPIRED (removing)"
      rm -f "$f"
    fi
  fi
done

[ "$FOUND" -eq 0 ] && echo "No active reservations"
```

### Rules

1. **Always target THIS pane** (`$MY_PANE` / `$MY_PANE_SAFE`) — never ask which pane
2. **Manager MUST respect reservations** — never dispatch to RESERVED panes
3. **Timed reservations auto-expire** — `.reserved` file first line is `permanent` or unix timestamp
4. **Pane safe names:** replace `:` and `.` with `_`
5. **Do NOT ask for confirmation** — just do it immediately
6. **Always `mkdir -p`** the status directory before writing
