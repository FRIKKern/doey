# Skill: doey-reserve

Reserve or unreserve a worker pane to prevent the Manager from dispatching tasks to it.

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

2. **Ask the user what they want to do:**
   - **Reserve this pane** — permanently reserve the current pane
   - **Reserve another pane** — pick a worker pane to reserve
   - **Unreserve a pane** — remove reservation from a pane
   - **List reservations** — show all current reservations
   - **Reserve with timer** — reserve for N minutes (e.g., 5m, 30m)

3. **For "Reserve this pane" or "Reserve another pane":**
   ```bash
   # Permanent reservation
   echo "permanent" > "${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.reserved"
   ```

   For timed reservation:
   ```bash
   # Timed reservation (DURATION_SECONDS calculated from user input)
   EXPIRY=$(( $(date +%s) + DURATION_SECONDS ))
   echo "$EXPIRY" > "${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.reserved"
   ```

4. **For "Unreserve a pane":**
   ```bash
   rm -f "${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.reserved"
   ```

5. **For "List reservations":**
   ```bash
   for f in "${RUNTIME_DIR}/status/"*.reserved; do
     [ -f "$f" ] || continue
     PANE_SAFE=$(basename "$f" .reserved)
     EXPIRY=$(head -1 "$f")
     if [ "$EXPIRY" = "permanent" ]; then
       echo "${PANE_SAFE}: PERMANENT"
     else
       NOW=$(date +%s)
       REMAINING=$(( EXPIRY - NOW ))
       if [ "$REMAINING" -gt 0 ]; then
         echo "${PANE_SAFE}: ${REMAINING}s remaining"
       else
         echo "${PANE_SAFE}: EXPIRED (cleaning up)"
         rm -f "$f"
       fi
     fi
   done
   ```

6. **Update the pane's status file** to reflect reservation:
   ```bash
   cat > "${RUNTIME_DIR}/status/${TARGET_PANE_SAFE}.status" << EOF
PANE: ${TARGET_PANE}
UPDATED: $(date -Iseconds)
STATUS: RESERVED
TASK:
EOF
   ```

7. **Confirm** the action to the user with a summary of current reservations.

### Rules
- The Manager MUST respect reservations — never dispatch to a RESERVED pane
- Permanent reservations persist until explicitly unreserved
- Timed reservations auto-expire (cleaned up by statusbar script and hooks)
- The .reserved file format: first line is either "permanent" or a unix timestamp (expiry)
- Pane safe names replace `:` and `.` with underscores: `doey-project:0.4` becomes `doey-project_0_4`
- When listing panes for user selection, show pane index, title, and current status
