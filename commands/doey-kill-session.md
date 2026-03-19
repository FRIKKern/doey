# Skill: doey-kill-session

Kill the entire Doey session — all windows, processes, and runtime files.

## Usage
`/doey-kill-session`

## Prompt

### Step 1: Confirm

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

**Ask:** "Kill session ${SESSION_NAME}? All processes and runtime at ${RUNTIME_DIR} will be removed." Do NOT proceed without yes.

### Step 2: Kill processes, session, and clean up

SIGTERM all pane children across all windows, sleep 2, SIGKILL stragglers. Capture RUNTIME_DIR and SESSION_NAME before killing (tmux env unavailable after).

```bash
tmux kill-session -t "$SESSION_NAME"
rm -rf "$RUNTIME_DIR"
```

### Step 3: Report

Processes killed, session destroyed, runtime removed.
