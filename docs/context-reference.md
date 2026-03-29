# Context Reference

> **Core principle:** Strategic utilization over brute-force parallelism. Workers are disposable context — they feed high-quality content to the Manager, who validates everything. Force multipliers: ultrathink, `/batch`, `/doey-research`, `/doey-simplify-everything`, agent swarms. See CLAUDE.md § Philosophy.

How Claude Code instances in a Doey session receive their configuration, from lowest to highest precedence.

| Precedence | Source | Applies To |
|------------|--------|------------|
| Lowest | Agent definitions (`agents/`) | Boss, Manager, Session Mgr |
| | Settings (4-file merge) | All |
| | Hooks (`.claude/hooks/`) | All |
| | Skills (`.claude/skills/`) | Manager (+ 3 for Workers) |
| | Persistent memory | Boss, Manager, Session Mgr |
| | Environment vars (`session.env`) | All |
| | CLI launch flags | Per-instance |
| | tmux layout | All |
| | Runtime state (`/tmp/doey/`) | All |
| Highest | CLAUDE.md | All |


## Agent Definitions

Files in `agents/` (installed to `~/.claude/agents/`). Body = system prompt.

| Field | Boss | Manager | Session Mgr | ~~Watchdog~~ | ~~Freelancer Watchdog~~ | Tmux UI | Settings Editor | Test Driver | Product Brain | Claude Expert | Platform Expert | Critic |
|-------|------|---------|-------------|----------|---------------------|---------|-----------------|-------------|---------------|---------------|-----------------|--------|
| `model` | `opus` | `opus` | `opus` | ~~`sonnet`~~ | ~~`sonnet`~~ | `opus` | `opus` | `opus` | `opus` | `opus` | `opus` | `opus` |
| `color` | `#E74C3C` | `green` | `#FF6B35` | ~~`yellow`~~ | ~~`#FFA500`~~ | `#E5C07B` | `#4A90D9` | `red` | `#FFD700` | `magenta` | `cyan` | `red` |
| `memory` | `user` | `user` | `user` | ~~`none`~~ | ~~`none`~~ | `none` | `none` | `none` | `user` | `user` | `user` | `user` |

> **Note:** Watchdog and Freelancer Watchdog agents are **deprecated**. Their definitions remain in `agents/` for reference but are no longer launched in new sessions.

Precedence: CLI `--model` > frontmatter > settings.

**Specialist team agents** (SEO, Visual) are also in `agents/` but only loaded when those teams are spawned: `seo-manager`, `seo-technical`, `seo-content`, `seo-sitemap`, `seo-reporter`, `visual-manager`, `visual-investigator`, `visual-reviewer`, `visual-a11y`, `visual-reporter`.


## Settings

Merge order (later wins for scalars; arrays additive; objects deep-merged):

1. `~/.claude/settings.json` — agent teams, model, notifications
2. `~/.claude/settings.local.json` — user-level overrides
3. `<project>/.claude/settings.json` — project-level
4. `<project>/.claude/settings.local.json` — permissions + hooks (copied by `doey init`)

Hooks require explicit registration in `settings.local.json` — not auto-discovered.


## Hooks

All in `.claude/hooks/`. Exit codes: 0=allow, 1=block+error, 2=block+feedback.

| File | Event | Purpose |
|------|-------|---------|
| `common.sh` | — | Shared utils: `init_hook()`, `parse_field()`, `_read_team_key()`, role checks, `send_notification()` |
| `on-session-start.sh` | SessionStart | Sets DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX, DOEY_TEAM_WINDOW, DOEY_TEAM_DIR, DOEY_RUNTIME, SESSION_NAME, PROJECT_DIR, PROJECT_NAME |
| `on-prompt-submit.sh` | UserPromptSubmit | BUSY status; READY on `/compact`; collapsed column restore |
| `on-pre-tool-use.sh` | PreToolUse | Role-based tool blocking |
| `on-pre-compact.sh` | PreCompact | Preserves orchestration state before compaction |
| `post-tool-lint.sh` | PostToolUse | Bash 3.2 compatibility lint |
| `stop-status.sh` | Stop | FINISHED/RESERVED/READY; blocks research without reports |
| `stop-results.sh` | Stop | Result JSON and completion events |
| `stop-notify.sh` | Stop | Unified stop notifications: Worker→Manager, Manager→Session Mgr, Session Mgr→desktop |
| `on-notification.sh` | Notification | Desktop notification for SM permission requests (30s cooldown) |
| `session-manager-wait.sh` | — | Session Manager sleep/wake between cycles (trigger, message, result, crash) |
| `watchdog-scan.sh` | — | ~~DEPRECATED~~ — Pane scanning (called directly, not registered) |
| `watchdog-wait.sh` | — | ~~DEPRECATED~~ — Event-driven sleep between scans |

**Identity:** Hooks must use `tmux display-message -t "$TMUX_PANE"` — without `-t`, tmux returns the focused pane.


## Skills

Project-level in `.claude/skills/<name>/SKILL.md`, invoked via `/skill-name`, loaded on-demand.

**Manager skills:**
`/doey-dispatch` (send to idle workers), `/doey-delegate` (to specific worker), `/doey-research` (with report enforcement), `/doey-monitor` (detect pane states), `/doey-status` (share/check status), `/doey-broadcast` (message all), `/doey-reload` (hot-reload), `/doey-reinstall` (pull + install), `/doey-repair` (dashboard diagnostic), `/doey-reserve` (reserve/unreserve panes), `/doey-watchdog-compact`, `/doey-purge` (audit context rot), `/doey-simplify-everything` (full codebase simplification), `/doey-stop` (stop worker), `/doey-clear` (restart workers/Watchdog/Manager), `/doey-rd-team` (spawn R&D product team on live codebase), `/doey-login` (fix auth), `/doey-settings` (interactive settings), `/unknown-task` (fallback for unrecognized tasks)

**Session Manager skills:**
`/doey-worktree` (also Manager), `/doey-add-window`, `/doey-kill-window`, `/doey-kill-session`, `/doey-kill-all-sessions`, `/doey-list-windows`

**Worker skills:** `/doey-status`, `/doey-reserve`, `/doey-stop`.


## Persistent Memory

Auto-loaded at startup; lines after 200 truncated. Store stable patterns, not session state.

- Boss: `~/.claude/agent-memory/doey-boss/MEMORY.md`
- Manager: `~/.claude/agent-memory/doey-manager/MEMORY.md`
- Session Mgr: `~/.claude/agent-memory/doey-session-manager/MEMORY.md`
- ~~Watchdog~~: disabled (`memory: none`) — **deprecated**


## Environment Variables

Bootstrap: `doey.sh` → `tmux set-environment DOEY_RUNTIME` → writes `session.env`.

**Session-level (`session.env`):**
`PROJECT_DIR`, `PROJECT_NAME`, `SESSION_NAME`, `GRID`, `ROWS` (dynamic only), `MAX_WORKERS` (dynamic only), `CURRENT_COLS` (dynamic only), `TOTAL_PANES` (static only), `WORKER_COUNT`, `WORKER_PANES`, `WATCHDOG_PANE` (deprecated), `RUNTIME_DIR`, `PASTE_SETTLE_MS`, `IDLE_COLLAPSE_AFTER`, `IDLE_REMOVE_AFTER`, `TEAM_WINDOWS`, `WDG_SLOT_1`..`WDG_SLOT_6` (deprecated), `SM_PANE`

**Set by tmux/Claude Code:** `TMUX_PANE`, `CLAUDE_PROJECT_DIR`

**Set by hooks:** `DOEY_ROLE`, `DOEY_PANE_ID`, `DOEY_PANE_INDEX`, `DOEY_WINDOW_INDEX`, `DOEY_TEAM_WINDOW`, `DOEY_TEAM_DIR`, `DOEY_RUNTIME`, `DOEY_TEAM_ROLE`, `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`

**Per-window (`team_<W>.env`):** `WINDOW_INDEX`, `GRID`, `MANAGER_PANE`, `WATCHDOG_PANE` (deprecated), `WORKER_PANES`, `WORKER_COUNT`, `SESSION_NAME`, `TEAM_TYPE` (`managed` or `freelancer`), `TEAM_DEF` (team definition name, if any). Loaded via `_read_team_key()`, overrides session.env for per-window fields.


## CLI Launch Flags

| Instance | Command |
|----------|---------|
| Boss | `claude --dangerously-skip-permissions --agent doey-boss` |
| Session Manager | `claude --dangerously-skip-permissions --agent doey-session-manager` |
| Manager | `claude --dangerously-skip-permissions --model opus --name "T<N> Window Manager" --agent doey-manager` |
| ~~Watchdog~~ | ~~`claude --dangerously-skip-permissions --model sonnet --name "T<N> Watchdog" --agent doey-watchdog`~~ (deprecated) |
| Workers | `claude --dangerously-skip-permissions --model opus --name "T<N> W<P>" --append-system-prompt-file <prompt>.md` |

Workers use `--append-system-prompt-file` (not `--agent`) for per-worker identity. Precedence: CLI flags > agent frontmatter > settings.

**Note:** Session Manager does not pass `--model` explicitly — it relies on the `model: opus` frontmatter in `agents/doey-session-manager.md`.


## Shell Scripts

All in `shell/`, installed to `~/.local/bin/` by `install.sh`.

| File | Purpose |
|------|---------|
| `doey.sh` | CLI entry point — session lifecycle, grid management, all subcommands |
| `info-panel.sh` | Live dashboard (pane 0.0) |
| `settings-panel.sh` | Interactive settings TUI |
| `doey-statusline.sh` | Claude Code statusline integration |
| `doey-config-default.sh` | Default config template |
| `doey-go-check.sh` | Go TUI availability check |
| `pane-border-status.sh` | tmux pane border formatting |
| `tmux-statusbar.sh` | tmux status bar content |
| `tmux-theme.sh` | tmux color theme |
| `tmux-settings-btn.sh` | Settings button for tmux status bar |
| `context-audit.sh` | Context rot auditor |
| `pre-commit-go.sh` | Go pre-commit hook |


## tmux Layout

```
Dashboard: [0.0 Info] [0.1 Boss] [0.2 Session Mgr]   (0.3+ formerly Watchdog slots — deprecated)
Team W:    [W.0 Mgr] [W.1 W1 | W.2 W2] [W.3 W3 | W.4 W4] ...
```

Dynamic grid auto-expands when all workers are busy.

**Pane communication:**
- `send-keys` — short commands (< 200 chars)
- `load-buffer` + `paste-buffer` — long/multi-line tasks
- `capture-pane` — read pane output

**Key details:**
- **PANE_SAFE escaping:** `${PANE//[-:.]/_}` — e.g. `doey-project:0.5` → `doey_project_0_5`
- **Pane titles:** Format is `"<pane_id> | <role>"` — e.g. `"d-t1-mgr | doey T1 Mgr"`, `"d-sm | doey SM"`, `"d-boss | doey Boss"`, `"d-t1-w1 | Worker"`
- **Startup timing:** Manager briefing 8s; workers ready ~15s
- **Notifications:** `bell-action none`, `visual-bell off`; uses `osascript` instead


## Runtime State

Root: `/tmp/doey/<project>/`. Directories created by `doey init`, ensured by `init_hook()`.

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
| `status/watchdog_W<W>.heartbeat` | ~~Watchdog liveness~~ (deprecated) |
| `status/watchdog_pane_states_W<W>.json` | ~~Watchdog state snapshot~~ (deprecated) |
| `status/completion_pane_<W>_<index>` | Worker completion event |
| `status/crash_pane_<W>_<index>` | Crash alert |
| `status/manager_crashed_W<N>` | Manager crash marker |
| `status/col_*.collapsed` | Collapsed column markers |
| `research/<pane_safe>.task` | Research task marker |
| `reports/<pane_safe>.report` | Research report |
| `results/` | Structured result JSON |
| `broadcasts/` | Broadcast messages (created on-demand by `/doey-broadcast`) |
| `messages/` | Inter-instance messages (created by `init_hook()`) |
| `triggers/` | Wake triggers (`.trigger` files touched to wake wait hooks) |
| `lifecycle/` | Lifecycle events from `notify_watchdog()` (`.evt` files) |
| `tasks/` | Session-level task tracking (`.task` files, managed by SM) |
| `issues/` | Issue reports from Manager/Watchdog (`.issue` files) |
| `logs/` | Per-pane runtime logs |
| `errors/` | Structured error log (`errors.log`) and individual `.err` files |
| `debug/` | Debug flight-recorder JSONL (created by `/doey-debug on`) |
| `context_log_W<N>.md` | **Golden Context Log** — Manager's accumulated knowledge (survives compaction) |
| `status/state_since_<W>_<idx>` | Duration tracking (epoch when pane entered current state) |
| `status/anomaly_<W>_<pane>.event` | ~~Active anomaly marker~~ (deprecated — watchdog) |
| `status/anomaly_count_<W>_<pane>` | ~~Consecutive anomaly count~~ (deprecated — watchdog) |
| `status/team_snapshot_W<N>.txt` | ~~Watchdog team snapshot~~ (deprecated) |
| `status/session_manager_trigger` | SM-specific fast-wake trigger |
| `status/notif_cooldown_*` | Desktop notification cooldown timestamps |

**Status values:** READY, BUSY, BOOTING, FINISHED, RESERVED, LOGGED_OUT.

**Watchdog anomaly types (deprecated):** PROMPT_STUCK, WRONG_MODE, QUEUED_INPUT, LOGGED_OUT.

**Research lifecycle:** dispatch → `.task` created → worker investigates → Stop hook blocks until `.report` written → Manager reads report.


## Debugging

| Symptom | Check |
|---------|-------|
| Manager writes code itself | Memory lacks delegation-first rules |
| Manager dispatches to invalid pane | Check `WORKER_PANES` in session.env |
| Manager sends empty tasks | Task text empty before Enter |
| All panes think they're Manager | Hook missing `-t "$TMUX_PANE"` |
| Hooks not firing | `.claude/settings.local.json` missing (`doey init`) |
| ~~Watchdog stops monitoring~~ | ~~Wait hook not returning; check `watchdog-wait.sh` trigger path~~ (deprecated) |
| ~~Watchdog spams notifications~~ | ~~State tracking lost after compaction~~ (deprecated) |
| Research stops without report | Check exit 2 in `stop-status.sh`; verify `.task` exists |
| Workers ignore hook changes | Restart workers (`/doey-clear workers`) |
| Dispatch to reserved pane | Check `.reserved` file; verify `is_reserved()` |
| Runtime file not found | Verify PANE_SAFE escaping; check `init_hook()` ran |
