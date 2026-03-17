# Skill: doey-status

Show worker status across all team windows, or set your own status.

## Usage
`/doey-status [W]` — show status for window W (default: all)
`/doey-status set <STATUS> [task description]` — set your own status

## Prompt
You are checking or setting worker status in the Doey team.

### Step 1: Determine action
- If the user said `/doey-status set ...` → go to "Setting status"
- Otherwise → go to "Viewing status"

### Viewing status

Run the CLI command:
```bash
doey status $WINDOW_ARG
```
Where `$WINDOW_ARG` is the window number if specified, or omitted for all windows.

Present the output. Highlight any issues:
- Workers stuck in BUSY for a long time
- CRASHED or ERROR states → suggest `/doey-monitor` for deep inspect
- Stale watchdog heartbeats → suggest checking the Watchdog
- All FINISHED → suggest the Manager can collect results

### Setting status

Detect current pane identity and write status file:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
MY_PANE=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')
MY_PANE_SAFE=$(echo "$MY_PANE" | tr ':.' '_')
mkdir -p "${RUNTIME_DIR}/status"

cat > "${RUNTIME_DIR}/status/${MY_PANE_SAFE}.status" << EOF
PANE: ${MY_PANE}
UPDATED: $(date '+%Y-%m-%dT%H:%M:%S%z')
STATUS: $STATUS_VALUE
TASK: $TASK_DESCRIPTION
EOF
```

Valid status values: READY, BUSY, FINISHED, RESERVED.

Confirm the status was set.
