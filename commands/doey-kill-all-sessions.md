# Skill: doey-kill-all-sessions

Kill all running Doey tmux sessions across all projects — processes, sessions, and runtime files.

## Usage
`/doey-kill-all-sessions`

## Prompt
You are killing all running Doey tmux sessions.

### Step 1: Show running sessions

```bash
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^doey-' || echo "No Doey sessions found"
```

If no sessions found, report and stop.

### Step 2: Confirm with user

**Before doing anything**, ask the user:

> This will kill ALL running Doey sessions listed above, all their processes, and remove all runtime files under `/tmp/doey/`. Proceed? (yes/no)

**Do NOT proceed without explicit confirmation.**

### Step 3: Run CLI

```bash
echo "yes" | doey kill-all
```

The CLI handles: finding all doey-* sessions, SIGTERM/SIGKILL all processes, killing sessions, cleaning /tmp/doey/*/.

### Step 4: Report

Report how many sessions were killed. Note: to restart any project, use `doey` from that project's directory.

### Rules
- **ALWAYS confirm with the user** before running — this is destructive and irreversible
- The CLI handles all process killing and cleanup
- Handle zero sessions gracefully
