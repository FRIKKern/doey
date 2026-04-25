# Context Reference

Precedence for Claude Code instances (lowest → highest):

| Precedence | Source | Applies To |
|------------|--------|------------|
| Lowest | Agent definitions (`agents/`) | Boss, Subtaskmaster, Taskmaster |
| | Settings (4-file merge) | All |
| | Hooks (`.claude/hooks/`) | All |
| | Skills (`.claude/skills/`) | Subtaskmaster (+ 3 for Workers) |
| | Persistent memory | Boss, Subtaskmaster, Taskmaster |
| | Environment vars (`session.env`) | All |
| | CLI launch flags | Per-instance |
| | tmux layout | All |
| | Runtime state (`/tmp/doey/`) | All |
| Highest | CLAUDE.md | All |


## Agent Definitions

Files in `agents/` → `~/.claude/agents/`. Body = system prompt. Precedence: CLI `--model` > frontmatter > settings.

| Field | Boss | Subtaskmaster | Taskmaster | Tmux UI | Settings Editor | Test Driver | Product Brain | Claude Expert | Platform Expert | Critic | Deployment | Doey Expert | Task Reviewer | Worker |
|-------|------|---------|-------------|---------|-----------------|-------------|---------------|---------------|-----------------|--------|------------|-------------|---------------|--------|
| `model` | `opus` | `opus` | `opus` | `opus` | `opus` | `opus` | `opus` | `opus` | `opus` | `opus` | `sonnet` | `opus` | `sonnet` | `opus` |
| `color` | `#E74C3C` | `green` | `#FF6B35` | `#E5C07B` | `#4A90D9` | `red` | `#FFD700` | `magenta` | `cyan` | `red` | `#2196F3` | `#9C27B0` | `#4CAF50` | `#3498DB` |
| `memory` | `user` | `user` | `user` | `none` | `none` | `none` | `user` | `user` | `user` | `user` | `user` | `user` | `user` | `none` |

Specialist agents (SEO, Visual) loaded only when those teams are spawned.


## Settings

Merge order (scalars: last wins; arrays: additive; objects: deep-merged):

1. `~/.claude/settings.json` — agent teams, model, notifications
2. `~/.claude/settings.local.json` — user overrides
3. `<project>/.claude/settings.json` — project-level
4. `<project>/.claude/settings.local.json` — permissions + hooks (`doey init`)

Hooks must be registered in `settings.local.json` — not auto-discovered.


## Hooks

All in `.claude/hooks/`. Exit codes: 0=allow, 1=block+error, 2=block+feedback. Hooks must use `tmux display-message -t "$TMUX_PANE"` (without `-t`, tmux returns the focused pane).

| File | Event | Purpose |
|------|-------|---------|
| `common.sh` | — | Shared utils: `init_hook()`, `parse_field()`, `_read_team_key()`, role checks |
| `on-session-start.sh` | SessionStart | Sets DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX, DOEY_TEAM_WINDOW, etc. |
| `on-prompt-submit.sh` | UserPromptSubmit | BUSY status; READY on `/compact`; collapsed column restore |
| `on-pre-tool-use.sh` | PreToolUse | Role-based tool blocking |
| `on-pre-compact.sh` | PreCompact | Preserves orchestration state before compaction |
| `post-tool-lint.sh` | PostToolUse | Bash 3.2 compatibility lint |
| `stop-status.sh` | Stop | FINISHED/RESERVED/READY; blocks research without reports |
| `stop-results.sh` | Stop | Result JSON and completion events |
| `stop-notify.sh` | Stop | Stop notifications: Worker→Subtaskmaster→Taskmaster→desktop |
| `on-notification.sh` | Notification | Desktop notification for SM permission requests (30s cooldown) |
| `taskmaster-wait.sh` | — | Taskmaster sleep/wake between cycles (trigger, message, result, crash) |


## Skills

In `.claude/skills/<name>/SKILL.md`, invoked via `/skill-name`, loaded on-demand.

- **Subtaskmaster:** `/doey-dispatch`, `/doey-research`, `/doey-monitor`, `/doey-status`, `/doey-reload`, `/doey-reinstall`, `/doey-repair`, `/doey-reserve`, `/doey-purge`, `/doey-simplify-everything`, `/doey-stop`, `/doey-clear`, `/doey-rd-team`, `/doey-settings`, `/doey-debug`, `/doey-nudge`, `/doey-reset`, `/doey-task`, `/unknown-task`
- **Taskmaster:** `/doey-worktree` (also Subtaskmaster), `/doey-add-window`, `/doey-add-team`, `/doey-kill-window`, `/doey-kill-session`, `/doey-kill-all-sessions`, `/doey-list-windows`, `/doey-create-task`, `/doey-instant-task`, `/doey-planned-task`, `/doey-masterplan`, `/doey-task`
- **Worker:** `/doey-status`, `/doey-reserve`, `/doey-stop`, `/doey-task`


## Persistent Memory

Auto-loaded at startup; lines after 200 truncated.

- Boss: `~/.claude/agent-memory/doey-boss/MEMORY.md`
- Subtaskmaster: `~/.claude/agent-memory/doey-subtaskmaster/MEMORY.md`
- Taskmaster: `~/.claude/agent-memory/doey-taskmaster/MEMORY.md`


## Environment Variables

Bootstrap: `doey.sh` → `tmux set-environment DOEY_RUNTIME` → `session.env`.

**Session-level (`session.env`):** `PROJECT_DIR`, `PROJECT_NAME`, `SESSION_NAME`, `GRID`, `ROWS`/`MAX_WORKERS`/`CURRENT_COLS` (dynamic), `TOTAL_PANES` (static), `WORKER_COUNT`, `WORKER_PANES`, `RUNTIME_DIR`, `PASTE_SETTLE_MS`, `IDLE_COLLAPSE_AFTER`, `IDLE_REMOVE_AFTER`, `TEAM_WINDOWS`, `TASKMASTER_PANE`

**tmux/Claude Code:** `TMUX_PANE`, `CLAUDE_PROJECT_DIR`

**Hooks:** `DOEY_ROLE`, `DOEY_PANE_ID`, `DOEY_PANE_INDEX`, `DOEY_WINDOW_INDEX`, `DOEY_TEAM_WINDOW`, `DOEY_TEAM_DIR`, `DOEY_RUNTIME`, `DOEY_TEAM_ROLE`, `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`

**Per-window (`team_<W>.env`):** `WINDOW_INDEX`, `GRID`, `MANAGER_PANE`, `WORKER_PANES`, `WORKER_COUNT`, `SESSION_NAME`, `TEAM_TYPE` (`managed`/`freelancer`), `TEAM_DEF`. Loaded via `_read_team_key()`, overrides session.env.

**Notification opt-ins (`send_notification`):** `DOEY_NOTIFY_CMD` (path to executable hook script; default `~/.config/doey/notify-cmd`; receives `DOEY_NOTIFY_TITLE`/`SUBTITLE`/`BODY`/`EVENT` + `DOEY_TASK_ID`, runs in background), `DOEY_NOTIFY_REPLACE=1` (skip built-in desktop/Discord when custom hook ran), `DOEY_NO_FOCUS_SUPPRESS=1` (always notify even when user is focused on the source pane).


## CLI Launch Flags

| Instance | Command |
|----------|---------|
| Boss | `claude --dangerously-skip-permissions --agent doey-boss` |
| Taskmaster | `claude --dangerously-skip-permissions --agent doey-taskmaster` |
| Subtaskmaster | `claude --dangerously-skip-permissions --model opus --name "T<N> Subtaskmaster" --agent doey-subtaskmaster` |
| Workers | `claude --dangerously-skip-permissions --model opus --name "T<N> W<P>" --append-system-prompt-file <prompt>.md` |

Workers use `--append-system-prompt-file` (not `--agent`) for per-worker identity. Precedence: CLI > frontmatter > settings.


## Shell Scripts

All in `shell/` → `~/.local/bin/`.

| File | Purpose |
|------|---------|
| `doey.sh` | CLI entry — session lifecycle, grid, subcommands |
| `info-panel.sh` | Live dashboard (0.0) |
| `settings-panel.sh` | Settings TUI |
| `doey-statusline.sh` | Claude Code statusline |
| `doey-config-default.sh` | Default config template |
| `doey-constants.sh` | Generated constants from Go (DO NOT EDIT) |
| `doey-go-check.sh` | Go TUI check |
| `doey-go-helpers.sh` | Shared Go build functions |
| `doey-ipc-helpers.sh` | IPC helpers for Taskmaster messaging |
| `doey-plan-helpers.sh` | Plan CRUD helpers |
| `doey-remote-provision.sh` | Remote server provisioning |
| `doey-render-task.sh` | Task file terminal renderer |
| `doey-roles.sh` | Centralized role definitions |
| `doey-send.sh` | Send-keys helper with delivery verification |
| `doey-task-helpers.sh` | Persistent task management library |
| `doey-tunnel.sh` | Tunnel lifecycle for remote sessions |
| `expand-templates.sh` | Template expansion for `{{DOEY_ROLE_*}}` placeholders |
| `pane-border-status.sh` | Pane border formatting |
| `tmux-statusbar.sh` | Status bar content |
| `tmux-theme.sh` | Color theme |
| `tmux-settings-btn.sh` | Settings button |
| `tmux-window-workers.sh` | Per-window worker dot indicator |
| `context-audit.sh` | Context rot auditor |
| `pre-commit-go.sh` | Go pre-commit hook |
| `pre-push-gate.sh` | Pre-push quality gate |


## tmux Layout

```
Dashboard:  [0.0 Info] [0.1 Boss]
Core Team:  [1.0 Taskmaster] [1.1 Reviewer] [1.2 Deployment] [1.3 Expert]
Team W:     [W.0 Subtaskmaster] [W.1 W1 | W.2 W2] [W.3 W3 | W.4 W4] ...
```

Dynamic grid auto-expands when all workers are busy.

**Pane IPC:** `send-keys` (< 200 chars) · `load-buffer` + `paste-buffer` (long) · `capture-pane` (read)

- **PANE_SAFE:** `${PANE//[-:.]/_}` — `doey-project:0.5` → `doey_project_0_5`
- **Titles:** `"<pane_id> | <role>"` — `"d-t1-mgr | doey T1 Subtaskmaster"`, `"d-tm | doey TM"`
- **Timing:** Subtaskmaster briefing 8s; workers ready ~15s
- **Notifications:** `bell-action none`, `visual-bell off`; uses `osascript`


## Runtime State

Root: `/tmp/doey/<project>/`. Created by `doey init`, ensured by `init_hook()`.

| Path | Purpose |
|------|---------|
| `session.env` | Session manifest |
| `team_<W>.env` | Per-window team config |
| `worker-system-prompt-w<W>-<N>.md` | Per-worker prompt |
| `status/<pane_safe>.status` | 4-line: PANE, UPDATED, STATUS, TASK |
| `status/<pane_safe>.reserved` | Permanent reservation marker |
| `status/<pane_safe>.role` | Per-pane role cache (authoritative for hook role detection) |
| `status/pane_hash_<pane_safe>` | Output hash (change detection) |
| `status/unchanged_count_<W>_<index>` | Stuck-detection counter |
| `status/completion_pane_<W>_<index>` | Worker completion event |
| `status/crash_pane_<W>_<index>` | Crash alert |
| `status/manager_crashed_W<N>` | Subtaskmaster crash marker |
| `status/col_*.collapsed` | Collapsed column markers |
| `research/<pane_safe>.task` | Research task marker |
| `reports/<pane_safe>.report` | Research report |
| `results/` | Structured result JSON |
| `broadcasts/` | Broadcast messages |
| `messages/` | Inter-instance messages (created by `init_hook()`) |
| `triggers/` | Wake triggers (`.trigger` files touched to wake wait hooks) |
| `tasks/` | Runtime task cache (synced from `${PROJECT_DIR}/.doey/tasks/` on session start) |
| `issues/` | Issue reports from Subtaskmaster (`.issue` files) |
| `logs/` | Per-pane runtime logs |
| `errors/` | Structured error log (`errors.log`) and individual `.err` files |
| `debug/` | Debug flight-recorder JSONL (created by `/doey-debug on`) |
| `context_log_W<N>.md` | **Golden Context Log** — Subtaskmaster's accumulated knowledge (survives compaction) |
| `status/state_since_<W>_<idx>` | Duration tracking (epoch when pane entered current state) |
| `status/taskmaster_trigger` | Taskmaster-specific fast-wake trigger |
| `status/notif_cooldown_*` | Desktop notification cooldown timestamps |

**Persistent tasks:** `${PROJECT_DIR}/.doey/tasks/` (source of truth, survives reboots). Runtime `tasks/` is a cache synced on start. Agents read `.doey/tasks/` first, fall back to runtime.

**Status values:** READY, BUSY, BOOTING, FINISHED, RESERVED, LOGGED_OUT.

**Research lifecycle:** dispatch → `.task` → worker investigates → Stop hook blocks until `.report` → Subtaskmaster reads.


## Debugging

| Symptom | Check |
|---------|-------|
| Subtaskmaster writes code | Memory lacks delegation-first rules |
| Invalid pane dispatch | Check `WORKER_PANES` in session.env |
| Empty tasks dispatched | Task text empty before Enter |
| All panes = Subtaskmaster | Hook missing `-t "$TMUX_PANE"` |
| Hooks not firing | Missing `settings.local.json` → `doey init` |
| Research stops early | Check exit 2 in `stop-status.sh`; verify `.task` exists |
| Hook changes ignored | Restart workers: `/doey-clear workers` |
| Dispatch to reserved | Check `.reserved` file; verify `is_reserved()` |
| Runtime file missing | Verify PANE_SAFE escaping; check `init_hook()` ran |
