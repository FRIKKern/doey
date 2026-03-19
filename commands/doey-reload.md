# Skill: doey-reload

Hot-reload: update files, restart Manager + Watchdog. Workers keep running unless `--workers`.

## Usage
`/doey-reload [--workers]`

## Prompt

Run `doey reload` to hot-reload the session.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
cd "$PROJECT_DIR"
doey reload $ARGUMENTS
```

Installs latest files, regenerates prompts, relaunches Manager + Watchdog, optionally restarts workers.

**Warning:** Kills YOUR Claude instance — Manager starts with fresh context. ~15s watchdog gap. Hooks/commands update live without restart.

### Rules
- Always `cd "$PROJECT_DIR"` before running
- Pass through arguments (--workers, --all)
- Warn user that Manager context resets
