# Context Reference -- Window Manager & Watchdog Agents

## Context Layer Model

```
Load Order (bottom = first, top = last / highest precedence)

  +----------------------------------------------------------+
  | 10. CLAUDE.md           (project root — loaded by all)   |
  +----------------------------------------------------------+
  |  9. Runtime State       (status files, messages, tasks)  |
  +----------------------------------------------------------+
  |  8. tmux Integration    (session, panes, send-keys)      |
  +----------------------------------------------------------+
  |  7. CLI Launch Flags    (--agent, --model, --dangerously) |
  +----------------------------------------------------------+
  |  6. Environment Vars    (session.env, TMUX_PANE)         |
  +----------------------------------------------------------+
  |  5. Persistent Memory   (~/.claude/agent-memory/)        |
  +----------------------------------------------------------+
  |  4. Skills/Commands     (~/.claude/commands/doey-*.md)   |
  +----------------------------------------------------------+
  |  3. Hook System         (.claude/hooks/ modular scripts) |
  +----------------------------------------------------------+
  |  2. Claude Code Settings (4-file merge chain)            |
  +----------------------------------------------------------+
  |  1. Agent Definitions   (agents/doey-manager.md, etc.)   |
  +----------------------------------------------------------+
```

| Layer | Source Files | Applies To | Load Time |
|-------|-------------|------------|-----------|
| 1. Agent Definitions | `agents/doey-manager.md`, `agents/doey-session-manager.md`, `agents/doey-watchdog.md` | Window Manager, Session Manager, Watchdog | Startup (via `--agent`) |
| 2. Settings | 4-file merge chain | All | Startup |
| 3. Hooks | `.claude/hooks/` modular scripts | All | Runtime (on events) |
| 4. Skills | `commands/doey-*.md` | Window Manager primarily | On-demand |
| 5. Memory | `~/.claude/agent-memory/<agent>/MEMORY.md` | Window Manager | Startup |
| 6. Env Vars | `session.env`, tmux env | All | Startup + Runtime |
| 7. CLI Flags | `--agent`, `--model`, `--dangerously-skip-permissions` | Per-instance | Startup |
| 8. tmux | Session config, pane structure | All | Startup |
| 9. Runtime | `/tmp/doey/<name>/` tree | All | Runtime |
| 10. CLAUDE.md | Project root | All | Startup |


## Layer 1: Agent Definitions

**Files:** `agents/doey-manager.md`, `agents/doey-session-manager.md`, `agents/doey-watchdog.md`, `agents/test-driver.md` (installed to `~/.claude/agents/`)

| Field | Window Manager | Session Manager | Watchdog | Effect |
|-------|----------------|-----------------|----------|--------|
| `model` | `opus` | `opus` | `haiku` | Default model; CLI `--model` overrides |
| `color` | `green` | `#FF6B35` | `yellow` | Status line color |
| `memory` | `user` | `user` | `none` | Window Manager/Session Manager store to `~/.claude/agent-memory/<name>/`; Watchdog has no memory |

Body text below frontmatter becomes the system prompt. Window Manager: identity, workflow, delegation rules. Session Manager: multi-window orchestration, cross-team coordination. Watchdog: monitoring loop, prompt detection, monitoring rules. See `agents/*.md` for current content.

Precedence: CLI `--model` > frontmatter `model` > settings `model`.


## Layer 2: Claude Code Settings

Merge order (later wins for scalars; arrays are additive):

| File | Key Settings |
|------|-------------|
| `~/.claude/settings.json` | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"`, `skipDangerousModePermissionPrompt: true`, `model: "opus"`, `notifications: false` |
| `~/.claude/settings.local.json` | User-level local overrides (permissions, etc.) |
| `<project>/.claude/settings.json` | Project-level settings (if present) |
| `<project>/.claude/settings.local.json` | Bash permission allow-list and hook registration — stored in the doey repo at `.claude/settings.local.json`, copied to target projects during `doey init`. Hooks are explicitly registered in `hooks` array entries keyed by event name (e.g., `PreToolUse`, `Stop`, `PostToolUse`). |

*Note: User-level settings vary per machine. The doey repo contains a base `settings.local.json` with permission rules and hook registrations. During `doey init`, hooks and settings are copied to the target project directory. Hooks require explicit registration in `settings.local.json` — they are NOT auto-discovered from the `.claude/hooks/` directory.*

Merge: scalars=last-wins, arrays=additive, objects=deep-merged.


## Layer 3: Hook System

| File | Purpose |
|------|---------|
| `common.sh` | Shared: `init_hook()` (stdin JSON, pane identity, runtime dirs, WINDOW_INDEX), `parse_field()` (JSON extraction with jq fallback), `load_team_env()` (per-window team config), role checks (`is_manager()`, `is_session_manager()`, `is_worker()`, `is_watchdog()`, `is_reserved()`), `send_notification()` (cross-platform, Session Manager-only, 60s cooldown), `NL` (portable newline var), `is_numeric()` (numeric validation) |
| `on-session-start.sh` | SessionStart: initial setup |
| `on-prompt-submit.sh` | UserPromptSubmit: sets BUSY status, sets READY on `/compact`, expands collapsed tmux columns |
| `on-pre-tool-use.sh` | PreToolUse: safety guards |
| `on-pre-compact.sh` | PreCompact: context preservation — preserves Window Manager orchestration state (worker assignments, pending results, completion files) and Watchdog-specific state from `watchdog_pane_states_W<N>.json` |
| `post-tool-lint.sh` | PostToolUse: linting after tool use. Returns JSON decision format (`{"decision": "block", "reason": "..."}`) |
| `stop-status.sh` | Stop: sets FINISHED (workers), RESERVED (if reserved), or READY (Window Manager/Watchdog); blocks research workers without reports (exit 2) |
| `stop-results.sh` | Stop: collects and writes results |
| `stop-notify.sh` | Stop: Session Manager notifications |
| `watchdog-scan.sh` | Utility: called directly by Watchdog for pane scanning (not a registered hook) |

Exit codes: 0=allow, 1=block+error, 2=block+feedback.

**TMUX_PANE identity:** Hooks use `tmux display-message -t "$TMUX_PANE"` (with `-t`) to resolve the correct pane. Without `-t`, tmux returns the focused pane (usually 0.0), causing all workers to misidentify as Window Manager.


## Layer 4: Skills/Commands

24 skills installed to `~/.claude/commands/`, invoked via `/skill-name`. Loaded on-demand as additional user-turn instructions.

| Skill | Primary Agent | Purpose |
|-------|---------------|---------|
| `/doey-dispatch` | Window Manager | Send task to idle workers |
| `/doey-delegate` | Window Manager | Delegate to specific worker |
| `/doey-research` | Window Manager | Research task with report enforcement |
| `/doey-monitor` | Window Manager | Detect FINISHED/BUSY/ERROR/READY |
| `/doey-status` | Window Manager/Workers | Share or check status |
| `/doey-broadcast` | Window Manager | Message all instances |
| `/doey-send` | Window Manager | Message specific pane |
| `/doey-inbox` | Any | Read messages |
| `/doey-team` | Window Manager | Team layout overview |
| `/doey-add-window` | Session Manager | Add a new team window |
| `/doey-kill-window` | Session Manager | Kill a team window and all its processes |
| `/doey-kill-session` | Session Manager | Kill entire Doey session |
| `/doey-kill-all-sessions` | Session Manager | Kill all running Doey sessions across all projects |
| `/doey-list-windows` | Session Manager | List all team windows with status |
| `/doey-reload` | Window Manager | Hot-reload session (install files, restart Manager + Watchdog) |
| `/doey-restart-window` | Window Manager | Restart workers + Watchdog in a window |
| `/doey-reinstall` | Window Manager | Pull + re-install |
| `/doey-reserve` | Window Manager/Workers | Reserve/unreserve panes |
| `/doey-watchdog-compact` | Window Manager | Compact Watchdog context |
| `/doey-purge` | Window Manager | Scan and clean stale runtime files |
| `/doey-analyze` | Window Manager | Full project context analysis — find and fix doc obscurities |
| `/doey-stop` | Window Manager | Stop a specific worker |
| `/doey-stop-all` | Window Manager | Stop all sessions *(deprecated, replaced by `/doey-kill-session`)* |
| `/doey-restart-workers` | Window Manager | Restart workers + Watchdog *(deprecated, replaced by `/doey-restart-window`)* |

Agent usage: Window Manager uses all except `/doey-inbox` and window-management commands. Session Manager uses `/doey-list-windows`, `/doey-add-window`, `/doey-kill-window`, `/doey-kill-session`, `/doey-kill-all-sessions`. Watchdog uses none. Workers use `/doey-inbox`, `/doey-status`, `/doey-reserve`.


## Layer 5: Persistent Memory

| Agent | Path | Notes |
|-------|------|-------|
| Window Manager | `~/.claude/agent-memory/doey-manager/MEMORY.md` | Stores dispatch patterns, delegation rules, hook behavior |
| Watchdog | `~/.claude/agent-memory/doey-watchdog/MEMORY.md` | Disabled (agent definition has `memory: none`) |

Auto-loaded at startup; lines after 200 truncated. Store stable patterns, not session state.


## Layer 6: Environment Variables

Bootstrap: `doey.sh` → `tmux set-environment DOEY_RUNTIME` → writes `session.env`.
Agents read: `tmux show-environment DOEY_RUNTIME | cut -d= -f2-` → `source session.env`.

| Variable | Description | Source | Mode |
|----------|-------------|--------|------|
| `PROJECT_DIR` | Absolute path to project root | doey.sh | both |
| `PROJECT_NAME` | Sanitized project name | doey.sh | both |
| `SESSION_NAME` | tmux session name (`doey-<name>`) | doey.sh | both |
| `GRID` | Grid layout (e.g., `6x2`) or `dynamic` | doey.sh | both |
| `ROWS` | Number of rows in grid (always `2`) | doey.sh | dynamic only |
| `MAX_WORKERS` | Maximum worker count | doey.sh | dynamic only |
| `CURRENT_COLS` | Current column count (updated as grid expands) | doey.sh | dynamic only |
| `TOTAL_PANES` | Total pane count | doey.sh | static only |
| `WORKER_COUNT` | Number of workers | doey.sh | both |
| `WATCHDOG_PANE` | Watchdog pane index | doey.sh | both |
| `WORKER_PANES` | Comma-separated worker indices | doey.sh | both |
| `RUNTIME_DIR` | Runtime state directory | doey.sh | both |
| `PASTE_SETTLE_MS` | Paste buffer settle time in ms | doey.sh | both |
| `IDLE_COLLAPSE_AFTER` | Seconds before idle column collapse | doey.sh | both |
| `IDLE_REMOVE_AFTER` | Seconds before idle column removal | doey.sh | both |
| `TMUX_PANE` | tmux auto-set pane ID (e.g., `%0`) | tmux | both |
| `CLAUDE_PROJECT_DIR` | Claude Code project dir | Claude Code | both |
| `CLAUDECODE` | Set when inside Claude Code | Claude Code | both |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `1` — enables Agent Teams | Claude Code | both |
| `TEAM_WINDOWS` | Comma-separated list of active team window indices (e.g., `"0,1,2"`) | doey.sh | both |
| `DOEY_ROLE` | Pane role (manager/watchdog/worker) | hooks | both |
| `DOEY_PANE_INDEX` | Pane index within session | hooks | both |
| `DOEY_WINDOW_INDEX` | Window index for this pane | hooks | both |
| `DOEY_TEAM_WINDOW` | Team window index this pane monitors/belongs to | on-session-start.sh | both |

**Per-window team config:** Each team window has a `team_<W>.env` file in the runtime directory:

| Variable | Description |
|----------|-------------|
| `WINDOW_INDEX` | Window index (matches `<W>` in filename) |
| `GRID` | Grid layout for this window |
| `MANAGER_PANE` | Window Manager pane index (always `0`) |
| `WATCHDOG_PANE` | Watchdog Dashboard pane index (0.1-0.3) |
| `WORKER_PANES` | Comma-separated worker pane indices (W.1+) |
| `WORKER_COUNT` | Number of workers in this window |
| `SESSION_NAME` | tmux session name (same as session.env) |

Loaded by hooks via `load_team_env()` and by commands via manual sourcing. Team env values override session.env for per-window fields (`WATCHDOG_PANE`, `WORKER_PANES`, etc.).


## Layer 7: CLI Launch Flags

| Instance | Command |
|----------|---------|
| Window Manager | `claude --dangerously-skip-permissions --agent doey-manager` |
| Watchdog | `claude --dangerously-skip-permissions --model haiku --agent doey-watchdog` |
| Workers | `claude --dangerously-skip-permissions --model opus --append-system-prompt-file /tmp/doey/<name>/worker-system-prompt-<N>.md` |

Precedence: CLI flags > agent frontmatter > settings files.

Workers use `--append-system-prompt-file` (not `--agent`) to inject per-worker rules and identity.


## Layer 8: tmux Integration

Window 0 is always the Dashboard. Layout: pane 0.0 = Info Panel, panes 0.1-0.3 = Watchdog slots (one per team), pane 0.4 = Session Manager (when multiple teams exist). Team grids start at window 1+.

Default grid: **dynamic** (launches with 3 worker columns (6 workers), auto-adds more when all workers are busy). In team windows: pane W.0 = Window Manager, W.1+ = Workers. Watchdog for each team runs in Dashboard (panes 0.1-0.3).

```
Dashboard (window 0):
+--------+--------+--------+--------+--------+
|  0.0   |  0.1   |  0.2   |  0.3   |  0.4   |
|  INFO  |  WDG1  |  WDG2  |  WDG3  |  SMGR  |
| PANEL  | (team1)| (team2)| (team3)|        |
+--------+--------+--------+--------+--------+

Dynamic grid (default) — team window layout, then after `doey add`:

 Initial (6 workers, window W)                                    After `doey add` (8 workers)
+--------+--------+--------+--------+                         +--------+--------+--------+--------+--------+
|  W.0   |  W.1   |  W.3   |  W.5   |                         |  W.0   |  W.1   |  W.3   |  W.5   |  W.7   |
|  MGR   |  W1    |  W3    |  W5    |                         |  MGR   |  W1    |  W3    |  W5    |  W7    |
+--------+--------+--------+--------+                         +--------+--------+--------+--------+--------+
|        |  W.2   |  W.4   |  W.6   |                         |        |  W.2   |  W.4   |  W.6   |  W.8   |
|        |  W2    |  W4    |  W6    |                         |        |  W2    |  W4    |  W6    |  W8    |
+--------+--------+--------+--------+                         +--------+--------+--------+--------+--------+
```

Static grid (legacy, via `doey 6x2`): all panes are Workers except W.0 (Manager).

```
+--------+--------+--------+--------+--------+--------+
|  W.0   |  W.1   |  W.2   |  W.3   |  W.4   |  W.5   |
|  MGR   |  W1    |  W2    |  W3    |  W4    |  W5    |
+--------+--------+--------+--------+--------+--------+
|  W.6   |  W.7   |  W.8   |  W.9   |  W.10  |  W.11  |
|  W6    |  W7    |  W8    |  W9    |  W10   |  W11   |
+--------+--------+--------+--------+--------+--------+
```

| Method | Use Case |
|--------|----------|
| `send-keys` | Short commands (< 200 chars) |
| `load-buffer` + `paste-buffer` | Long/multi-line tasks |
| `capture-pane` | Read pane output |

Bell suppression: `bell-action none`, `visual-bell off`. Notifications via `osascript` in hooks.
Display: `pane-border-status top`, heavy borders, role-aware colors, mouse enabled, status bar shows NB/NR/NF/NRsv counts (Busy/Ready/Finished/Reserved).

**Info Panel:** `shell/info-panel.sh` runs full-screen in window 0 (Dashboard) as a live dashboard. It displays team count, worker totals, per-window status, recent events (completions/crashes), and watchdog heartbeat ages. Refreshes every 5 minutes.

**PANE_SAFE escaping:** `${PANE//[:.]/_}` — e.g., `doey-project:0.5` becomes `doey-project_0_5`. Used in all runtime file names.

**Pane title format:** `"MGR Manager"`, `"WDG Watchdog"`, `"W1 Worker 1"` etc. Used by `rebuild_pane_state()` to recover after pane index shifts.

**Startup timing:** Window Manager briefing sent after 8s delay. Workers ready in ~15s.


## Layer 9: Runtime State

```
/tmp/doey/<project>/
  session.env                        # Session manifest (includes TEAM_WINDOWS)
  team_<W>.env                       # Per-window team config (W = window index)
  worker-system-prompt-N.md          # Per-worker prompt (base + identity)
  status/                            # [init-time]
    <pane_safe>.status               # 4-line: PANE, UPDATED, STATUS, TASK
    <pane_safe>.reserved             # contains "permanent"
    pane_hash_<pane_safe>            # Watchdog output hashes for change detection
    unchanged_count_<W>_<index>      # Watchdog stuck-detection counter (per window + pane)
    watchdog_W<W>.heartbeat          # Watchdog liveness marker (per window)
    watchdog_pane_states_W<W>.json   # Watchdog state snapshot (per window)
    pane_map                         # Pane ID-to-index mapping cache
    notif_cooldown_*                 # Notification rate-limiting markers
    col_*.collapsed                  # Collapsed column markers
    completion_pane_<W>_<index>      # Worker completion events (consumed by Watchdog)
    crash_pane_<W>_<index>           # Crash alerts (written by Watchdog)
  research/                          # [hook-init] Created by common.sh init_hook()
    <pane_safe>.task                  # Research task marker
  reports/                           # [hook-init] Created by common.sh init_hook()
    <pane_safe>.report               # Research report
  results/                           # [hook-init] Structured result JSON files
  messages/                          # [hook-init] Inter-pane messages
    delivered/                       # Consumed messages subdirectory
  broadcasts/                        # [init-time] Broadcast messages
```

*Init-time directories (`messages/`, `broadcasts/`, `status/`) are created during `doey init`. On the first hook invocation in any pane, `common.sh init_hook()` eagerly ensures `status/`, `research/`, `reports/`, `results/`, and `messages/` all exist (fast-path skip if already present).*

**Status values:** READY, BUSY, FINISHED, RESERVED.

**Reservation:** Created by `/doey-reserve` (permanent only). Consumed by `is_reserved()`, statusbar, and Window Manager dispatch.

**Research lifecycle:** Window Manager dispatches → `.task` created → worker investigates → Stop hook blocks until `.report` written → Window Manager reads report.


## Layer 10: CLAUDE.md

Loaded by all instances. Contains: project overview, architecture, key directories, conventions, testing guidance, file reference.


## Debugging

| Symptom | Check |
|---------|-------|
| Window Manager writes code itself | Memory lacks delegation-first rules |
| Window Manager uses wrong session | `tmux show-environment DOEY_RUNTIME` invalid |
| Window Manager dispatches to Watchdog | `WATCHDOG_PANE` in session.env wrong |
| Window Manager sends empty tasks | Task text empty before Enter |
| Session Manager gets no stop notifications | `stop-notify.sh` not registered; pane not resolving to 0.4 in Dashboard window |
| Watchdog stops monitoring | Stop hook keep-alive failing; check `WATCHDOG_PANE` |
| Watchdog spams notifications | State tracking lost after compaction |
| All panes think they're Window Manager | Hook using bare `tmux display-message` without `-t "$TMUX_PANE"` |
| Hooks not firing | Project `.claude/settings.local.json` missing (should be created by `doey init`) |
| Research worker stops without report | Check exit 2 path in `stop-status.sh`; verify `.task` created |
| Workers don't pick up hook changes | Restart workers (`/doey-restart-window`) |
| Dispatch to reserved pane | Check `.reserved` file exists; verify `is_reserved()` |
| Messages not delivered | Check `messages/` dir — inter-pane messages go to `messages/<pane_safe>_<timestamp>.msg`, consumed messages move to `messages/delivered/` |
| Runtime file not found | Verify PANE_SAFE escaping: `${PANE//[:.]/_}`. Directories are created eagerly by `init_hook()` — check that hooks have fired at least once |

**Trace order:** 1. Agent definition → 2. Memory → 3. Settings (4-file merge) → 4. Hook scripts → 5. Skill files → 6. session.env / tmux env → 7. Runtime state → 8. CLI flags in doey.sh.
