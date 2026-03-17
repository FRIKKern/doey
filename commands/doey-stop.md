# Skill: doey-stop

Stop a specific worker by pane number. Kills the Claude process, updates status, and leaves the pane shell intact for restart.

## Usage
`/doey-stop 4` — stop worker in pane W.4
`/doey-stop` — lists workers, then ask which to stop

## Prompt

You are stopping a specific Claude Code worker instance.

### Step 1: Determine target

If user provided a pane number, use it. If not, run `doey status` to show current workers and ask the user which one to stop.

Determine the current window index:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-1}"
```

Validate: pane 0 is the Window Manager and cannot be stopped.

### Step 2: Run CLI

```bash
doey stop-worker "${WINDOW_INDEX}.${PANE_NUMBER}"
```

### Step 3: Report

Present the result. If successful, note the worker can be relaunched with `/doey-dispatch` or `/doey-restart-window`.

### Rules
- Never stop Window Manager (pane 0) or Watchdog
- The CLI handles PID lookup, kill, status update
- Pane shell stays alive for restart
