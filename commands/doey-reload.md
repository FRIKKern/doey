# Skill: doey-reload

Hot-reload: installs latest files, restarts Manager + Watchdog. Workers keep running (hooks + commands update live). `--workers` also restarts workers.

## Usage
`/doey-reload [--workers]`

## Prompt

### Step 1: Run reload

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
cd "$PROJECT_DIR"
doey reload $ARGUMENTS
```

**Warning:** This kills YOUR Claude instance (the Manager). The new instance starts with fresh context — user should re-brief if needed. Watchdog also restarts (~15s monitoring gap). Workers keep running unless `--workers`.

### Step 2: Report

Report what `doey reload` output. Hooks and slash commands take effect immediately without restart; agent definitions and worker system prompts require restart.
