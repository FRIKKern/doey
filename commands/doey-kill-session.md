# Skill: doey-kill-session

Kill the entire Doey session — all windows, all processes, all runtime files.

## Usage
`/doey-kill-session`

## Prompt
You are tearing down an entire Doey tmux session.

### Step 1: Confirm with user

Read project context:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
echo "Session: ${SESSION_NAME}"
echo "Runtime: ${RUNTIME_DIR}"
```

**Before doing anything**, ask the user:

> This will kill the entire Doey session `${SESSION_NAME}` — all windows, all processes, and remove all runtime files. Proceed? (yes/no)

**Do NOT proceed without explicit confirmation.**

### Step 2: Run CLI

```bash
echo "yes" | doey kill-session
```

The CLI handles: process SIGTERM/SIGKILL, session destruction, runtime cleanup.

### Step 3: Report

Report that the session was killed. Note: to restart, use `doey` from the project directory.

### Rules
- **ALWAYS confirm with the user** before running — this is destructive and irreversible
- The CLI handles all process killing and cleanup
- This command cannot be undone — the session must be relaunched with `doey`
