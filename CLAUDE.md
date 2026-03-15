# CLAUDE.md

## Project Overview

Doey is a CLI tool that creates a tmux-based multi-agent Claude Code team. It launches a Manager, Watchdog, and N Workers in a dynamic grid (default: 2 columns = 4 workers, auto-expands when all busy) in a single tmux session, enabling parallel task execution. Workers can be reserved by humans via `/doey-reserve` (permanent until explicitly unreserved). CLI entry point: `doey`.

## Architecture

- **Manager (pane 0.0, Opus):** Orchestrator — plans and delegates, never writes code. Skips reserved workers.
- **Watchdog (pane 0.1 dynamic, 0.{cols} static; Haiku):** Monitors workers, delivers inbox messages.
- **Test Driver (E2E, Opus):** Automated test runner that drives Doey sessions through journeys.
- **Workers (remaining panes, Opus):** Execute tasks.

Runtime files: `/tmp/doey/<project>/`. See `docs/context-reference.md`.

**Tool restrictions** (enforced by `on-pre-tool-use.sh`):
- **Manager:** No restrictions (full access)
- **Watchdog:** Blocked from Edit, Write, Agent, NotebookEdit tools; send-keys limited to /doey-inbox, /login, /compact, bare Enter, copy-mode
- **Workers:** Blocked from git push/commit, gh pr create/merge, ALL tmux send-keys, tmux kill-session/kill-server, rm -rf ~/\$HOME, shutdown/reboot

## Key Directories

- `agents/` -- Agent definitions, installed to `~/.claude/agents/`
- `commands/` -- Slash commands (doey-*.md), installed to `~/.claude/commands/`
- `.claude/hooks/` -- Modular hooks: common.sh, on-session-start.sh, on-prompt-submit.sh, on-pre-tool-use.sh, on-pre-compact.sh, post-tool-lint.sh, stop-status.sh, stop-results.sh, stop-notify.sh, watchdog-scan.sh
- `.claude/settings.local.json` -- Permission rules for Bash tool patterns (allow-list for common CLI commands)
- `shell/` -- Launcher and utilities (doey.sh, context-audit.sh, pane-border-status.sh, tmux-statusbar.sh); doey.sh, pane-border-status.sh, and tmux-statusbar.sh are installed to `~/.local/bin/` (context-audit.sh is not installed)
- `docs/` -- Platform guides and context-reference.md

Dynamic grid mode: `doey` (default) launches dynamic grid; `doey add`/`doey remove` manage columns at runtime.

## Development Conventions

- Agent definitions: YAML frontmatter (name, model, color, memory, description)
- Commands: `# Skill: name` + `## Usage` + `## Prompt`
- Hook exit codes: 0=allow, 1=block+error, 2=block+feedback
- Shell scripts: `set -euo pipefail`
- Shell scripts must be bash 3.2 compatible (macOS `/bin/bash`). Forbidden: `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `[[ =~` capture groups. Use `date +%s`, `while read` loops, eval-based key-value stores instead.
- Session names: `doey-<project-name>`
- Runtime data: `/tmp/doey/<project>/`

## Testing Changes

| Changed | Action |
|---------|--------|
| Agent definitions | Restart Manager or Watchdog |
| Hooks | Restart ALL workers (loaded at startup) |
| Commands/skills | No restart (loaded on-demand) |
| Launcher | `doey stop && doey` or new `doey init` |
| Shell scripts | Run `tests/test-bash-compat.sh` |

## Important Files

- `shell/doey.sh` -- Launcher: smart-launch, init, stop, update/reinstall, doctor, list, purge, test, version, dynamic/d, add, remove, uninstall
- `.claude/hooks/common.sh` -- Shared utilities: `init_hook()`, `parse_field()`, role checks (`is_manager()`, `is_worker()`, `is_watchdog()`, `is_reserved()`), `send_notification()`, `NL` (newline var), `is_numeric()`, `atomic_write()`
- `.claude/hooks/on-session-start.sh` -- SessionStart: initial setup
- `.claude/hooks/on-prompt-submit.sh` -- Sets BUSY status, sets READY on /compact, expands collapsed columns
- `.claude/hooks/on-pre-tool-use.sh` -- Tool usage safety guards
- `.claude/hooks/on-pre-compact.sh` -- Context preservation before compaction
- `.claude/hooks/post-tool-lint.sh` -- PostToolUse: linting after tool use
- `.claude/hooks/stop-status.sh` -- Stop: sets FINISHED/RESERVED for workers, READY for Manager/Watchdog, research enforcement
- `.claude/hooks/stop-results.sh` -- Stop: collects and writes results
- `.claude/hooks/stop-notify.sh` -- Stop: Manager notifications
- `commands/doey-reserve.md` -- Pane reservation command
- `shell/context-audit.sh` -- Context audit tool (detects contradictory patterns, identity confusion, stale references)
- `install.sh` -- Installs agents, commands, shell script

## Context Reference

See `docs/context-reference.md` for all context layers.
