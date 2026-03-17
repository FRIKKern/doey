# Skill: doey-reload

Hot-reload the running session: update files on disk, restart Manager and Watchdog with latest agent definitions. Workers keep running (hooks + commands update live). Use `--workers` to also restart workers.

## Usage
`/doey-reload [--workers]` — reload session (default: Manager + Watchdog only)

## Prompt
You are performing a hot reload of the running Doey session.

### What gets reloaded

| Component | Restart needed? | Why |
|-----------|----------------|-----|
| Hooks (.claude/hooks/) | No | Re-read from disk on every invocation |
| Slash commands | No | Loaded on-demand |
| Agent definitions | Yes | Baked into system prompt at startup |
| Worker system prompts | Yes (if --workers) | Read once at claude startup |

### Step 1: Run CLI

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
cd "$PROJECT_DIR"
doey reload $ARGUMENTS
```

Pass through any arguments the user provided (--workers, etc).

The CLI handles:
1. Running install.sh (copy agents, commands, shell scripts)
2. Copying hooks to project directory
3. Regenerating worker system prompts
4. Killing + relaunching Manager and Watchdog with new agent definitions
5. Re-briefing Watchdog with monitoring instructions
6. Optionally restarting workers (if --workers)

### Step 2: Report

After `doey reload` completes, report what happened:

```
Reload complete:
  - Files installed (agents, commands, shell scripts)
  - Hooks copied to project directory
  - Worker system prompts regenerated
  - Manager relaunched with latest agent definition
  - Watchdog relaunched with latest agent definition
  [- Workers restarted (if --workers was used)]

Note: This Manager instance was relaunched — your context was reset.
Hooks and slash commands take effect immediately without restart.
```

### Important Notes
- **This command will kill YOUR Claude instance** (the Manager) as part of the reload. You won't see the final output — the new Manager instance will start fresh.
- **The Watchdog will also restart**, so there will be a brief monitoring gap (~15s).
- **Workers keep running** unless --workers is specified. Their hooks update live.
- After reload, the NEW Manager instance starts with fresh context.

### Rules
- Always `cd "$PROJECT_DIR"` before running `doey reload`
- Pass through any arguments to the CLI
- Warn the user that Manager context will be reset
