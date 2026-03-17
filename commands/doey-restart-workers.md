# Skill: doey-restart-workers

## Usage
`/doey-restart-workers` (DEPRECATED)

## Prompt
This command is deprecated.

### Step 1: Run CLI

```bash
doey restart-workers
```

The CLI prints a deprecation notice and exits with error.

### Step 2: Guide the user

Tell them to use `/doey-restart-window <W>` instead, where W is the team window index (e.g., 1, 2, 3).

To restart the Watchdog separately, kill its process in the Dashboard pane and relaunch with `claude --dangerously-skip-permissions --model haiku --agent doey-watchdog`.
