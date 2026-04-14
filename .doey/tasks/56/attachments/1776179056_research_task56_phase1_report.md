# Task 56 — Phase 1 Research Report
**Task:** Wire startup to run in parallel with a 5-second countdown; dismiss at `min(5s, startup_complete)`.
**Generated:** 2026-04-14

---

## Summary

- There is **no literal "5-second countdown"** in the codebase today. The user-visible startup is a two-stage display: a bash `doey_splash()` (capped at ~1s min) followed by a `doey-loading` Bubbletea TUI that runs up to **45s** while polling pane `.status` files.
- The bash splash is **not a blocker** — `_launch_session_core()` runs synchronously while the splash ASCII is on-screen (stdout is redirected to a log). So "startup runs in parallel with the splash" already; what blocks attach is the **`doey-loading`** wait.
- The natural gate is `wait "$_loading_pid"` at `shell/doey-session.sh:800`. This is the single foreground choke-point that holds the user on the loading screen until Boss + Taskmaster reach `READY`, or 45s elapse.
- Two dismissal signals already exist inside `doey-loading`: `allKeyPanesReady()` (exit 0) and `timeoutMsg` (exit 2). A 5s cap can be implemented either by (A) changing the `--timeout` flag to `5` **and** tightening the "ready" predicate, or (B) adding a new `--min-display` / `--max-display` pair and letting readiness win whichever is sooner.
- A cross-boundary `startup_complete` signal is trivial to add: `touch "${RUNTIME_DIR}/startup_complete"` from the last "Ready" transition. No such file exists today.

---

## Current flow (actual, verified)

1. User runs `doey` → `load_with_grid` (`shell/doey.sh:586`) → `launch_session()` (`shell/doey-session.sh:767`).
2. `doey_splash` prints cyan ASCII art (`shell/doey-ui.sh:191-205`) — instant.
3. `_splash_wait_minimum 1` blocks up to **1s** (hard-capped at 1s regardless of arg, `shell/doey-ui.sh:208-223`).
4. `ensure_project_trusted` (`shell/doey-session.sh:778`).
5. stdout/stderr redirected to `${runtime_dir}/logs/startup.log` (`shell/doey-session.sh:782-783`) — splash stays visible on terminal.
6. `_launch_session_core` runs **sequentially** — session create, hooks install, layout, pane naming, Taskmaster launch, worker boot (parallel fan-out) (`shell/doey-session.sh:785`, body at 597-765).
7. `doey-loading` Bubbletea TUI launched in background with `--timeout 45` (`shell/doey-session.sh:789-795`).
8. stdout restored; `wait "$_loading_pid"` blocks foreground (`shell/doey-session.sh:799-801`).
9. `attach_or_switch "$session"` (`shell/doey-session.sh:803`).

**Gating answer to the task's GATING question:** Startup is **already concurrent** with the splash — `_launch_session_core` runs while splash pixels are on the terminal. The only sequential wait is `_splash_wait_minimum 1` (≤1s) and `wait $_loading_pid` (≤45s). Neither is a "full 5s regardless" sleep.

**What keeps the user on-screen post-splash:** `doey-loading` waits for `allKeyPanesReady()` — Boss pane (`_0_1`) AND Taskmaster pane (`_1_0`) in `READY|BUSY|WORKING|FINISHED|ERROR` (`tui/cmd/doey-loading/main.go:281-299`).

---

## File:line map — every splash/startup touchpoint

### Bash splash

| File | Line | Role |
|------|------|------|
| `shell/doey-ui.sh` | 191-205 | `doey_splash()` — prints ASCII; sets `_DOEY_SPLASH_START` |
| `shell/doey-ui.sh` | 208-223 | `_splash_wait_minimum()` — hard-capped at 1s |
| `shell/doey-session.sh` | 775 | Call: `doey_splash` |
| `shell/doey-session.sh` | 776 | Call: `_splash_wait_minimum 1` |
| `shell/doey-session.sh` | 782-783 | stdout redirect (keeps splash visible) |
| `shell/doey-session.sh` | 785 | `_launch_session_core` runs during splash |
| `shell/doey-session.sh` | 789-795 | Spawn `doey-loading --timeout 45` |
| `shell/doey-session.sh` | 799-801 | `wait $_loading_pid` (foreground block) |
| `shell/doey-session.sh` | 803 | `attach_or_switch` |

### `doey-loading` (Bubbletea loading screen) — `tui/cmd/doey-loading/main.go`

| Lines | Role |
|-------|------|
| 36-49 | `model` struct (timeout, startTime, panes, exitCode) |
| 83-142 | `discoverPanes` — reads session.env, team_*.env |
| 147-177 | `readStatuses` — scans `${runtime}/status/*.status` |
| 179-183 | `pollStatusCmd` — 500ms tick |
| 185-189 | `timeoutCmd` — single tea.Tick at timeout |
| 200-209 | `newModel` wiring |
| 212-217 | `Init` — batch(spinner, poll, timeout) |
| 220-255 | `Update` — key handling, poll, timeout |
| 228-234 | **Skip key handler** — `q`/`ctrl+c`/`esc` → exitCode 1 |
| 243-247 | **Ready handler** — `allKeyPanesReady()` → exitCode 0 |
| 250-253 | **Timeout handler** — → exitCode 2 |
| 259-275 | `applyStatuses` — READY/BUSY/WORKING/FINISHED/ERROR → "ready" |
| 281-299 | `allKeyPanesReady` — Boss `_0_1` + Taskmaster `_1_0` |
| 303-343 | `View` — title, grid, progress, "Press q to skip" hint |
| 324 | Hint literal: `"Press q to skip"` |

### Alternate splash (not in current path) — `tui/internal/startup/startup.go`

Used only by `doey-tui startup` via `_show_startup_progress()` in `shell/doey-ui.sh:228-239`, which is a **fallback** invoked elsewhere (not in `launch_session`). Notable lines:

| Lines | Role |
|-------|------|
| 51-107 | `tailProgress` — file-tailer, 100ms polls |
| 158-163 | Key handler — q/ctrl+c/esc |
| 171-179 | "Ready" string triggers exitCode 0 |
| 189-191 | Timeout → exitCode 2 |
| 198-214 | Splash ASCII art |
| 252 | "Press q to skip" |
| 268-290 | `Run()` — tea.Program |

### Shell startup hook — `.claude/hooks/on-session-start.sh`

| Lines | Role |
|-------|------|
| 101 | Write `${RUNTIME_DIR}/status/${PANE_SAFE}.role` |
| 113 | Write `${RUNTIME_DIR}/status/${PANE_SAFE}.status = BOOTING` |
| 115 | Lifecycle event `pane_boot` → `${RUNTIME_DIR}/lifecycle/events.jsonl` |
| 122 | Save respawn cmd to `.launch_cmd` |
| 166-189 | Inject DOEY_* env vars |
| 282 | Lifecycle event `pane_ready` |

### Info panel — `shell/info-panel.sh`

| Lines | Role |
|-------|------|
| 1-42 | Waits for `DOEY_RUNTIME`; refresh loop every 5min |
| — | Not a blocker; runs concurrently in pane 0.0 |

### Ready state machine

- `transition_state()` in `.claude/hooks/common.sh:408` writes to `${RUNTIME_DIR}/status/<pane>.status`. States: `BOOTING → READY → BUSY → FINISHED/ERROR`.
- `READY` written by team-spawn code (`shell/doey-team-mgmt.sh:503`, `796`, `1106`).

---

## Key Files

- `shell/doey-session.sh` — `launch_session()` orchestration (the primary edit target)
- `shell/doey-ui.sh` — bash splash + `_splash_wait_minimum` + TUI-fallback wrapper
- `tui/cmd/doey-loading/main.go` — the real "loading screen" (the other primary edit target)
- `tui/internal/startup/startup.go` — alternate/fallback TUI splash (may be unused in primary path)
- `.claude/hooks/on-session-start.sh` — pane state transitions (BOOTING → emits `pane_ready`)
- `shell/doey-team-mgmt.sh` — writes `READY` for Taskmaster/Subtaskmaster/Workers

---

## Plan A (recommended) — Cap `doey-loading` at 5s with min-display floor

**Intent:** Users always see the loading screen for at most 5 seconds. If Boss + Taskmaster are READY before 5s, dismiss as soon as a small min-display floor elapses (say 800ms) so the UI doesn't flicker. If not ready in 5s, dismiss anyway.

Equivalently: `dismiss_at = clamp(startup_complete_time, 800ms, 5000ms)`.

### Edits

1. **`shell/doey-session.sh:790,793`** — change `--timeout 45` to `--timeout 5`.
   ```
   -    doey-loading --session "$session" --runtime "$runtime_dir" --timeout 45 >&3 2>&4 &
   +    doey-loading --session "$session" --runtime "$runtime_dir" --timeout 5 --min-display 800ms >&3 2>&4 &
   ```
   Apply identically to the fallback on line 793.

2. **`tui/cmd/doey-loading/main.go`** — add `--min-display` flag and enforce floor in the `pollMsg` ready branch.
   - Add flag (near existing `flag.DurationVar` calls — search the `main()` func; if not present currently, add a `flag.DurationVar(&minDisplay, "min-display", 0, ...)`).
   - In `model`, add `minDisplay time.Duration`.
   - In `Update` (line 243-247), replace:
     ```go
     case pollMsg:
         m.applyStatuses(msg.statuses)
         if m.allKeyPanesReady() {
     -       m.done = true
     -       m.exitCode = 0
     -       return m, tea.Quit
     +       elapsed := time.Since(m.startTime)
     +       if elapsed >= m.minDisplay {
     +           m.done = true
     +           m.exitCode = 0
     +           return m, tea.Quit
     +       }
     +       // hold briefly, then quit
     +       return m, tea.Tick(m.minDisplay-elapsed, func(_ time.Time) tea.Msg {
     +           return readyHoldMsg{}
     +       })
         }
         return m, pollStatusCmd(m.runtime)
     ```
   - Add `readyHoldMsg` type and a case to handle it with exitCode 0.

3. **`tui/cmd/doey-loading/main.go` View (line 324)** — update hint to reflect shorter wait:
   ```
   -    hint := ...Render("Press q to skip")
   +    hint := ...Render("Press q to skip (auto-dismisses in 5s)")
   ```

4. **Remove `_splash_wait_minimum 1`** at `shell/doey-session.sh:776` (or leave it — the bash splash is effectively subsumed into the 5s loading budget, but a single 1s bash splash pre-loading-screen is harmless). **Recommendation: keep it** for resilience when `doey-loading` isn't installed.

5. **Emit `startup_complete` touchfile** (see section below) — from bash side, after `wait $_loading_pid` returns:
   ```
   # shell/doey-session.sh, after line 801
   : > "${runtime_dir}/startup_complete"
   ```
   This is a post-hoc marker visible to external tooling; it fires whether exit was by readiness, timeout, or skip.

### Rationale (A)
- Minimal surface area — one Go flag + one bash arg.
- Preserves existing exit-code semantics (0 ready / 1 skip / 2 timeout) for scripts that care.
- Min-display floor prevents a <100ms flash when Taskmaster is cached/fast.
- Bash splash retained as safety net when the Go binary is missing.
- `startup_complete` file is emitted after the wait, so it's a real "we are attaching now" marker.

---

## Plan B — Add a dedicated `--max-display 5s` without behavioral change to readiness predicate

**Intent:** Keep the 45s hard timeout for full-system readiness, but cap user-visible wait at 5s by adding a second timer. User sees loading screen disappear at `min(5s, allKeyPanesReady, 45s, q-skip)`; background work continues regardless.

### Edits

1. **`tui/cmd/doey-loading/main.go`** — add `--max-display` flag (e.g., `5s`) separate from `--timeout` (e.g., `45s`). `--timeout` becomes a "absolute giveup / error exit"; `--max-display` is "soft dismiss".
   - Add `flag.DurationVar(&maxDisplay, "max-display", 5*time.Second, ...)`.
   - Add `maxDisplayCmd` returning a new `maxDisplayMsg`.
   - In `Init` (line 213), include the new Tick.
   - In `Update`, handle `maxDisplayMsg` like a successful exit (exitCode 0 to distinguish from hard timeout). Since panes aren't strictly verified ready, log the reason.

2. **`shell/doey-session.sh:790,793`** — add flag:
   ```
   -    doey-loading --session "$session" --runtime "$runtime_dir" --timeout 45 >&3 2>&4 &
   +    doey-loading --session "$session" --runtime "$runtime_dir" --timeout 45 --max-display 5s >&3 2>&4 &
   ```

3. **`startup_complete` touchfile** — same as Plan A, after `wait`.

### Rationale (B)
- Preserves current 45s error-detection semantics (important if anything downstream reads exitCode 2 for "startup genuinely failed").
- Clearer separation of concerns: display time vs. readiness time.
- Slightly more code (two timers, two messages) but easier to reason about.
- Downside: attaching before Boss/Taskmaster are `READY` means the user can see a BOOTING pane briefly. This may be acceptable; Claude Code panes show their own loading state.

---

## Proposed `startup_complete` signal mechanism

**Mechanism:** Empty touch file at `${RUNTIME_DIR}/startup_complete`.

**Emitter (shell):** `shell/doey-session.sh`, immediately after `wait "$_loading_pid"` completes (line 801):
```sh
: > "${runtime_dir}/startup_complete"
```

**Why here:**
- Atomic, simple (no locking).
- Fires on any `doey-loading` exit path (ready, timeout, skip) — the single post-wait point.
- Accessible to Go and bash tooling without IPC.
- `${runtime_dir}` is already created at line 781.

**Alternative (richer):** Have `doey-loading` write the file itself, including exit reason:
```go
// in tui/cmd/doey-loading/main.go, at final tea.Quit emission
os.WriteFile(filepath.Join(runtimeDir, "startup_complete"),
    []byte(fmt.Sprintf("reason=%s\nelapsed_ms=%d\n", reason, time.Since(startTime).Milliseconds())),
    0644)
```
This lets downstream logic know *why* startup ended. Recommend this for Plan A/B both.

**Cleanup:** `_cleanup_old_session` at `shell/doey-session.sh:809` already removes `$runtime_dir`, so no extra cleanup needed.

---

## Risks

1. **q-skip race** — If user presses `q` at the exact moment readiness fires, Bubbletea's `Update` is serialized per-message, so no actual race. But: exitCode 1 (skip) vs. 0 (ready) may both write `startup_complete` with different reasons. Mitigation: shell-side touch after wait is reason-agnostic; Go-side richer file can record which won.

2. **Readiness signal race (Plan A)** — `allKeyPanesReady()` uses `.status` files written by `transition_state()`. There's a small window where Taskmaster pane exists but hasn't yet transitioned `BOOTING → READY`. At 5s total budget, this is tighter than before. Mitigation: the current predicate already accepts `BUSY|WORKING|FINISHED|ERROR` as "alive", so ERROR will not hang the loader. **Risk is low.**

3. **Fresh-install impact (install.sh / settings.json)** — No changes required to `install.sh`. No `~/.claude/settings.json` changes needed. `doey-loading` binary is already installed (`tui/cmd/doey-loading/` builds via Go; installed by `install.sh` alongside `doey-scaffy`). Verify: check `install.sh` for `doey-loading` build step. If absent, must add.

4. **Bash 3.2 compatibility** — Proposed bash change (`: > file`) is POSIX; no bash 3.2 concerns. Run `tests/test-bash-compat.sh` after edits.

5. **zsh globbing** — None of the proposed edits use globs in Bash tool commands.

6. **Broken 5s budget on slow machines** — On cold VM boot, Taskmaster pane can take >5s to reach READY. With Plan A, user attaches to a pane still showing Claude's own startup sequence. This is likely fine but should be documented.

7. **Fallback path (bash `_show_startup_progress`)** — `shell/doey-ui.sh:228-239` uses `doey-tui startup` as a fallback, not `doey-loading`. That fallback is invoked by a **different** caller — verify it's not on the primary `launch_session` path (grep confirms: `launch_session` uses `doey-loading` only).

8. **Existing exit-code consumers** — `wait "$_loading_pid"` discards the exit status (`|| true`), so no script currently depends on it. Safe to change semantics.

---

## Dispatch-ready implementation prompts for Phase 2

### Prompt — Worker 1: Go loading screen changes (Plan A)

> **TASK:** Edit `tui/cmd/doey-loading/main.go` to cap user-visible loading time at 5s with a min-display floor.
>
> 1. Add a `--min-display` CLI flag (duration, default `0`). Scan `main()` for existing `flag.DurationVar` calls and add alongside.
> 2. Add `minDisplay time.Duration` to the `model` struct (line 36-49).
> 3. Thread the flag into `newModel()` (line 193).
> 4. In `Update` (`pollMsg` branch, line 241-248), after `m.allKeyPanesReady()` returns true, gate on `time.Since(m.startTime) >= m.minDisplay`. If not yet elapsed, return a `tea.Tick` that schedules a new `readyHoldMsg` at the remaining time. Add a `case readyHoldMsg:` branch that sets `done=true, exitCode=0` and returns `tea.Quit`.
> 5. Update the "Press q to skip" hint on line 324 to "Press q to skip (auto-dismisses in 5s)".
> 6. On any tea.Quit path, write `${runtimeDir}/startup_complete` with `reason=<ready|timeout|skip>\nelapsed_ms=<n>\n`.
>
> Run `cd tui && go build ./...` to verify. Do not edit any other file.

### Prompt — Worker 2: Shell invocation changes

> **TASK:** Update `shell/doey-session.sh` to use the new 5s loading budget.
>
> 1. Edit line 790: change `--timeout 45` to `--timeout 5 --min-display 800ms`.
> 2. Edit line 793 (fallback branch): same change.
> 3. Leave `_splash_wait_minimum 1` at line 776 as-is (safety net when `doey-loading` is absent).
> 4. After line 801 (`wait "$_loading_pid" 2>/dev/null || true`), add a shell-side safety touch in case the Go binary failed to write it: `[ -f "${runtime_dir}/startup_complete" ] || : > "${runtime_dir}/startup_complete"`.
>
> Run `bash tests/test-bash-compat.sh` to verify. Do not edit any other file.

### Prompt — Worker 3 (optional): Install-path verification

> **TASK:** Confirm `doey-loading` ships via `install.sh`.
>
> 1. `grep -n "doey-loading" /Users/frikk.jarl/Documents/GitHub/doey/install.sh` — confirm a build step exists (e.g., `go build -o ~/.local/bin/doey-loading ./tui/cmd/doey-loading`). If absent, add it alongside the existing `doey-scaffy` build.
> 2. Verify `doey doctor` still passes after fresh install.
> 3. Run `doey uninstall && ./install.sh && command -v doey-loading` — must print a path.
>
> Report only; do not edit unless a build step is missing.

---

## Appendix — verbatim current countdown/readiness logic

**Bash min-wait (`shell/doey-ui.sh:207-223`):**
```sh
_splash_wait_minimum() {
  local min_seconds="${1:-1}"
  if [ "$min_seconds" -gt 1 ]; then
    min_seconds=1
  fi
  if [ -n "${_DOEY_SPLASH_START:-}" ]; then
    local now elapsed remaining
    now="$(date +%s)"
    elapsed=$(( now - _DOEY_SPLASH_START ))
    remaining=$(( min_seconds - elapsed ))
    if [ "$remaining" -gt 0 ]; then
      sleep "$remaining"
    fi
  fi
}
```

**Go ready predicate (`tui/cmd/doey-loading/main.go:281-299`):**
```go
func (m *model) allKeyPanesReady() bool {
    bossReady := false
    taskmasterReady := false
    bossSuffix := "_0_1"
    tmSuffix := "_1_0"
    for _, p := range m.panes {
        if p.status != "ready" { continue }
        if strings.HasSuffix(p.paneID, bossSuffix) { bossReady = true }
        if strings.HasSuffix(p.paneID, tmSuffix) { taskmasterReady = true }
    }
    return bossReady && taskmasterReady
}
```
