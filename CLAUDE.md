# CLAUDE.md

## Project Overview

Doey is a CLI tool that creates a tmux-based multi-agent Claude Code team. It launches a Manager, Watchdog, and N Workers (default 10) in a single tmux session, enabling parallel task execution across multiple Claude Code instances. The CLI entry point is `doey`.

## Architecture

- **Manager (pane 0.0):** Orchestrator — plans and delegates, never writes code. Uses `--agent doey-manager` (Opus).
- **Watchdog (pane 0.{cols}):** Monitors workers, auto-accepts prompts. Uses `--agent doey-watchdog` (Haiku).
- **Workers (remaining panes):** Standard Claude Code instances (Opus) that execute tasks.

Communication is via tmux commands (`send-keys`, `capture-pane`) and runtime files under `/tmp/doey/<project>/`. See `docs/context-reference.md` for details.

## Key Directories

- `agents/` -- Agent definitions (doey-manager.md, doey-watchdog.md), installed to `~/.claude/agents/`
- `commands/` -- Slash command skills (doey-*.md), installed to `~/.claude/commands/`
- `.claude/hooks/` -- Modular hook scripts: common.sh (shared utilities), on-prompt-submit.sh, on-stop.sh, on-pre-tool-use.sh, on-pre-compact.sh
- `.claude/settings.local.json` -- Hook registration (maps 4 events to modular hook scripts)
- `shell/` -- Launcher script (doey.sh), installed to `~/.local/bin/doey`
- `docs/` -- Platform guides (linux-server.md, windows-wsl2.md) and context-reference.md

## Development Conventions

- Agent definitions use YAML frontmatter: name, model, color, memory, description
- Commands follow the format: `# Skill: name` + `## Usage` + `## Prompt`
- Hook exit codes: 0 = allow, 1 = block with error, 2 = block with feedback message
- Shell scripts use `set -euo pipefail`
- The installer (`install.sh`) copies agents/ to `~/.claude/agents/` and commands/ to `~/.claude/commands/`
- Session names follow the pattern `doey-<project-name>`
- Runtime data lives under `/tmp/doey/<project>/`

## Testing Changes

- **Agent definitions:** restart the Manager or Watchdog to pick up changes
- **Hook changes:** restart ALL workers (hooks are loaded at startup per-instance)
- **Command/skill changes:** no restart needed (loaded on-demand)
- **Launcher changes:** need `doey stop && doey` or new `doey init`

## Important Files

- `shell/doey.sh` -- Main launcher: init, start, stop, restart, status, doctor, update, grid setup
- `.claude/hooks/common.sh` -- Shared hook utilities: pane identity resolution, runtime dir detection
- `.claude/hooks/on-prompt-submit.sh` -- UserPromptSubmit handler: sets WORKING status
- `.claude/hooks/on-stop.sh` -- Stop handler: sets IDLE status, research report enforcement, watchdog keep-alive, Manager notifications
- `.claude/hooks/on-pre-tool-use.sh` -- PreToolUse handler: safety guards for tool usage
- `.claude/hooks/on-pre-compact.sh` -- PreCompact handler: context preservation before compaction
- `.claude/hooks/status-hook.sh` -- Legacy monolithic hook (kept as reference, no longer registered)
- `install.sh` -- Copies agents, commands, shell script to user directories; registers repo path

## Context Reference

For deep documentation of all context layers (settings, hooks, memory, env vars, CLI flags, tmux integration, runtime state), see `docs/context-reference.md`.
