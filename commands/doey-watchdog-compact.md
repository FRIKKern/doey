# Skill: doey-watchdog-compact

Send `/compact` to the Watchdog to reduce its context window.

## Usage
`/doey-watchdog-compact [window_index]`

## Prompt
Send `/compact` to the Watchdog and verify it resumes monitoring.

### Step 1: Determine target window

```bash
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-1}"
TARGET_WIN="${1:-$WINDOW_INDEX}"
echo "Target team window: ${TARGET_WIN}"
```

### Step 2: Run CLI

```bash
doey watchdog-compact "$TARGET_WIN"
```

The CLI handles: finding the Watchdog pane from team env, exiting copy-mode, sending /compact, waiting 15s, and verifying activity.

### Step 3: Report

Present the CLI result. If the watchdog is not responding, suggest:
- Check the Dashboard pane manually
- Try `/doey-restart-window` if the watchdog is stuck
- Kill and relaunch the watchdog manually
