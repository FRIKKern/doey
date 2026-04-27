# Configuration Reference

## Overview

Doey uses `DOEY_*` environment variables for all configuration. Variables follow a layered override chain so you can set global defaults and override per-project. No configuration is required — sensible defaults are built in.

## Configuration Override Chain

Settings are resolved in this order (last wins):

1. **Hardcoded defaults** — `_doey_load_config()` in `shell/doey.sh`, using `${VAR:-default}` pattern
2. **Global config** — `~/.config/doey/config.sh` (sourced first by `_doey_load_config()`)
3. **Project config** — `.doey/config.sh` (found by walking up from `pwd`; sourced second, overrides global)
4. **Startup wizard** — `doey-tui setup` outputs JSON that sets `DOEY_TEAM_COUNT` + per-team vars, overriding the legacy team variables
5. **Environment variables** — any `DOEY_*` var already exported in your shell takes precedence over hardcoded defaults but is overwritten by sourced config files

Config is loaded twice: once at script start in `_doey_load_config()` and again after `cd` into the project directory during `launch_session_dynamic()`.

**Config files are optional.** Create one with `doey config --reset` or `doey init`. The template lives at `shell/doey-config-default.sh`.

## Core Variables

### Grid & Team Sizing

| Variable | Default | Type | Description |
|---|---|---|---|
| `DOEY_INITIAL_WORKER_COLS` | `3` | integer | Worker columns per team (each column = 2 workers) |
| `DOEY_INITIAL_TEAMS` | `0` | integer | Number of managed teams to create at startup |
| `DOEY_INITIAL_WORKTREE_TEAMS` | `0` | integer | (Opt-in) Teams launched in isolated git worktrees. Ignored unless `DOEY_WORKTREE_OPT_IN=1` is also set; default flow stays on the session's starting branch and never auto-creates branches. |
| `DOEY_WORKTREE_OPT_IN` | `0` | boolean | Master switch for worktree/branch automation. Worktrees are never created by default — set this to `1` to allow `DOEY_INITIAL_WORKTREE_TEAMS` and `DOEY_TEAM_<N>_TYPE=worktree` to take effect. |
| `DOEY_INITIAL_FREELANCER_TEAMS` | `0` | integer | Managerless freelancer pools to create |
| `DOEY_MAX_WORKERS` | `20` | integer | Hard cap on total worker panes across all teams |

Initial workers per team = `DOEY_INITIAL_WORKER_COLS * 2`. With the default of 3, each team starts with 6 workers.

### Timing

Defaults are conservative to avoid Claude API rate-limit errors on session start. Lower only if your account has high rate limits and you need faster boots.

| Variable | Default | Type | Description |
|---|---|---|---|
| `DOEY_WORKER_LAUNCH_DELAY` | `1` | seconds | Delay between launching individual workers |
| `DOEY_TEAM_LAUNCH_DELAY` | `2` | seconds | Delay between launching teams |
| `DOEY_MANAGER_LAUNCH_DELAY` | `1` | seconds | Delay before launching a team's Subtaskmaster |
| `DOEY_MANAGER_BRIEF_DELAY` | `2` | seconds | Delay before sending the Subtaskmaster its initial brief |

### Models

| Variable | Default | Type | Description |
|---|---|---|---|
| `DOEY_MANAGER_MODEL` | `opus` | string | Claude model for Subtaskmasters |
| `DOEY_WORKER_MODEL` | `opus` | string | Claude model for Workers |
| `DOEY_TASKMASTER_MODEL` | `opus` | string | Claude model for the Taskmaster |

### Idle Management

| Variable | Default | Type | Description |
|---|---|---|---|
| `DOEY_IDLE_COLLAPSE_AFTER` | `60` | seconds | Collapse idle worker panes after this duration |
| `DOEY_IDLE_REMOVE_AFTER` | `300` | seconds | Remove idle worker panes after this duration |

### Dashboard & Monitoring

| Variable | Default | Type | Description |
|---|---|---|---|
| `DOEY_INFO_PANEL_REFRESH` | `300` | seconds | Info panel auto-refresh interval |
| `DOEY_PASTE_SETTLE_MS` | `500` | ms | Settle time after tmux paste operations |

### Remote Access

| Variable | Default | Type | Description |
|---|---|---|---|
| `DOEY_TUNNEL_ENABLED` | `false` | boolean | Enable remote tunnel access |
| `DOEY_TUNNEL_PROVIDER` | `auto` | string | Tunnel provider selection |
| `DOEY_TUNNEL_PORTS` | *(empty)* | string | Ports to expose via tunnel |
| `DOEY_TUNNEL_DOMAIN` | *(empty)* | string | Custom tunnel domain |

## Per-Team Advanced Configuration

When `DOEY_TEAM_COUNT` is set, it replaces the legacy `DOEY_INITIAL_TEAMS` / `DOEY_INITIAL_WORKTREE_TEAMS` / `DOEY_INITIAL_FREELANCER_TEAMS` variables entirely. Each team is configured individually:

| Variable Pattern | Values | Description |
|---|---|---|
| `DOEY_TEAM_COUNT` | integer | Total number of teams to create |
| `DOEY_TEAM_<N>_TYPE` | `local`, `worktree`, `freelancer`, `premade` | Team isolation mode. `worktree` requires `DOEY_WORKTREE_OPT_IN=1`; otherwise it is silently downgraded to `local` (stays on the session's starting branch — usually `main`, never default). |
| `DOEY_TEAM_<N>_WORKERS` | integer | Worker count for this team |
| `DOEY_TEAM_<N>_NAME` | string | Human-readable team name |
| `DOEY_TEAM_<N>_ROLE` | string | Specialization hint (injected into agent prompts) |
| `DOEY_TEAM_<N>_WORKER_MODEL` | model name | Per-team worker model override |
| `DOEY_TEAM_<N>_MANAGER_MODEL` | model name | Per-team Subtaskmaster model override |
| `DOEY_TEAM_<N>_DEF` | def name | Team definition file (for `premade` type) |

`<N>` is 1-indexed (first team is `DOEY_TEAM_1_TYPE`, etc.).

When the startup wizard is used, it sets `DOEY_TEAM_COUNT` and per-team vars, then forces `DOEY_INITIAL_TEAMS=0` and `DOEY_INITIAL_FREELANCER_TEAMS=0` so the legacy path is skipped.

## CLI Flags & Commands

### Startup Flags

| Flag | Effect |
|---|---|
| `doey --quick` / `-q` | Skip wizard, use minimal defaults: 1 team, 1 column (2 workers), 0 freelancers |
| `doey --no-wizard` | Skip the TUI setup wizard, use config/defaults directly |

### Post-Startup Commands

| Command | Effect |
|---|---|
| `doey add` | Add 1 worker column (2 workers) to team 1 |
| `doey add-window` | Add a new team window (default 4x2 static grid) |
| `doey add-window --grid 3x2` | Add a dynamic team with 3 worker columns |
| `/doey-worktree <window>` | Opt-in: isolate an existing team window in a git worktree. The default `add-window` path stays on the session's starting branch (usually `main`); worktrees are never the default. |
| `doey add-window --type freelancer` | Add a managerless freelancer pool |
| `doey add-team <name>` | Spawn a team from a `.team.md` definition file |

### Config Management

| Command | Effect |
|---|---|
| `doey config` | Edit project config (falls back to global if no project config) |
| `doey config --show` | Display current config values and load chain |
| `doey config --global` | Edit global config |
| `doey config --reset` | Reset config to template defaults |

## Key Functions Reference

| Function | Purpose |
|---|---|
| `_doey_load_config()` | Loads global then project `config.sh`. Project config overrides global. Uses directory walk-up to find `.doey/config.sh` |
| `launch_session_dynamic()` | Main startup path. Creates tmux session, dashboard window (Boss + Subtaskmaster), team 1 grid, then spawns extra teams in background |
| `add_dynamic_team_window()` | Creates a new team window with a Subtaskmaster pane + N worker columns. Used by `doey add-window --grid` |
| `doey_add_column()` | Adds 2 worker panes (1 column) to an existing dynamic team window. Used by `doey add` |
| `_read_team_config()` | Reads `DOEY_TEAM_<N>_<PROP>` with a fallback default value |
| `write_team_env()` | Writes per-team env file (`team_<N>.env`) to the runtime directory |
| `doey_config()` | Implements the `doey config` subcommand (show/edit/reset) |

## Examples

### Minimal setup

```bash
doey --quick
```

Starts with 1 team, 1 worker column (2 workers), no freelancers. Skips the wizard entirely.

### Standard launch

```bash
doey
```

Opens the TUI wizard where you choose team count, types, and worker counts interactively.

### Large team via config.sh

In `.doey/config.sh`:

```bash
DOEY_INITIAL_WORKER_COLS=4
DOEY_INITIAL_TEAMS=3
DOEY_INITIAL_FREELANCER_TEAMS=2
DOEY_MAX_WORKERS=30
DOEY_WORKER_LAUNCH_DELAY=2
```

This creates 3 managed teams (8 workers each) + 2 freelancer pools = 5 team windows.

### Worktree isolation team (opt-in)

The default `doey add-window` flow stays on the session's starting branch — usually `main`, never default. Worktrees are explicit, opt-in only:

```bash
/doey-worktree <window-index>
```

This isolates the named team window after it has been created. To also enable worktree-typed teams in `DOEY_TEAM_<N>_TYPE` or the legacy `DOEY_INITIAL_WORKTREE_TEAMS` count, set `DOEY_WORKTREE_OPT_IN=1` in your config.

### Freelancer pool

```bash
doey add-window --type freelancer
```

Adds a managerless team of independent workers for ad-hoc tasks.

### Per-team customization

In `.doey/config.sh`:

```bash
DOEY_TEAM_COUNT=3

DOEY_TEAM_1_TYPE=local
DOEY_TEAM_1_WORKERS=6
DOEY_TEAM_1_NAME="Backend"
DOEY_TEAM_1_ROLE="API and database work"
DOEY_TEAM_1_WORKER_MODEL=sonnet

DOEY_TEAM_2_TYPE=local
DOEY_TEAM_2_WORKERS=4
DOEY_TEAM_2_NAME="Frontend"
DOEY_TEAM_2_ROLE="React components and styling"

DOEY_TEAM_3_TYPE=freelancer
DOEY_TEAM_3_WORKERS=2
DOEY_TEAM_3_NAME="Research"
```

This creates three specialized teams: a 6-worker backend team (using Sonnet for cost efficiency), a 4-worker frontend team, and a 2-worker freelancer research pool. All three stay on the session's starting branch (usually `main`); to put a team in an isolated worktree later, run `/doey-worktree <window>` (or set `DOEY_WORKTREE_OPT_IN=1` and `DOEY_TEAM_2_TYPE=worktree` to opt that team in at startup).
