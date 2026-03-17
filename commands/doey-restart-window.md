# Skill: doey-restart-window

Restart all workers in a specific team window. Does not restart the Window Manager (W.0) or the Watchdog (in Dashboard). The CLI handles process killing, relaunching, and boot verification.

## Usage
`/doey-restart-window [window_index]` — restart a specific team window (default: current window)

## Prompt
You are restarting workers in a team window.

### Step 1: Determine target window

```bash
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-1}"
TARGET_WIN="${1:-$WINDOW_INDEX}"
echo "Target window: ${TARGET_WIN}"
```

If no argument provided and DOEY_WINDOW_INDEX is not set, ask the user which window to restart.

### Step 2: Run CLI

```bash
doey restart-window "$TARGET_WIN"
```

The CLI handles:
- Reading team env for worker panes
- Skipping already-idle workers
- Killing Claude processes (SIGTERM, then SIGKILL after 5 attempts)
- Clearing terminals and relaunching Claude instances
- Verifying boot (up to 10 attempts, 5s apart)
- Printing a status table

### Step 3: Report

Present the CLI output. If any workers failed to restart, suggest manual intervention or retry.

### Rules
- **Never restart the Window Manager** (pane W.0) — only workers
- **Watchdog is in Dashboard** (pane 0.2-0.4) — not restarted by this command
- The CLI handles all the complexity — just pass the window index
- Pane indices come from team_W.env — never hardcode
