# CLAUDE.md

## Project Overview

Doey is a CLI tool that creates a tmux-based multi-agent Claude Code team. It launches a Window Manager, Watchdog, and N Workers in a dynamic grid (default: 3 columns = 6 workers, auto-expands when all busy) in a single tmux session, enabling parallel task execution. Workers can be reserved by humans via `/doey-reserve` (permanent until explicitly unreserved). CLI entry point: `doey`.

## Architecture

**Window 0 — Dashboard (always present):**
- **Info Panel (pane 0.0, shell script):** Live dashboard showing team status, worker counts, recent events. User lands here on attach.
- **Watchdog slots (panes 0.1-0.3, Haiku):** One Watchdog per team window. Monitors workers, catches crashes.
- **Session Manager (pane 0.4, Opus):** Top-level orchestrator that routes tasks between team windows. Never dispatches to workers directly. Present when multiple teams exist.

**Window 1+ — Team windows:**
- **Window Manager (pane W.0, Opus):** Orchestrator — plans and delegates, never writes code. Skips reserved workers.
- **Workers (pane W.1+, Opus):** Execute tasks.
- Additional teams added via `doey add-team` (window 2, 3, etc.).

**Other:**
- **Test Driver (E2E, Opus):** Automated test runner. Runs outside the tmux grid (separate Claude process via `doey test`).

Runtime files: `/tmp/doey/<project>/`. See `docs/context-reference.md`.

**Tool restrictions** (enforced by `on-pre-tool-use.sh`):
- **Window Manager:** No restrictions (full access)
- **Watchdog:** Blocked from Edit, Write, Agent, NotebookEdit tools; send-keys limited to /login, /compact, bare Enter, copy-mode; also blocked from git push/commit, gh pr create/merge, destructive rm, shutdown/reboot, tmux kill-session/server
- **Workers:** Blocked from git push/commit, gh pr create/merge, ALL tmux send-keys, tmux kill-session/kill-server, rm -rf ~/\$HOME, shutdown/reboot

## Key Directories

- `agents/` -- Agent definitions, installed to `~/.claude/agents/`
- `commands/` -- Slash commands, installed to `~/.claude/commands/`
- `.claude/hooks/` -- Modular hooks: see Important Files
- `.claude/settings.local.json` -- Bash tool permission rules
- `shell/` -- Launcher and utilities, installed to `~/.local/bin/`
- `docs/` -- Platform guides and context-reference.md

Dynamic grid mode: `doey` (default) launches dynamic grid; `doey add`/`doey remove` manage columns at runtime.

## Development Conventions

- Agent definitions: YAML frontmatter (name, model, color, memory, description)
- Commands: `# Skill: name` + `## Usage` + `## Prompt`
- Hook exit codes: 0=allow, 1=block+error, 2=block+feedback
- Shell scripts: `set -euo pipefail`
- Shell scripts must be bash 3.2 compatible (macOS `/bin/bash`). Forbidden: `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `[[ =~` capture groups.
- Session names: `doey-<project-name>`
- Runtime data: `/tmp/doey/<project>/`

## Testing Changes

| Changed | Action |
|---------|--------|
| Agent definitions | Restart Manager or Watchdog |
| Hooks | Restart ALL workers (loaded at startup) |
| Commands/skills | No restart (loaded on-demand) |
| Launcher | `doey stop && doey` or `doey reload` |
| Shell scripts | Run `tests/test-bash-compat.sh` |
| Live reload | `doey reload` or `/doey-reload` (Manager+Watchdog), `doey reload --workers` (all) |

## Important Files

- `shell/doey.sh` -- Launcher: smart-launch, init, stop, update/reinstall, reload, doctor, list, purge, test, version, dynamic/d, add, remove, uninstall, add-team/add-window, kill-team/kill-window, list-teams/list-windows
- `shell/info-panel.sh` -- Dashboard for window 0 (team status, worker counts, recent events)
- `.claude/hooks/common.sh` -- Shared utilities: `init_hook()`, `parse_field()`, `load_team_env()`, role checks (`is_manager()`, `is_session_manager()`, `is_worker()`, `is_watchdog()`, `is_reserved()`), `send_notification()`, `NL` (newline var), `is_numeric()`
- `.claude/hooks/on-prompt-submit.sh` -- Sets BUSY status, sets READY on /compact, expands collapsed columns
- `.claude/hooks/on-pre-tool-use.sh` -- Tool usage safety guards
- `.claude/hooks/on-pre-compact.sh` -- Context preservation before compaction
- `.claude/hooks/stop-status.sh` -- Stop: sets FINISHED/RESERVED for workers, READY for Window Manager/Watchdog, research enforcement
- `.claude/hooks/on-session-start.sh` -- SessionStart: sets DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX per-pane
- `.claude/hooks/post-tool-lint.sh` -- PostToolUse: bash 3.2 compatibility lint on .sh files
- `.claude/hooks/stop-results.sh` -- Stop: writes result JSON and completion events
- `.claude/hooks/stop-notify.sh` -- Stop: Session Manager notifications
- `.claude/hooks/watchdog-scan.sh` -- Watchdog: pane state detection, heartbeat
- `commands/doey-reserve.md` -- Pane reservation command
- `shell/context-audit.sh` -- Context audit tool (detects contradictory patterns, identity confusion, stale references)

## Context Reference

See `docs/context-reference.md` for all context layers.
