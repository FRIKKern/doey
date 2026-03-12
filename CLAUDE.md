# CLAUDE.md

## Project Overview

Doey is a CLI tool that creates a tmux-based multi-agent Claude Code team. It launches a Manager, Watchdog, and N Workers (default 10) in a single tmux session, enabling parallel task execution. Workers can be reserved by humans via `/doey-reserve` (permanent until explicitly unreserved). CLI entry point: `doey`.

## Architecture

- **Manager (pane 0.0, Opus):** Orchestrator — plans and delegates, never writes code. Skips reserved workers.
- **Watchdog (pane 0.{cols}, Haiku):** Monitors workers, delivers messages, sends notifications.
- **Workers (remaining panes, Opus):** Execute tasks.

Runtime files: `/tmp/doey/<project>/`. See `docs/context-reference.md`.

## Key Directories

- `agents/` -- Agent definitions, installed to `~/.claude/agents/`
- `commands/` -- Slash commands (doey-*.md), installed to `~/.claude/commands/`
- `.claude/hooks/` -- Modular hooks: common.sh, on-prompt-submit.sh, on-stop.sh, on-pre-tool-use.sh, on-pre-compact.sh
- `.claude/settings.local.json` -- Hook registration (4 events)
- `shell/` -- Launcher (doey.sh), installed to `~/.local/bin/doey`
- `docs/` -- Platform guides and context-reference.md

## Development Conventions

- Agent definitions: YAML frontmatter (name, model, color, memory, description)
- Commands: `# Skill: name` + `## Usage` + `## Prompt`
- Hook exit codes: 0=allow, 1=block+error, 2=block+feedback
- Shell scripts: `set -euo pipefail`
- Session names: `doey-<project-name>`
- Runtime data: `/tmp/doey/<project>/`

## Testing Changes

| Changed | Action |
|---------|--------|
| Agent definitions | Restart Manager or Watchdog |
| Hooks | Restart ALL workers (loaded at startup) |
| Commands/skills | No restart (loaded on-demand) |
| Launcher | `doey stop && doey` or new `doey init` |

## Important Files

- `shell/doey.sh` -- Launcher: init/start/stop/restart/status/doctor/update
- `.claude/hooks/common.sh` -- Shared utilities: pane identity, runtime dir
- `.claude/hooks/on-prompt-submit.sh` -- Sets BUSY status
- `.claude/hooks/on-stop.sh` -- Sets FINISHED/RESERVED, research enforcement, watchdog keep-alive
- `.claude/hooks/on-pre-tool-use.sh` -- Tool usage safety guards
- `.claude/hooks/on-pre-compact.sh` -- Context preservation before compaction
- `commands/doey-reserve.md` -- Pane reservation command
- `.claude/hooks/status-hook.sh` -- Legacy hook (reference only)
- `install.sh` -- Installs agents, commands, shell script

## Context Reference

See `docs/context-reference.md` for all context layers.
