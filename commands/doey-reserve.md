# Skill: doey-reserve

Reserve or unreserve a worker pane to prevent Manager dispatch.

## Usage
`/doey-reserve`

## Prompt

You are managing pane reservations for the Doey team.

### Steps

1. **Discover runtime and identity:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   source "${RUNTIME_DIR}/session.env"
   MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
   MY_PANE_SAFE=${MY_PANE//[:.]/_}
   ```

2. **Ask the user:** Reserve this pane, reserve another pane, unreserve a pane, list reservations, or reserve with timer.

3. **Reserve (permanent or timed):**
   ```bash
   # Permanent
   echo "permanent" > "${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.reserved"
   # Timed (DURATION_SECONDS from user input)
   echo "$(( $(date +%s) + DURATION_SECONDS ))" > "${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.reserved"
   ```

4. **Unreserve:** `rm -f "${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.reserved"`

5. **List reservations:**
   ```bash
   for f in "${RUNTIME_DIR}/status/"*.reserved; do
     [ -f "$f" ] || continue
     PANE_SAFE=$(basename "$f" .reserved); EXPIRY=$(head -1 "$f")
     if [ "$EXPIRY" = "permanent" ]; then echo "${PANE_SAFE}: PERMANENT"
     else NOW=$(date +%s); R=$(( EXPIRY - NOW ))
       [ "$R" -gt 0 ] && echo "${PANE_SAFE}: ${R}s remaining" || { echo "${PANE_SAFE}: EXPIRED"; rm -f "$f"; }
     fi
   done
   ```

6. **Update status file** to reflect RESERVED status:
   ```bash
   cat > "${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.status" << EOF
PANE: ${TARGET_PANE}
UPDATED: $(date -Iseconds)
STATUS: RESERVED
TASK:
EOF
   ```

7. **Confirm** with a summary of current reservations.

### Rules
- Manager MUST respect reservations — never dispatch to RESERVED panes
- Timed reservations auto-expire; `.reserved` file: first line is "permanent" or unix timestamp
- Pane safe names: replace `:` and `.` with `_`
- When listing panes for selection, show index, title, and status
