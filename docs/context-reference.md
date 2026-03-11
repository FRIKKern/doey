# Context Reference -- Manager & Watchdog Agents

## Overview

This document maps every context layer that influences the behavior of the
Manager and Watchdog agents in Doey. Use it to debug
unexpected behavior, understand load order, and optimize agent performance.

Each Claude Code instance receives context from up to 10 layers, merged in a
specific order. A change in any layer can alter agent behavior. This reference
documents what IS, not what should be.


## Context Layer Model

```
Load Order (bottom = loaded first, top = loaded last / highest precedence)

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
| 1. Agent Definitions | `agents/doey-manager.md`, `agents/doey-watchdog.md` | Manager, Watchdog | Startup (via `--agent`) |
| 2. Claude Code Settings | 4-file merge chain (see below) | All | Startup |
| 3. Hook System | `.claude/hooks/common.sh` + `on-*.sh` scripts | All (registered in project settings) | Runtime (on events) |
| 4. Skills/Commands | `commands/doey-*.md` (15 files) | Manager primarily; some Watchdog | On-demand (`/skill-name`) |
| 5. Persistent Memory | `~/.claude/agent-memory/doey-manager/MEMORY.md` | Manager | Startup (system prompt) |
| 6. Environment Variables | `session.env`, tmux env, Claude Code env | All | Startup + Runtime |
| 7. CLI Launch Flags | `--agent`, `--model`, `--dangerously-skip-permissions` | Per-instance | Startup |
| 8. tmux Integration | tmux session config, pane structure | All | Startup (session creation) |
| 9. Runtime State | `/tmp/doey/<name>/` tree | All | Runtime (continuous) |
| 10. CLAUDE.md | `CLAUDE.md` in project root | All | Startup (project context) |


## Layer 1: Agent Definitions

**Files:**
- `agents/doey-manager.md` -- installed to `~/.claude/agents/doey-manager.md`
- `agents/doey-watchdog.md` -- installed to `~/.claude/agents/doey-watchdog.md`

### Frontmatter Fields

| Field | Manager | Watchdog | Effect |
|-------|---------|----------|--------|
| `name` | `doey-manager` | `doey-watchdog` | Agent identifier for `--agent` flag |
| `model` | `opus` | `haiku` | Default model; overridden by CLI `--model` |
| `color` | `green` | `yellow` | Status line color in Claude Code UI |
| `memory` | `user` | `user` | Memory scope; stores to `~/.claude/agent-memory/<name>/` |
| `description` | Orchestrator examples | Monitoring examples | Shown in agent picker; used by Agent tool matching |

### Body Text

The markdown body below the frontmatter `---` becomes the agent's system
prompt. It is injected into the conversation as the primary instruction set.

- **Manager body:** 253 lines defining identity, capabilities (discover team,
  check idle, send tasks, monitor), workflow (classify, plan, delegate,
  monitor, report), delegation-first rules, and communication style.
- **Watchdog body:** 175 lines defining monitoring loop, prompt detection
  patterns, auto-accept vs notify rules, state transition table, macOS
  notification format, rate limiting, and safety rules.

### Model Field vs CLI Flag

Precedence: CLI `--model` > agent frontmatter `model` > global settings `model`.

The Watchdog is launched with explicit `--model haiku`, which matches its
frontmatter. If the frontmatter were changed to `opus` but the launch command
still said `--model haiku`, the CLI flag would win.


## Layer 2: Claude Code Settings

Claude Code merges settings from 4 files in this order (later wins for
scalars; arrays like `permissions.allow` are additive):

```
1. ~/.claude/settings.json          (global)
2. ~/.claude/settings.local.json    (global local — gitignored)
3. <project>/.claude/settings.json  (project — committed)
4. <project>/.claude/settings.local.json  (project local — gitignored)
```

### File Contents

**`~/.claude/settings.json`** (global):
- `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"` -- enables Agent Teams feature
- `skipDangerousModePermissionPrompt: true` -- suppresses `--dangerously-skip-permissions` warning
- `model: "opus"` -- default model for all instances
- `notifications: false` -- disables built-in notifications (custom ones via hooks)

**`~/.claude/settings.local.json`** (global local):
- `permissions.allow: ["Bash(brew install:*)"]` -- allows brew install without prompting

**`<project>/.claude/settings.json`** (project):
Not present. Would be committed to repo for shared project settings.

**`<project>/.claude/settings.local.json`** (project local):
- Registers 4 hook events: `UserPromptSubmit`, `Stop`, `PreToolUse`, `PreCompact`
- Each event maps to a modular script in `.claude/hooks/on-*.sh`
- `matcher: ""` matches all prompts (no filtering)
- `$CLAUDE_PROJECT_DIR` is expanded by Claude Code at runtime

### Merge Behavior

- **Scalars** (model, notifications): last-wins. Project local overrides global.
- **Arrays** (permissions.allow): additive. All entries from all files are combined.
- **Objects** (hooks, env): deep-merged. Keys from later files override earlier ones.


## Layer 3: Hook System

### Architecture

The hook system uses a modular architecture with a shared utilities file and individual handler scripts:

| File | Purpose |
|------|---------|
| `.claude/hooks/common.sh` | Shared utilities: pane identity resolution, runtime dir detection, status file helpers, reservation management (`is_reserved()`, `reserve_pane()`, `unreserve_pane()`, `get_reservation_info()`) |
| `.claude/hooks/on-prompt-submit.sh` | UserPromptSubmit handler |
| `.claude/hooks/on-stop.sh` | Stop handler |
| `.claude/hooks/on-pre-tool-use.sh` | PreToolUse handler |
| `.claude/hooks/on-pre-compact.sh` | PreCompact handler |
| `.claude/hooks/status-hook.sh` | Legacy monolithic hook (kept as reference, no longer registered) |

Each `on-*.sh` script sources `common.sh` for shared functionality.

### Registered Events

| Event | Script | Trigger | Payload Fields |
|-------|--------|---------|----------------|
| `UserPromptSubmit` | `on-prompt-submit.sh` | When a prompt is submitted to any Claude instance | `hook_event_name`, `prompt` |
| `Stop` | `on-stop.sh` | When a Claude instance finishes responding | `hook_event_name`, `last_assistant_message`, `stop_hook_active` |
| `PreToolUse` | `on-pre-tool-use.sh` | Before a tool is executed | `hook_event_name`, `tool_name`, `tool_input` |
| `PreCompact` | `on-pre-compact.sh` | Before context compaction occurs | `hook_event_name` |

### Exit Code Semantics

| Code | Meaning |
|------|---------|
| 0 | Allow -- proceed normally |
| 1 | Block + show error to user |
| 2 | Block + show stderr as feedback (Claude sees it and can act on it) |

### Hook Flows

**on-prompt-submit.sh (UserPromptSubmit):**
- Writes STATUS: WORKING to the pane's status file
- Calls `reserve_pane 60` for worker panes (auto-reserve on human input; won't downgrade existing longer reservations)
- exit 0

**on-stop.sh (Stop):**
```
Write STATUS: IDLE
    |
+-----+-----+
| .task but  |--yes--> exit 2: "Write report first"
| no .report?|
+-----+-----+
      |no
+-----+-----+
| Watchdog   |--yes--> exit 2: "Continue monitoring"
| pane?      |
+-----+-----+
      |no
+-----+-----+
| Pane 0.0   |--yes--> osascript notification
| (Manager)? |
+-----+-----+
      |no
   exit 0
```

**on-pre-tool-use.sh (PreToolUse):**
- Safety guards for tool usage

**on-pre-compact.sh (PreCompact):**
- Preserves critical context before compaction

### TMUX_PANE Identity Resolution

The hooks use `tmux display-message -t "$TMUX_PANE"` (with `-t` targeting the
specific pane) instead of a bare `tmux display-message`. Without `-t`, tmux
returns info for whichever pane the client is focused on (usually 0.0), which
caused all workers to think they were the Manager and spam notifications.

`$TMUX_PANE` is set automatically by tmux for each process running inside a
pane (e.g., `%0`, `%1`, `%12`). The hook resolves it to the human-readable
format `session:window.pane` (e.g., `doey-myproject:0.4`).


## Layer 4: Skills/Commands

All 14 skills are installed to `~/.claude/commands/` and invoked via `/skill-name`.

| Skill | File | Primary Agent | Purpose |
|-------|------|---------------|---------|
| `/doey-dispatch` | `doey-dispatch.md` | Manager | Send task to one or more idle worker panes (primary dispatch primitive) |
| `/doey-delegate` | `doey-delegate.md` | Manager | Delegate a task to a specific worker pane |
| `/doey-research` | `doey-research.md` | Manager | Dispatch research task with guaranteed report-back (Stop hook enforced) |
| `/doey-monitor` | `doey-monitor.md` | Manager | Smart monitoring: detect DONE, WORKING, ERROR, IDLE states |
| `/doey-status` | `doey-status.md` | Manager/Workers | Share or check status of Claude instances |
| `/doey-broadcast` | `doey-broadcast.md` | Manager | Broadcast message to ALL other instances |
| `/doey-send` | `doey-send.md` | Manager | Send message to a specific pane |
| `/doey-inbox` | `doey-inbox.md` | Any | Check and read messages from other instances |
| `/doey-team` | `doey-team.md` | Manager | View full team layout and pane overview |
| `/doey-stop-all` | `doey-stop-all.md` | Manager | Stop all running Doey sessions |
| `/doey-restart-workers` | `doey-restart-workers.md` | Manager | Restart all workers and Watchdog (not Manager) |
| `/doey-reinstall` | `doey-reinstall.md` | Manager | Pull latest from git and re-run installer |
| `/doey-reserve` | `doey-reserve.md` | Manager/Workers | Reserve or unreserve a worker pane for human use |
| `/doey-watchdog-compact` | `doey-watchdog-compact.md` | Manager | Send `/compact` to Watchdog to reduce token usage |

### How Skills Load

Skills are loaded on-demand when invoked via `/skill-name`. The skill's
markdown content is expanded into the conversation as a prompt. The agent's
existing system prompt (from the agent definition) remains active; the skill
content composes on top of it as additional user-turn instructions.

### Agent-Skill Mapping

- **Manager** uses: `/doey-dispatch`, `/doey-delegate`, `/doey-research`,
  `/doey-monitor`, `/doey-status`, `/doey-broadcast`, `/doey-send`,
  `/doey-team`, `/doey-stop-all`, `/doey-restart-workers`, `/doey-reinstall`,
  `/doey-watchdog-compact`, `/doey-reserve`
- **Watchdog** uses: none (operates from its agent definition, not skills)
- **Workers** use: `/doey-inbox`, `/doey-status`, `/doey-reserve` (when explicitly told to)


## Layer 5: Persistent Memory

### Manager Memory

**Path:** `~/.claude/agent-memory/doey-manager/MEMORY.md`

Key topics: tmux dispatch pattern (exit/restart/rename/paste-buffer),
concurrent file edit mitigations, worker management, slash command locations,
delegation-first rule, skill-first usage rule, hook behavior summary.

### Watchdog Memory

**Path:** `~/.claude/agent-memory/doey-watchdog/MEMORY.md`

Status: File may not exist or may be empty. The Watchdog runs on Haiku and
rarely accumulates persistent memory. This is a gap -- the Watchdog could
benefit from storing patterns about common prompt types and false positives.

### How Memory Loads

Memory files are loaded into the agent's system prompt at startup. The
`MEMORY.md` file is auto-loaded; lines after 200 are truncated. Additional
topic files can be created and linked from MEMORY.md.

### What Should/Shouldn't Be Stored

**Store:** Stable patterns confirmed across sessions, key architectural
decisions, solutions to recurring problems, user preferences.

**Don't store:** Session-specific state, in-progress work, speculative
conclusions, anything that duplicates CLAUDE.md instructions.


## Layer 6: Environment Variables

### Bootstrap Chain

```
doey.sh       --> tmux set-environment DOEY_RUNTIME "/tmp/doey/<name>"
              --> writes session.env to that directory
Agents read:  --> tmux show-environment DOEY_RUNTIME | cut -d= -f2-
              --> source "${RUNTIME_DIR}/session.env"
```

### session.env Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `PROJECT_DIR` | `/Users/user/myproject` | Absolute path to project root |
| `PROJECT_NAME` | `myproject` | Sanitized project name |
| `SESSION_NAME` | `doey-myproject` | tmux session name |
| `GRID` | `6x2` | Grid layout (columns x rows) |
| `TOTAL_PANES` | `12` | Total pane count |
| `WORKER_COUNT` | `10` | Number of worker panes |
| `WATCHDOG_PANE` | `6` | Pane index of the Watchdog |
| `WORKER_PANES` | `1,2,3,4,5,7,8,9,10,11` | Comma-separated worker pane indices |
| `RUNTIME_DIR` | `/tmp/doey/myproject` | Path to runtime state directory |

### tmux-Provided Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `TMUX_PANE` | tmux (automatic) | Pane ID like `%0`, `%12`; unique per pane process |

### Claude Code-Provided Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `CLAUDE_PROJECT_DIR` | Claude Code | Project directory; used in hook command paths |
| `CLAUDECODE` | Claude Code | Set when running inside Claude Code |

### Feature Flags

| Variable | Value | Source | Description |
|----------|-------|--------|-------------|
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `1` | `~/.claude/settings.json` env | Enables Agent Teams feature |


## Layer 7: CLI Launch Flags

### Three Launch Patterns

**Manager (pane 0.0):**
```bash
claude --dangerously-skip-permissions --agent doey-manager
```

**Watchdog (pane 0.N where N = first pane in second row):**
```bash
claude --dangerously-skip-permissions --model haiku --agent doey-watchdog
```

**Workers (all remaining panes):**
```bash
claude --dangerously-skip-permissions --model opus \
  --append-system-prompt-file /tmp/doey/<name>/worker-system-prompt-<N>.md
```

### Flag Precedence

```
CLI flags  >  Agent definition frontmatter  >  Settings files
```

- `--model opus` on a worker overrides the global `model: opus` in settings
  (same value here, but explicit).
- `--model haiku` on Watchdog overrides its own frontmatter `model: haiku`
  (redundant but explicit).
- `--agent doey-manager` loads the agent definition, which sets model to opus.
  No CLI `--model` is given for Manager, so it uses the agent definition value.

### --dangerously-skip-permissions

All three instance types use this flag. It allows all tool calls without
user confirmation prompts. Combined with `skipDangerousModePermissionPrompt: true`
in global settings, the warning banner is also suppressed.

### --append-system-prompt-file

Workers do NOT use `--agent`. Instead, they use `--append-system-prompt-file`
to inject a per-worker system prompt that includes:
- Base worker rules (absolute paths, stay in scope, no git commits, etc.)
- Project context (name, root dir, runtime dir)
- Worker identity (worker number, pane index, session name)


## Layer 8: tmux Integration

### Session Structure

Default grid: 6x2 (6 columns, 2 rows = 12 panes).

```
+--------+--------+--------+--------+--------+--------+
|  0.0   |  0.1   |  0.2   |  0.3   |  0.4   |  0.5   |
|  MGR   |  W1    |  W2    |  W3    |  W4    |  W5    |
| Manager| Worker | Worker | Worker | Worker | Worker |
+--------+--------+--------+--------+--------+--------+
|  0.6   |  0.7   |  0.8   |  0.9   |  0.10  |  0.11  |
|  WDG   |  W6    |  W7    |  W8    |  W9    |  W10   |
|Watchdog| Worker | Worker | Worker | Worker | Worker |
+--------+--------+--------+--------+--------+--------+
```

Pane 0.0 is always the Manager. The Watchdog pane index equals the number of
columns (first pane of second row). All other panes are workers.

### Pane Detection

```bash
# Get this pane's identity (used in hooks)
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}')

# List all panes with metadata
tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_index} #{pane_title} #{pane_pid}'
```

### Bell Suppression

```bash
tmux set-option -t "$session" bell-action none
tmux set-option -t "$session" visual-bell off
```

Custom notifications are handled by `on-stop.sh` via `osascript` instead
of terminal bells, preventing notification spam from worker panes.

### Theme and Display Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| `pane-border-status` | `top` | Show pane titles above each pane |
| `pane-border-lines` | `heavy` | Thick border lines between panes |
| `pane-border-format` | Role-aware with color | Shows pane title; active pane in cyan bold |
| `status-position` | `top` | Status bar at top of terminal |
| `status-left` | Branded with session/project name | Cyan "DOEY: name" badge |
| `status-right` | Pane title + time + worker summary (NW/NI/NR) | Shows focused pane info; NW=working, NI=idle, NR=reserved. Reserved panes show RSV:Xs countdown or RESERVED badge |
| `set-titles` | `on` | Updates terminal tab title |
| `mouse` | `on` | Enables mouse for pane selection and scrolling |

### Communication Primitives

| Method | Use Case | Example |
|--------|----------|---------|
| `send-keys` | Short commands (< 200 chars) | `tmux send-keys -t "$SESSION_NAME:0.4" "task text" Enter` |
| `load-buffer` + `paste-buffer` | Long/multi-line tasks | Write to tempfile, `tmux load-buffer`, `tmux paste-buffer -t` |
| `capture-pane` | Read pane output | `tmux capture-pane -t "$SESSION_NAME:0.4" -p -S -80` |


## Layer 9: Runtime State

### Directory Tree

```
/tmp/doey/<project-name>/
  session.env                          # Session manifest (Layer 6)
  worker-system-prompt.md              # Base worker system prompt
  worker-system-prompt-1.md            # Per-worker prompt (base + identity)
  worker-system-prompt-2.md            # ...
  worker-system-prompt-N.md            # One per worker
  status/
    doey-<name>_0_0.status              # Manager status
    doey-<name>_0_1.status              # Worker 1 status
    doey-<name>_0_6.status              # Watchdog status
    doey-<name>_0_1.reserved           # Worker 1 reservation marker (optional)
    ...                                # One .status per pane; .reserved optional
  research/
    doey-<name>_0_4.task                # Research task marker (topic text)
    ...
  reports/
    doey-<name>_0_4.report              # Research report (written by worker)
    ...
  messages/
    ...                                # Inter-pane message files
  broadcasts/
    ...                                # Broadcast message files
  task_XXXXXX.txt                      # Temporary task files (created, used, deleted)
```

### Status File Format

Each status file contains 4 lines:

```
PANE: doey-myproject:0.4
UPDATED: 2026-03-10T14:23:01+01:00
STATUS: WORKING
TASK: Refactor hero-section component to use new design tokens
```

`STATUS` is `WORKING`, `IDLE`, or `RESERVED`. `TASK` contains the first 80
characters of the prompt (on UserPromptSubmit) or is empty (on Stop).

### Reservation File Format

Optional file at `${RUNTIME_DIR}/status/${PANE_SAFE}.reserved`. If present,
the pane is reserved. First line contains:
- `permanent` — reserved indefinitely until manually unreserved
- Unix timestamp (epoch seconds) — reserved until this time, auto-expires

Created by:
- `on-prompt-submit.sh` auto-reserve (60s) on human input to worker panes
- `/doey-reserve` command for permanent or timed reservations

Consumed by:
- `common.sh:is_reserved()` — checks if reservation is active
- `tmux-statusbar.sh` — displays RSV:Xs countdown or RESERVED badge
- Manager dispatch logic — skips reserved panes

### Research Lifecycle

1. Manager dispatches via `/doey-research` -- skill creates `research/<pane>.task` marker
2. Worker investigates using Agent subagents
3. Worker attempts to stop -- Stop hook sees `.task` but no `.report` -- exit 2 blocks
4. Worker writes report to `reports/<pane>.report`, stops again -- hook cleans up `.task`
5. Manager reads `reports/<pane>.report`

### Message Bus

Messages between panes use files in the `messages/` and `broadcasts/`
directories. The `/doey-send` and `/doey-broadcast` skills manage creation;
`/doey-inbox` reads them.

### Worker System Prompt Files

Each worker gets a unique system prompt file combining:
1. `worker-system-prompt.md` -- shared rules (absolute paths, stay in scope,
   no git commits, concurrent awareness, etc.)
2. Appended identity block -- worker number, pane index, session name

These files persist in the runtime directory for the session's lifetime.


## Layer 10: CLAUDE.md

**Status: Present.** `CLAUDE.md` exists in the project root and is loaded by
Claude Code into every instance's context (Manager, Watchdog, and all Workers).

**Contents:**
- Project overview and architecture (three agent roles, communication channels)
- Key directories (`agents/`, `commands/`, `.claude/hooks/`, `shell/`, `docs/`)
- Development conventions (frontmatter format, hook exit codes, shell conventions)
- Testing guidance (what to restart when changing agents, hooks, commands, launcher)
- Important file reference (`doey.sh`, hook scripts, `install.sh`)
- Link to this context reference document


## Complete Context Stacks

### Manager Context (load order)

```
 1. ~/.claude/settings.json                          (global settings)
 2. ~/.claude/settings.local.json                    (global local settings)
 3. .claude/settings.local.json                      (project hooks registration)
 4. agents/doey-manager.md frontmatter               (model=opus, memory=user)
 5. agents/doey-manager.md body                      (system prompt: 253 lines)
 6. ~/.claude/agent-memory/doey-manager/MEMORY.md    (persistent memory)
 7. CLI: --dangerously-skip-permissions --agent doey-manager
 8. tmux env: DOEY_RUNTIME -> session.env             (project/session context)
 9. Runtime: status/, research/, reports/             (live state)
10. Skills: loaded on-demand via /doey-*             (13 skills used)
```

### Watchdog Context (load order)

```
 1. ~/.claude/settings.json                          (global settings)
 2. ~/.claude/settings.local.json                    (global local settings)
 3. .claude/settings.local.json                      (project hooks registration)
 4. agents/doey-watchdog.md frontmatter              (model=haiku, memory=user)
 5. agents/doey-watchdog.md body                     (system prompt: 175 lines)
 6. ~/.claude/agent-memory/doey-watchdog/MEMORY.md   (persistent memory -- likely empty)
 7. CLI: --dangerously-skip-permissions --model haiku --agent doey-watchdog
 8. tmux env: DOEY_RUNTIME -> session.env             (session context)
 9. Runtime: reads pane output via capture-pane       (live state)
10. Skills: none (operates from agent definition)
```

### Worker Context (load order, for comparison)

```
 1. ~/.claude/settings.json                          (global settings)
 2. ~/.claude/settings.local.json                    (global local settings)
 3. .claude/settings.local.json                      (project hooks registration)
 4. No agent definition (workers don't use --agent)
 5. --append-system-prompt-file worker-system-prompt-N.md  (rules + identity)
 6. No persistent memory (workers don't have memory scope)
 7. CLI: --dangerously-skip-permissions --model opus
 8. tmux env: DOEY_RUNTIME -> session.env             (available but rarely used)
 9. Runtime: status/ (written by hooks)              (passive -- hooks write, worker doesn't read)
10. Skills: /doey-inbox, /doey-status (if invoked)
```


## Performance & Debugging Guide

### When the Manager Behaves Unexpectedly

| Symptom | Check |
|---------|-------|
| Manager tries to read/edit code itself | Memory file may lack delegation-first rules; check `~/.claude/agent-memory/doey-manager/MEMORY.md` |
| Manager uses wrong session name | Not reading manifest; verify `tmux show-environment DOEY_RUNTIME` returns valid path |
| Manager dispatches to Watchdog pane | `WATCHDOG_PANE` in session.env may be wrong; verify grid math |
| Manager sends empty tasks | `send-keys "" Enter` bug; check that task text is non-empty before the Enter keystroke |
| Manager gets no notifications on Stop | Check `on-stop.sh` is registered in `.claude/settings.local.json`; verify pane resolves to `0.0` |
| Manager waits for confirmation on safe tasks | Agent definition may have been modified; check delegation-first rules in body text |

### When the Watchdog Misbehaves

| Symptom | Check |
|---------|-------|
| Watchdog stops monitoring | Stop hook keep-alive may be failing; check `WATCHDOG_PANE` in session.env matches actual pane index |
| Watchdog spams notifications | State tracking lost after context compression; rate limiting (60s cap) should catch this |
| Watchdog auto-accepts dangerous prompts | Review safety rules in agent definition; pattern matching may be too broad |
| Watchdog ignores prompts | Pane capture may not include the prompt line; check `-S -15` range |
| Watchdog runs on wrong model | Verify `--model haiku` in launch command in `doey.sh` |

### Common Issues

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Wrong model on any instance | CLI flag missing or overridden | Check launch commands in `doey.sh` |
| Hooks not firing | Settings file not in correct location | Verify `.claude/settings.local.json` exists in project root |
| All panes think they're Manager | Hook using bare `tmux display-message` without `-t "$TMUX_PANE"` | Fixed in current version; verify hook uses `$TMUX_PANE` |
| Notification spam | Watchdog notifications + hook notifications both active | Hooks only notify for Manager (pane 0.0); Watchdog notifies for workers |
| Stale memory causing bad behavior | Outdated patterns in MEMORY.md | Review and clean `~/.claude/agent-memory/doey-manager/MEMORY.md` |
| Research worker stops without report | Hook not installed or not blocking | Check exit code 2 path in `on-stop.sh`; verify `.task` file was created |
| Workers don't pick up hook changes | Hooks load at Claude Code startup | Restart workers via `/doey-restart-workers` |
| Manager dispatches to reserved pane | `.reserved` file missing or hooks not running | Check `.reserved` file exists in `status/` dir; verify hooks are running and `is_reserved()` returns correctly |

### How to Trace Which Layer Caused a Behavior

1. **Is it in the system prompt?** Check agent definition body text.
2. **Is it from memory?** Check `~/.claude/agent-memory/<agent>/MEMORY.md`.
3. **Is it a settings issue?** Dump merged settings: check all 4 files in merge order.
4. **Is it a hook issue?** Add `echo "DEBUG: ..." >&2` to the relevant `on-*.sh` hook and watch stderr.
5. **Is it a skill issue?** Read the skill file in `commands/`; skills compose with agent context.
6. **Is it an environment issue?** Check `session.env` and `tmux show-environment`.
7. **Is it a runtime state issue?** Inspect files in `/tmp/doey/<name>/`.
8. **Is it a CLI flag issue?** Check the exact launch command in `doey.sh`.
