# Trust-Prompt Daemon — Codebase Integration (Task 596, Subtask 2)

Research on where a new trust-prompt watcher daemon plugs into Doey's existing
session-startup architecture. Read-only investigation — no source modified.

## R2. Panes That Launch Claude Code

Doey spawns Claude in six distinct code sites. Every instance uses
`claude --dangerously-skip-permissions` (the flag that does NOT silence the
trust dialog — that's the bug driving task 596).

| Pane (session:W.P) | Role | Launch site (file:line) | When |
|---|---|---|---|
| `0.1` | Boss | `shell/doey-session.sh:143-145` (`setup_dashboard`) | `doey` startup, after `session.env` exists |
| `1.0` | Taskmaster | `shell/doey-session.sh:184-186` → `_launch_team_manager` at `shell/doey-team-mgmt.sh:787-794` | `doey` startup, via `_create_core_team` |
| `1.1` | Task Reviewer | `shell/doey-session.sh:195-198` | `doey` startup, inside `_create_core_team` |
| `1.2` | Deployment | `shell/doey-session.sh:201-204` | `doey` startup, inside `_create_core_team` |
| `1.3` | Terminal (`doey-term`) | `shell/doey-session.sh:207` | NOT a Claude pane — ignore. (CLAUDE.md documents a "Doey Expert" at `C.3`, but the current code launches `doey-term` instead.) |
| `W.0` (≥2) | Team Lead / Subtaskmaster | `_launch_team_manager` @ `shell/doey-team-mgmt.sh:787-794` | Dynamic-team expansion during startup AND every `doey add-team` / `doey add-window` / `add_team_from_def` |
| `W.1+` | Workers / Freelancers | `_batch_boot_workers` @ `shell/doey-team-mgmt.sh:474-496` (legacy) **and** `shell/doey-team-mgmt.sh:1080-1103` (team-def path) | Dynamic-team creation AND every `doey add` column AND reload-worker |
| team-def pane 0 (manager) | Subtaskmaster / custom | `shell/doey-team-mgmt.sh:1033-1035` | `add_team_from_def` (premade teams, masterplan window) |
| ad-hoc | test-driver | `shell/doey-test-runner.sh:183` | `doey test` only |
| ad-hoc | settings-editor | `shell/tmux-settings-btn.sh:21` | When user clicks settings button |

Tmux target strings are uniformly `${SESSION}:${WINDOW}.${PANE}` (e.g.
`doey-barkpark:1.0`). Sessions are always `doey-<project>` (see
`CLAUDE.md` "Conventions" + `shell/doey-session.sh:1134`).

**Three temporal phases the daemon must cover:**

1. **Startup burst** (t=0..~30s): Boss (0.1) + Core Team (1.0–1.2) + initial
   Subtaskmaster (W.0) + initial worker columns — all created inside the
   background-forked setup in `launch_session_dynamic`
   (`shell/doey-session.sh:1212-1355`).
2. **On-demand expansions**: `doey add` (columns), `doey add-team`,
   `doey add-window`, `doey masterplan` — can happen minutes/hours later.
3. **Reload**: `doey reload --workers` relaunches claude in existing panes
   (`shell/doey-session.sh:963`), which will re-hit the trust prompt only
   if it's still unresolved.

A single one-shot watcher that exits after phase 1 would miss phases 2 & 3,
so the daemon must be long-lived — ideally for the lifetime of the session.

## R4. Detection Mechanism Comparison

### Option A — Background watcher daemon (RECOMMENDED)

Single long-running shell process, forked from `launch_session_dynamic` after
pane creation begins. Iterates the canonical pane manifest (see R7) and runs
`tmux capture-pane -p -S -5 <target>` against each pane; when text matches the
trust-dialog signature, sends `C-m` (Enter).

- **Complexity**: ~80 LOC bash. No new dependencies (`tmux` + `grep` only).
- **Fresh-install**: append one `install_script` line to `install.sh:424-426`
  and copy the file into `shell/`. No hook changes required.
- **Bash 3.2**: trivial — `while :`, `for f in dir/*.role`, `tmux capture-pane`,
  `grep -q -F`. No associative arrays, no `mapfile`, no `BASH_REMATCH`
  capture-groups needed for a literal signature match.
- **Hook interaction**: none. The daemon is a peer of `doey-router.pid` /
  `doey-daemon.pid` (`doey-session.sh:1268-1292`) — identical lifecycle
  pattern (write PID, background-fork, cleaned up by `_kill_doey_session`).
- **Pane discovery**: reads `${RUNTIME_DIR}/status/*.role`, filtering out
  `info_panel` + any role not in the claude-running set. New panes appear
  automatically as `on-session-start.sh:101` writes their `.role` files.
- **False-positive risk**: LOW if the literal signature from subtask 1 is
  distinctive (e.g. `"Quick safety check"` + `"Is this a project you"`). Keep
  the match case-sensitive and plain (`grep -q -F`). Auto-exit each pane's
  watch loop after the first successful Enter OR after 60s to bound the
  window in which a false trigger could fire.
- **Coverage**: phases 1, 2, 3 all covered — daemon is alive for the whole
  session and polls the `.role` manifest so new panes are picked up.

### Option B — Pre-launch probe

Before each `claude` invocation, read `~/.claude.json` (or similar), check
whether `<project_dir>` is listed, and if not, script the Enter keystroke
via `expect` or a deferred `tmux send-keys -t <pane> Enter`.

- **Complexity**: Medium. Need per-call-site changes in `doey-session.sh` +
  `doey-team-mgmt.sh` (5+ launch sites), plus a timing heuristic for *when*
  the dialog is visible (races with Claude startup which varies 1–5s).
- **Fresh-install**: Introduces read-dependency on `~/.claude.json` — the
  task explicitly says "Do NOT pre-trust the workspace or modify
  `~/.claude.json`", and the file's schema is an external contract that
  changes between Claude releases.
- **Bash 3.2**: requires `expect` OR a sleep-based timer — `expect` is an
  extra system dependency; sleep-based timing is flaky.
- **Hook interaction**: HIGH. Every claude-spawning site has to be updated,
  and any future pane-launch code path forgetting the probe silently re-
  introduces the bug.
- **False-positive risk**: High — sending Enter into a pane that already got
  past the dialog types a blank newline at the Claude prompt.

### Option C — Per-pane wrapper script

Replace each `claude ...` invocation with `claude-trust-wrapped.sh ...` that
exec's Claude and, in parallel, scripts the Enter keystroke.

- **Complexity**: Low code, but requires modifying ~8 command-string build
  sites (`_boss_cmd`, `_spec_cmd`, `_mgr_cmd`, `_w_cmd`, test-runner, etc.).
- **Fresh-install**: one extra script to install.
- **Bash 3.2**: fine if the wrapper is pure shell.
- **Hook interaction**: same footgun as B — every new launch site must use
  the wrapper. Breaks the current `_append_settings` + `--mcp-config`
  pipeline because the Claude flags are passed through two shells.
- **False-positive risk**: same as B — wrapper must time the Enter
  correctly per pane, which is fundamentally racy.

### Recommendation

**Option A (background watcher daemon).** It is the *only* option that:

1. Covers all three temporal phases (startup + add-team + reload) without
   editing every launch site.
2. Leaves the `claude` command strings and `--settings` / `--mcp-config` /
   `--append-system-prompt-file` pipeline untouched — Doey already has six
   distinct claude-launch build sites, and any per-site solution is a future
   maintenance tax.
3. Matches a pattern the codebase already uses (`doey-router`, `doey-daemon`)
   — same PID-file + background-fork + `_kill_doey_session` cleanup story.
4. Is capture-pane-driven, so it observes what the user's pane actually
   shows — zero risk of false-positive Enter presses in panes that never
   showed the dialog, as long as the signature is sufficiently unique.
5. Honors the task's constraint: does not touch `~/.claude.json` and does
   not pre-trust. It only reacts to the visible dialog.

## R7. Integration Points

### Where the watcher script lives
`shell/trust-watcher.sh` — new file, shell script, Bash 3.2 compatible.

### Who starts it
Single insertion point in `launch_session_dynamic`, **after** the router
/ daemon block (`shell/doey-session.sh:1268-1293`) and **before** the
`setup_dashboard` call on line 1309/1315/1332. At that point `session.env`
exists (line 1243-1262), so the watcher can source it for `RUNTIME_DIR` and
`SESSION_NAME`.

Sketch:
```bash
# shell/doey-session.sh around line 1294
_tw_bin=$(command -v trust-watcher.sh 2>/dev/null || echo "${HOME}/.local/bin/trust-watcher.sh")
if [ -x "$_tw_bin" ]; then
  "$_tw_bin" --runtime "$runtime_dir" --session "$session" \
    >>"${runtime_dir}/logs/trust-watcher.log" 2>&1 &
  echo $! > "${runtime_dir}/trust-watcher.pid"
fi
```

`_kill_doey_session` should kill any PID in `${runtime_dir}/trust-watcher.pid`
for clean teardown — follow the exact pattern used for
`doey-router.pid` / `doey-daemon.pid`.

### How it discovers panes
Iterate `${RUNTIME_DIR}/status/*.role`. The `.role` filename is the
pane-safe form of `session:window.pane` (e.g.
`doey_barkpark_0_1.role`) — `on-session-start.sh:99-101` writes it as
`session:window.pane` with `:.-` → `_`. To recover the tmux target:

```bash
# inverse of on-session-start.sh:99
base="${f##*/}"; base="${base%.role}"           # doey_barkpark_0_1
target="${base#doey_}"                           # barkpark_0_1
# Split from the right on two underscores to get W and P
pane="${target##*_}"; target="${target%_*}"
win="${target##*_}";  proj="${target%_*}"
tmux_target="doey-${proj}:${win}.${pane}"
```

Simpler alternative — read the role file, skip if role = `info_panel` (info
panel runs no claude). Also skip if role is `doey-term` (pane 1.3). Use
`tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}'`
filtered to the session name; cross-reference against the `.role` manifest
to pick up every pane the install currently creates.

### install.sh changes required
install.sh **enumerates** every shell script it ships — it does NOT pick up
new files automatically. Add one line in the block at `install.sh:424-426`:

```bash
for s in tmux-statusbar.sh tmux-theme.sh pane-border-status.sh info-panel.sh \
         settings-panel.sh tmux-settings-btn.sh doey-statusline.sh \
         doey-remote-provision.sh trust-watcher.sh; do   # <-- new
  install_script "$SCRIPT_DIR/shell/$s" "$HOME/.local/bin/$s"
done
```

That's it — no hook registration, no settings-json edits.

### on-session-start.sh interaction
**None required.** `on-session-start.sh` fires once per pane when Claude
starts, *after* the trust dialog has already been shown (the dialog is a
first-paint concern before Claude finishes booting). The watcher running in
the background outside Claude is the right observer.

An optional coordination tweak: `on-session-start.sh:115` already writes a
`pane_ready` lifecycle event. The daemon could subscribe to that to
pre-arm the pane's watch loop — but polling `*.role` is already
event-driven enough for this use case and avoids coupling.

### Teardown
- **Per-pane**: each pane's inner loop exits after the first successful
  Enter send OR after a per-pane TTL (e.g. 60s). Reduces tmux noise to
  zero for panes that never showed the dialog.
- **Daemon-wide**: exits when `${runtime_dir}` disappears (`_cleanup_old_session`
  / `_kill_doey_session` rm -rf's it) OR when tmux session no longer exists
  (`tmux has-session` check every 10s). Also killable via its `.pid` file —
  `_kill_doey_session` should send SIGTERM to it like it does for the other
  daemons.

### "Wait for Claude to be ready" logic
Yes — `doey_wait_for_prompt` at `shell/doey-send.sh:143-169` waits for the
`❯` glyph via `tmux capture-pane -p -S -10` + `grep -qF '❯'`. The trust
watcher is upstream of this: by the time the prompt glyph appears, the
dialog is already gone. No coordination needed; the two functions operate
on disjoint phases of Claude startup.

## Bash 3.2 compatibility patterns already in use

Things the daemon should mirror from existing code:

- `tmux capture-pane -p -S -N` + `printf '%s' … | grep -qF …` (literal
  match, no regex or BASH_REMATCH). See `shell/doey-send.sh:152,161`.
- Plain `for f in dir/*.role` under `shopt -s nullglob` — no `mapfile`.
  Already used everywhere in `shell/doey-team-mgmt.sh`.
- Daemon lifecycle: background-fork + PID file + `kill $(cat file.pid)`
  pattern at `shell/doey-session.sh:1268-1292`.
- Env accessor: `_env_val` / `_read_team_key` for reading
  `${runtime_dir}/session.env` without sourcing — avoids side-effects when
  running as a daemon.

## Proposed Architecture Diagram

```
  doey user command
        │
        ▼
  shell/doey.sh  →  launch_session_dynamic (doey-session.sh:1132)
        │
        │  fork to background
        ▼
  ┌────────────────────────────────────────────────────────┐
  │  _init_doey_session  →  writes session.env            │
  │  apply_doey_theme                                      │
  │  write session.env + detect project type               │
  │  start doey-router.pid                                 │
  │  start doey-daemon.pid                                 │
  │  ★ start trust-watcher.pid  ◄── NEW, 1-line addition  │
  │  setup_dashboard           → claude in 0.1 (Boss)      │
  │  _create_core_team         → claude in 1.0, 1.1, 1.2   │
  │  launch team window(s)     → claude in W.0, W.1+       │
  └────────────────────────────────────────────────────────┘
                                │
                                ▼
    trust-watcher.sh (long-running, owned by session)
        │
        ├─ every 500ms: for f in $RUNTIME/status/*.role
        │     role=$(cat $f); pane=$(decode $f basename)
        │     [ role == info_panel|doey-term ] && continue
        │     cap=$(tmux capture-pane -p -S -5 -t $pane)
        │     if grep -qF "Quick safety check" <<<"$cap"; then
        │         tmux send-keys -t $pane Enter
        │         mark $pane done   # stop polling this pane
        │     fi
        │
        └─ exits when: session gone OR all panes marked done
                         OR runtime_dir deleted
                                │
                                ▼
                 PID cleaned up by _kill_doey_session
```

## Summary for implementor

- One new file: `shell/trust-watcher.sh` (~80 LOC, Bash 3.2).
- One edit in `shell/doey-session.sh` near line 1294 — fork the daemon.
- One edit in `install.sh:424` — add `trust-watcher.sh` to the for-loop.
- One edit in `_kill_doey_session` (helper in `shell/doey-session.sh` or
  `shell/doey-helpers.sh`) — kill `${runtime_dir}/trust-watcher.pid`.
- No hook changes. No agent changes. No settings.json changes.
- Fresh-install friendly: `install.sh` picks it up via the explicit entry;
  fork runs with `TMPDIR`/`RUNTIME_DIR` as only inputs.
