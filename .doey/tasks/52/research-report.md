# Doey Spawn Path Optimization Report

**Date:** 2026-03-30
**Scope:** Full analysis of session/team/pane spawning in `shell/doey.sh`
**Goal:** Identify every bottleneck, rank by impact, propose optimizations

---

## 1. Current Spawn Timeline

The following traces the **dynamic grid** path (`launch_session_dynamic`), which is the default and most common launch mode. Default config: 2 initial worker columns (4 workers), 2 teams, 1 freelancer team.

### Phase 1: Pre-Session Setup

| Step | Function | What Happens | Est. Time |
|------|----------|-------------|-----------|
| 1 | `_doey_load_config()` :47 | Walk up dirs to find `.doey/config.sh`, source global + project configs | ~5ms |
| 2 | `check_claude_auth()` :1473 | Runs `claude auth status` (forks Claude CLI, network check) | **200-500ms** |
| 3 | Wizard check :2861 | `command -v doey-tui` + `doey-tui setup` (Go binary, interactive UI) | 0-10s (user) |
| 4 | `_print_full_banner()` :1686 | Printf banner art | ~1ms |
| 5 | `ensure_project_trusted()` :1028 | Read/write `~/.claude/settings.json` with jq | ~20ms |
| 6 | `install_doey_hooks()` :135 | `cp` hooks + skills + settings.local.json to project dir | ~50-100ms |

**Subtotal:** ~300-650ms (excluding wizard interaction)

### Phase 2: Session & Dashboard Creation

| Step | Function | Line | What Happens | Est. Time |
|------|----------|------|-------------|-----------|
| 7 | `_init_doey_session()` :2804 | Kill old session, clean runtime dir, `tmux new-session`, write env files, settings overlay, task sync | ~50-100ms |
| 8 | Write `session.env` :2928 | `cat > session.env` with project manifest | ~2ms |
| 9 | `_detect_project_type()` :203 | Check for package.json, go.mod, Cargo.toml etc. | ~10ms |
| 10 | `write_team_env()` :250 | Write `team_1.env` | ~2ms |
| 11 | `setup_dashboard()` :565 | 2x `split-window`, 3x `select-pane -T`, `send-keys` x3 (info-panel, Boss, SM) | ~30-50ms |
| 12 | `tmux new-window` :2985 | Create team 1 window | ~5ms |
| 13 | `select-pane -T`, `rename-window` :2986-2987 | Name manager pane and window | ~10ms |

**Subtotal:** ~110-180ms

### Phase 3: Theme Application

| Step | Function | Line | What Happens | Est. Time |
|------|----------|------|-------------|-----------|
| 14 | `apply_doey_theme()` :1019 | Sources `tmux-theme.sh` which runs **~25 individual tmux commands** (set-option, set-window-option, bind-key) | **~75-125ms** |

Each `tmux set-option` call: fork tmux binary (~2-3ms) + socket IPC (~1ms) = ~3-5ms. 25 calls = 75-125ms.

**Subtotal:** 75-125ms

### Phase 4: Manager Launch

| Step | Function | Line | What Happens | Est. Time |
|------|----------|------|-------------|-----------|
| 15 | `_launch_team_manager()` :3554 | `generate_team_agent` (cp + sed agent file), build command, `send-keys`, `select-pane -T` | ~20ms |
| 16 | **`sleep 0.2`** :3566 | Hardcoded sleep after manager launch | **200ms** |
| 17 | `write_pane_status()` :3567 | Write status file | ~2ms |
| 18 | `_brief_team()` :3570 | Spawns background subshell with **`sleep $DOEY_MANAGER_BRIEF_DELAY`** (default **8s**) then sends briefing via `send-keys` | 0ms (async) |

**Subtotal:** ~222ms (0.2s sleep dominates)

### Phase 5: Worker Column Creation (2 columns = 4 workers)

Each call to `doey_add_column()` :3365 does:

| Step | What | Est. Time |
|------|------|-----------|
| `_read_team_state()` :3250 | Read team env, list panes | ~15ms |
| `tmux display-message` :3382 | Get window width | ~5ms |
| `tmux list-panes` :3385 | Count current panes | ~5ms |
| `tmux split-window -h` :3402 | Create top pane | ~5ms |
| `tmux split-window -v` :3403 | Create bottom pane | ~5ms |
| `tmux select-pane -T` x2 :3408-3409 | Name new panes | ~10ms |
| `rebuild_pane_state()` :3413 | List panes, rebuild CSV | ~10ms |
| `write_team_env()` :3416 | Update team env file | ~5ms |
| `_batch_boot_workers()` :3418 | Prepare prompt files (2x `cp` + `printf`), 2x `send-keys`, 2x `write_pane_status`, **`sleep $DOEY_WORKER_LAUNCH_DELAY`** (default **3s**) | **~3.05s** |
| `rebalance_grid_layout()` :3419 | Complex custom layout calculation + `tmux move-pane`/`resize-pane` calls | ~50-100ms |

Per column: ~3.15-3.20s (dominated by the 3s worker launch delay)

| Sub-step | Line | Time |
|----------|------|------|
| **`sleep 0.2`** before columns | :2998 | **200ms** |
| Column 1 | doey_add_column | **~3.15s** |
| **`sleep 0.3`** between columns | :3002 | **300ms** |
| Column 2 | doey_add_column | **~3.15s** |

**Subtotal: ~6.8s** (for 2 columns, 4 workers)

### Phase 6: Additional Teams (default: 1 more team + 1 freelancer)

Each `add_dynamic_team_window()` :3827 for a regular team:

| Step | What | Est. Time |
|------|------|-----------|
| `tmux new-window` :3843 | Create window | ~5ms |
| `write_team_env()` :3869 | Write team env | ~5ms |
| `_name_team_window()` :3870 | 5x tmux calls (border theme) | ~25ms |
| `_register_team_window()` :3871 | Lock + sed session.env | ~15ms |
| `_ensure_worker_prompt()` :3872 | Check/write prompt file | ~5ms |
| `_launch_team_manager()` :3925 | Launch manager, **sleep 0.2** | ~220ms |
| 2x `doey_add_column()` :3937-3939 | Same as Phase 5 | **~6.5s** |
| `_build_worker_pane_list()` :3942 | List panes | ~10ms |
| `_brief_team()` :3950 | Async briefing (sleep 8 in bg) | 0ms |
| **`sleep $DOEY_TEAM_LAUNCH_DELAY`** :3087 | Between teams (default **15s**) | **15s** |

Per team: ~6.8s + 15s between = ~21.8s

For freelancer team `add_dynamic_team_window()` with `is_freelancer=true`:
| Step | What | Est. Time |
|------|------|-----------|
| Pane 0 worker launch + **`sleep $DOEY_WORKER_LAUNCH_DELAY`** :3897 | **3s** |
| Split + pane 1 launch + **`sleep $DOEY_WORKER_LAUNCH_DELAY`** :3919 | **3s** |
| 2x `doey_add_column()` :3937 | **~6.5s** |
| No inter-team sleep (last team) | 0s |

Per freelancer team: ~12.5s

### Phase 7: Boss & SM Briefing

| Step | Line | What | Est. Time |
|------|------|------|-----------|
| Background subshell :3132 | **`sleep $DOEY_MANAGER_BRIEF_DELAY`** (8s), then `send-keys` to Boss + SM | 0ms (async, fires ~8s after Phase 4) |

### Phase 8: Final Output & Attach

| Step | What | Est. Time |
|------|------|-----------|
| Count team windows :3126-3130 | Read team windows | ~10ms |
| Print summary :3142-3156 | Printf | ~1ms |
| `attach_or_switch()` :1050 | Attach user to session | ~5ms |

**Subtotal:** ~16ms

---

### Total Wall-Clock Time (Default Config: 2 teams + 1 freelancer, 2 cols each)

| Phase | Duration | % of Total |
|-------|----------|------------|
| Pre-session setup | ~500ms | 1% |
| Session + Dashboard | ~150ms | <1% |
| Theme | ~100ms | <1% |
| Team 1 Manager | ~222ms | <1% |
| Team 1 Workers (2 cols) | **~6.8s** | 14% |
| Team 2 (full) | **~6.8s** | 14% |
| Inter-team delay (T1->T2) | **~15s** | 31% |
| Freelancer team | **~12.5s** | 26% |
| Inter-team delay (T2->FL) | **~15s** | 31% |
| Final + attach | ~16ms | <1% |

**Estimated total: ~42-50 seconds**

With just 1 team (quick mode: `DOEY_QUICK=true`): **~7-8 seconds**

---

## 2. Identified Bottlenecks (Ranked by Time Impact)

### B1: Inter-Team Launch Delays (CRITICAL)
- **Impact:** 15s per additional team = **30s for 2 extra teams**
- **Evidence:** `DOEY_TEAM_LAUNCH_DELAY` default 15s, used at lines 3050, 3057, 3087, 3101, 3116
- **Reason:** "Serialize team launches to prevent concurrent OAuth token requests" (comment at :3081)
- **Reality:** Claude instances authenticate asynchronously via `send-keys`. The 15s sleep is a blunt guard against API rate limits during token acquisition, but authentication happens when Claude CLI starts, not when `send-keys` fires.

### B2: Worker Launch Delay per Batch (HIGH)
- **Impact:** 3s per `_batch_boot_workers` call = **~12-15s total** across all teams
- **Evidence:** `DOEY_WORKER_LAUNCH_DELAY` default 3s, used at line 3361, 3786, 3897, 3919
- **Reason:** Auth stagger — prevent rate-limiting on simultaneous Claude auth
- **Improvement:** Already optimized from O(N) to O(1) (one sleep per batch instead of per worker), but the 3s is still conservative

### B3: Freelancer Team Sequential Worker Launch (HIGH)
- **Impact:** ~6s for first 2 freelancers (2x `DOEY_WORKER_LAUNCH_DELAY`)
- **Evidence:** Lines 3891-3919 — F0 launched, sleep 3s, F1 launched, sleep 3s
- **Reason:** Manual sequential launch instead of using `_batch_boot_workers`
- **Note:** This is a regression — `_batch_boot_workers` already solves this with O(1) sleep, but freelancer base panes (F0, F1) don't use it

### B4: Manager Brief Delay (MEDIUM)
- **Impact:** 8s per team (async, but delays first task dispatch)
- **Evidence:** `DOEY_MANAGER_BRIEF_DELAY` default 8s at lines 3133, 3577, 1616
- **Reason:** Wait for Claude to finish loading before sending the initial briefing prompt
- **Note:** Non-blocking (runs in background subshell), but means managers aren't productive for ~8s after launch

### B5: Tmux Command Overhead — Theme (LOW-MEDIUM)
- **Impact:** ~75-125ms
- **Evidence:** `tmux-theme.sh` makes 25+ individual `tmux set-option` calls, each forking tmux binary
- **Fix complexity:** Low — batch via `source-file`

### B6: Small Sleeps Scattered Throughout (LOW)
- **Impact:** ~2-3s total across all phases
- **Evidence:**
  - `sleep 0.2` after manager launch (:3566) — 200ms x N teams
  - `sleep 0.3` between worker columns (:3002, :3939) — 300ms x (cols-1) x N teams
  - `sleep 0.1` after freelancer split (:3901) — 100ms
  - `sleep 0.5` in grid verification (:1585) — 500ms (static grid only)
  - `sleep 0.3` in add_team_window (:3995) — 300ms (static grid only)
  - `sleep 0.5` in doey-add-window skill (:step 2) — 500ms per invocation
- **Reason:** Most are "tmux settle" delays — waiting for tmux to finish creating panes before querying state
- **Reality:** tmux commands are synchronous. The server processes them before returning. These are mostly unnecessary.

### B7: `generate_team_agent()` File Operations (LOW)
- **Impact:** ~10ms per team (cp + sed)
- **Evidence:** Line 284 — copies agent file, runs sed to rename
- **Note:** Trivial but avoidable — could template in memory

### B8: `install_doey_hooks()` Repeated for Worktrees (LOW)
- **Impact:** ~50-100ms per worktree team
- **Evidence:** Line 3859 — full cp of hooks + skills for each worktree team dir
- **Note:** Necessary for correctness but could be parallelized

### B9: `on-session-start.sh` Per-Pane Overhead (LOW)
- **Impact:** ~30-50ms per pane startup (runs when each Claude instance starts)
- **Evidence:** Full hook at lines 1-167 — reads env files, determines role, writes status/role files, syncs skills (with lock contention at :106-119), writes env vars, sets pane title
- **Critical detail:** Skill sync uses mkdir lock (:106) — contention between simultaneous pane starts. Losing panes do `sleep 1` (:118)

### B10: `rebalance_grid_layout()` Complexity (LOW)
- **Impact:** ~50-100ms per call, called after every column addition
- **Evidence:** Line 3184 — reads window dimensions, iterates all panes, calculates custom layout, issues move-pane/resize-pane commands
- **Note:** Could batch tmux commands via source-file

---

## 3. Proposed Optimizations (Ranked by Effort vs Impact)

### Impact/Effort Matrix

```
HIGH IMPACT
    |
    |  [O1] Reduce inter-team     [O3] Attach early,
    |       delay                        build behind
    |
    |  [O2] Freelancer batch      [O6] Pre-warm during
    |       boot fix                    wizard
    |
    |  [O4] Reduce worker         [O8] source-file
    |       launch delay                batching
    |
    |  [O5] Eliminate small       [O7] split-window
    |       sleeps                      with command arg
    |
LOW IMPACT
    +-------------------------------------
     LOW EFFORT                HIGH EFFORT
```

### O1: Reduce Inter-Team Launch Delay (HIGH impact, LOW effort)

**Current:** `DOEY_TEAM_LAUNCH_DELAY=15` seconds between each team.

**Proposal:** Reduce default to 5s. The 15s was set conservatively for API rate limits, but workers already use `_batch_boot_workers` which has its own 3s delay. By the time team N+1's manager starts authenticating, team N's workers have already completed their auth window.

**Estimated savings:** 20s (from 30s to 10s for 2 extra teams)

**Risk:** May hit rate limits on accounts with low API limits. Mitigate by keeping the config variable user-tunable.

**Changes:** Line 75 — change default from 15 to 5.

### O2: Fix Freelancer Sequential Launch (HIGH impact, LOW effort)

**Current:** Freelancer F0 and F1 are launched individually with manual sleep between each (lines 3891-3919, ~6s total).

**Proposal:** Refactor to use `_batch_boot_workers` for F0+F1, same as regular workers. This gives O(1) sleep instead of O(N).

**Estimated savings:** 3s per freelancer team (from 6s to 3s)

**Risk:** Minimal — `_batch_boot_workers` already handles freelancer status marking.

**Changes:** Lines 3875-3923 — replace manual F0/F1 launch with split-window + `_batch_boot_workers`.

### O3: Attach Early, Build Teams Behind (HIGH impact, MEDIUM effort)

**Current:** User waits for ALL teams to be created before seeing the session.

**Proposal:** After dashboard + team 1 are ready, immediately attach the user to the session. Spawn additional teams in a background subshell.

```bash
# After team 1 is complete:
tmux select-window -t "$session:0"
attach_or_switch "$session"  # User is in!

# Background: spawn remaining teams
(
  for team in remaining_teams; do
    add_dynamic_team_window "$session" ...
    sleep $DOEY_TEAM_LAUNCH_DELAY
  done
) &
```

**Estimated savings:** User perceived latency drops from ~42s to ~8s. Teams still take the same total time but user is interactive immediately.

**Risk:** Medium — user might try to use teams that aren't ready yet. Mitigate with dashboard showing "Team 2: launching..." status. Boss/SM need to know which teams are available.

**Changes:** Restructure `launch_session_dynamic` to split into immediate (dashboard+T1) and deferred (T2+) phases.

### O4: Reduce Worker Launch Delay (MEDIUM impact, LOW effort)

**Current:** `DOEY_WORKER_LAUNCH_DELAY=3` — 3s sleep after each batch boot.

**Proposal:** Reduce to 1s for the batch case (where all workers are sent keys simultaneously and only one sleep follows). The stagger between individual `send-keys` calls within `_batch_boot_workers` is already 0ms.

**Estimated savings:** ~8s total (4 batch boots x 2s savings)

**Risk:** Rate limit on accounts with low limits. The batch pattern means all workers authenticate near-simultaneously regardless of the post-sleep. The sleep only gates the *next* batch.

**Changes:** Line 74 — change default from 3 to 1. Or better: use 1s for within-team batches, keep 3s for inter-team.

### O5: Eliminate Unnecessary Small Sleeps (MEDIUM impact, LOW effort)

**Specific sleeps to remove/reduce:**

| Sleep | Line | Current | Proposed | Savings | Justification |
|-------|------|---------|----------|---------|---------------|
| After manager launch | 3566 | 0.2s | 0s | 0.2s/team | tmux send-keys is synchronous |
| Between columns | 3002, 3939 | 0.3s | 0s | 0.3s/col | No reason to wait; next column doesn't depend on previous |
| Before columns | 2998 | 0.2s | 0s | 0.2s | tmux commands are sync |
| After freelancer split | 3901 | 0.1s | 0s | 0.1s | split-window returns after completion |
| Column removal settle | 3471, 3481 | 0.5s each | 0.1s | 0.8s | Only during remove, not critical path |

**Estimated savings:** ~1.5-2s across full launch

**Risk:** Very low — tmux commands are server-side synchronous. The client doesn't return until the server has processed the command.

### O6: Pre-warm During Wizard (HIGH impact, MEDIUM effort)

**Current:** Wizard runs, user makes choices, THEN session creation begins.

**Proposal:** While the wizard UI is showing, start creating the tmux session, dashboard, and theme in a background process. When wizard returns, skip the already-completed steps.

```bash
# Start pre-warming in background
(
  _init_doey_session "$session" "$runtime_dir" "$dir" "$name"
  setup_dashboard "$session" "$dir" "$runtime_dir" 1
  apply_doey_theme "$session" "$name" "$border_fmt" 2
) &
_PREWARM_PID=$!

# Run wizard (blocking)
_wizard_out="$(doey-tui setup 2>/dev/null)" || true

# Wait for prewarm to finish (usually already done)
wait $_PREWARM_PID 2>/dev/null || true
```

**Estimated savings:** ~300-500ms (overlaps pre-session setup with user interaction)

**Risk:** Medium — wizard might change team count, which affects dashboard layout. Mitigate by only pre-warming the session and dashboard (these don't depend on team configuration).

### O7: Use `split-window` with Command Argument (MEDIUM impact, MEDIUM effort)

**Current:** Create pane with `split-window`, then launch process with `send-keys`.

**Proposal:** Use `split-window 'claude --dangerously-skip-permissions ...'` to combine pane creation and process launch. Set `remain-on-exit on` per team window for crash visibility.

**Benefit:** Eliminates one tmux command per pane (~3-5ms each) and removes timing dependency between pane creation and process launch.

**Estimated savings:** ~20-50ms per team (small per-call savings but many calls)

**Risk:** If Claude crashes, pane shows as dead (mitigated by `remain-on-exit`). The `send-keys` approach is more forgiving of shell state.

### O8: Batch Tmux Commands via `source-file` (MEDIUM impact, MEDIUM effort)

**Current:** Each tmux operation is a separate process fork.

**Proposal:** For sequences of tmux commands (theme, grid creation, pane naming), generate a temp file and use `tmux source-file`.

Example for theme:
```bash
local _theme_file=$(mktemp)
cat > "$_theme_file" << EOF
set-option -t $session pane-border-status top
set-option -t $session pane-border-format "$pane_border_fmt"
# ... all 25 theme commands
EOF
tmux source-file "$_theme_file"
rm "$_theme_file"
```

Example for grid creation:
```bash
local _grid_file=$(mktemp)
for pane in ...; do
  echo "split-window -v -t $session:$window.0 -c $dir" >> "$_grid_file"
done
echo "select-layout -t $session:$window even-vertical" >> "$_grid_file"
tmux source-file "$_grid_file"
rm "$_grid_file"
```

**Estimated savings:**
- Theme: ~60-100ms (24 fewer forks)
- Grid: ~20-50ms per window
- Worker send-keys: ~15-30ms per batch

**Risk:** Low — `source-file` is a well-supported tmux feature. Debugging is slightly harder (no per-command error visibility). Use `-v` flag during development.

### O9: Skill Sync Lock Contention Fix (LOW impact, LOW effort)

**Current:** `on-session-start.sh` line 106 uses `mkdir` lock for skill sync. Losing panes sleep 1s.

**Proposal:** Only sync skills once per session start (not per pane). Move skill sync to `_init_doey_session` or make it idempotent without locking (use atomic mv instead).

**Estimated savings:** Up to 1s for panes that lose the lock race

**Risk:** Low

### O10: Parallelize Multi-Window Team Creation (HIGH impact, HIGH effort)

**Current:** Teams are created strictly sequentially with `DOEY_TEAM_LAUNCH_DELAY` between each.

**Proposal:** Create all team windows (tmux structures) in parallel since they're in separate windows with independent pane trees. Only stagger the Claude process launches.

```bash
# Phase 1: Create all windows + grids in parallel (fast)
for team in teams; do
  tmux new-window ...
  # split panes, name them, write env
done

# Phase 2: Launch Claude processes with stagger
for team in teams; do
  _launch_team_manager ...
  _batch_boot_workers ...
  sleep $DOEY_WORKER_LAUNCH_DELAY  # Only delay between teams, not structure creation
done
```

**Estimated savings:** ~2-5s by overlapping structural creation

**Risk:** Medium — file I/O for env files might race. Use atomic writes (already done via mv pattern).

---

## 4. Recommended Approach

### Phase 1: Quick Wins (1-2 hours, saves ~25s)

1. **O1** — Reduce `DOEY_TEAM_LAUNCH_DELAY` default from 15 to 5 (one-line change at :75)
2. **O5** — Remove 6 unnecessary sleeps (lines 2998, 3002, 3566, 3901, 3939 — guard with comments explaining why removed)
3. **O4** — Reduce `DOEY_WORKER_LAUNCH_DELAY` default from 3 to 1 (line :74)

### Phase 2: Structural Improvements (2-4 hours, saves ~6-10s + perceived latency)

4. **O2** — Refactor freelancer F0/F1 launch to use `_batch_boot_workers`
5. **O3** — Attach early, build remaining teams in background
6. **O8** — Convert `tmux-theme.sh` to `source-file` batching

### Phase 3: Advanced Optimizations (4-8 hours, marginal gains)

7. **O6** — Pre-warm during wizard
8. **O10** — Parallel window structural creation
9. **O7** — `split-window` with command argument
10. **O9** — Fix skill sync lock contention

### Expected Results

| Scenario | Current | After Phase 1 | After Phase 2 | After Phase 3 |
|----------|---------|---------------|---------------|---------------|
| 1 team, 2 cols | ~8s | ~5s | ~4s | ~3s |
| 2 teams + 1 FL (default) | ~42-50s | ~20-25s | ~8s perceived | ~5s perceived |
| 4 teams | ~75-90s | ~40-50s | ~10s perceived | ~7s perceived |

---

## 5. Risks and Tradeoffs

### Rate Limiting (O1, O4)
- **Risk:** Reducing delays may cause API auth failures on accounts with low rate limits
- **Mitigation:** Keep values configurable via `DOEY_*` env vars. Add exponential backoff on auth failure detection rather than pre-emptive sleeping. Document the config knobs.

### Early Attach (O3)
- **Risk:** User sees incomplete state — teams listed as "launching" in dashboard
- **Mitigation:** Dashboard already polls status files. Add "launching" state to team status display. Boss/SM should be briefed with "N teams planned, M ready" instead of waiting for all.
- **Risk:** Background team creation may fail silently
- **Mitigation:** Write failure status to runtime dir, display in dashboard

### Source-file Batching (O8)
- **Risk:** Harder to debug per-command failures
- **Mitigation:** Use `source-file -v` in debug mode. Keep temp files in `/tmp/doey/*/` for inspection.
- **Risk:** Variable expansion differs (tmux syntax, not shell syntax)
- **Mitigation:** Generate files with already-expanded values (no `$()` or backticks in source-file)

### Split-window with Command (O7)
- **Risk:** Pane destroyed if Claude crashes (unlike `send-keys` where the shell remains)
- **Mitigation:** Set `remain-on-exit on` per team window
- **Risk:** No shell history or environment customization in the pane
- **Mitigation:** Wrap Claude command in a shell that sets up the environment first

### Parallel Window Creation (O10)
- **Risk:** Env file race conditions when updating `session.env` TEAM_WINDOWS field
- **Mitigation:** `_set_session_env` already uses mkdir-based locking (:3508). Test under concurrent writes.

### Backward Compatibility
- All delay values are already configurable env vars — reducing defaults doesn't break users with custom values
- `source-file` is available in all tmux versions Doey targets
- Early-attach changes the user experience but doesn't change the API

---

## Appendix: All Sleeps in the Spawn Path

| Location | Duration | Purpose | Verdict |
|----------|----------|---------|---------|
| :75 `DOEY_TEAM_LAUNCH_DELAY` | 15s | Between teams | **Reduce to 5s** |
| :74 `DOEY_WORKER_LAUNCH_DELAY` | 3s | After batch boot | **Reduce to 1s** |
| :77 `DOEY_MANAGER_BRIEF_DELAY` | 8s | Wait before briefing manager | Keep (async, correctness) |
| :2998 | 0.2s | Before worker columns | **Remove** |
| :3002 | 0.3s | Between worker columns | **Remove** |
| :3566 | 0.2s | After manager launch | **Remove** |
| :3577 | 8s (via BRIEF_DELAY) | Brief team (async) | Keep (async) |
| :3786 | 2-3s (WORKER_LAUNCH_DELAY) | Between def-based workers | Reduce with batch |
| :3811 | 3s | Before def-based briefing | Keep (correctness) |
| :3818 | 1s | After def-based briefing | Keep (correctness) |
| :3897 | 3s (WORKER_LAUNCH_DELAY) | After freelancer F0 | **Fix with batch** |
| :3901 | 0.1s | After freelancer split | **Remove** |
| :3919 | 3s (WORKER_LAUNCH_DELAY) | After freelancer F1 | **Fix with batch** |
| :3939 | 0.3s | Between dynamic columns | **Remove** |
| :3995 | 0.3s | After static grid creation | **Remove** (static path) |
| :4045 | 1s | After add_team_window kill_window | Keep (cleanup) |

## Appendix: Tmux Command Counts per Team

For a dynamic team with 2 worker columns:

| Category | Count | Est. Time |
|----------|-------|-----------|
| split-window | 4 (2 per column) | ~20ms |
| select-pane -T | 5 (1 mgr + 4 workers) | ~25ms |
| send-keys | 5 (1 mgr + 4 workers) | ~25ms |
| set-option (border theme per window) | 5 | ~25ms |
| list-panes / display-message queries | 6 | ~30ms |
| write_pane_status (file I/O) | 5 | ~10ms |
| Misc (rename-window, select-layout, etc.) | 4 | ~20ms |
| **Total tmux calls** | **~34** | **~155ms** |

Plus: `rebalance_grid_layout` adds 10-20 tmux calls for move-pane/resize-pane = ~50-100ms.

Grand total per team: ~45-55 tmux calls = ~200-275ms of tmux overhead (excluding sleeps).
