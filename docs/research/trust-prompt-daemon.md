# Trust-Prompt Daemon — Consolidated Research Report (Task 596)

**Status:** Authoritative. Merges findings from
[trust-prompt-experimental.md](./trust-prompt-experimental.md) (dialog signature
+ behavior) and [trust-prompt-integration.md](./trust-prompt-integration.md)
(codebase integration map). Source reports retained for traceability.

## TL;DR

Claude Code shows a `Quick safety check: Is this a project you created or one
you trust?` modal on first launch in an un-trusted directory — **even with
`--dangerously-skip-permissions`**. The dialog races Doey's startup and crashes
Boss.

**Recommendation:** ship a 1-per-session background shell daemon
(`shell/trust-watcher.sh`) that tails pane captures, matches the literal
signature, and sends `Enter`. Fresh-install friendly, zero changes to
`~/.claude.json`, mirrors the existing `doey-router` / `doey-daemon` lifecycle.

## R1 — Exact Text Signature

Full dialog (see source experimental report for raw captures):

```
 Accessing workspace:

 /tmp/claude-trust-test-<pid>

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel
```

Distinctive markers, most → least unique:

1. `Quick safety check: Is this a project you created or one you trust?` — full
   sentence, zero collisions with normal Claude UI. **This is the canonical
   match pattern.**
2. `❯ 1. Yes, I trust this folder` — caret is U+276F, exact option label.
3. `Accessing workspace:` followed by a path line — gate-screen only.
4. `Enter to confirm · Esc to cancel` — middle separator is U+00B7 middle-dot,
   not ASCII. Generic confirmation footer (not unique on its own).

No rounded box around the gate — that chrome only renders *after* acceptance.

## R2 — Panes That Launch Claude Code

Every instance uses `claude --dangerously-skip-permissions`, and the flag does
NOT suppress the trust dialog.

| Pane (session:W.P) | Role | Launch site (file:line) | Phase |
|---|---|---|---|
| `0.1` | Boss | `shell/doey-session.sh:143-145` (`setup_dashboard`) | startup |
| `1.0` | Taskmaster | `shell/doey-session.sh:184-186` → `_launch_team_manager` at `shell/doey-team-mgmt.sh:787-794` | startup |
| `1.1` | Task Reviewer | `shell/doey-session.sh:195-198` | startup |
| `1.2` | Deployment | `shell/doey-session.sh:201-204` | startup |
| `1.3` | `doey-term` (NOT claude) | `shell/doey-session.sh:207` | ignore |
| `W.0` (≥2) | Subtaskmaster | `_launch_team_manager` @ `shell/doey-team-mgmt.sh:787-794` | startup + `doey add-team` / `doey add-window` |
| `W.1+` | Workers / Freelancers | `_batch_boot_workers` @ `shell/doey-team-mgmt.sh:474-496` **and** `shell/doey-team-mgmt.sh:1080-1103` | startup + every `doey add` column + reload |
| team-def pane 0 | Subtaskmaster / custom | `shell/doey-team-mgmt.sh:1033-1035` | `add_team_from_def` |
| ad-hoc | test-driver | `shell/doey-test-runner.sh:183` | `doey test` only |
| ad-hoc | settings-editor | `shell/tmux-settings-btn.sh:21` | on settings click |

Target strings: `${SESSION}:${WINDOW}.${PANE}` (session is always
`doey-<project>`). Three temporal phases the daemon must cover:

1. **Startup burst** (t=0..~30s) — Boss, Core Team, Subtaskmaster, initial
   worker columns.
2. **On-demand expansion** — `doey add`, `doey add-team`, `doey add-window`,
   `doey masterplan`; can happen minutes or hours later.
3. **Reload** — `doey reload --workers` (`shell/doey-session.sh:963`)
   re-launches `claude` in existing panes.

A one-shot watcher misses phases 2 & 3 → daemon must live for the session.

## R3 — Keyboard Behavior

| Keys          | Observed                                                                 |
|---------------|--------------------------------------------------------------------------|
| `Enter`       | Confirms default (option 1). Dialog vanishes; welcome box + `⏵⏵ bypass permissions on` footer render. |
| `1` + `Enter` | Same result — option 1 already highlighted. Redundant.                   |
| `2` + `Enter` | Selects "No, exit" — Claude terminates.                                  |
| `Esc`         | Cancels (exits).                                                         |

Default on Enter: option 1. **Send a single Enter, nothing else.** Do not send
a literal `1` first — if Claude changes the default highlight, bare Enter
remains correct; a literal `1` could then be wrong.

## R4 — Detection Mechanism — Ranked

### 🥇 Option A — Background watcher daemon (CHOSEN)

Long-running shell process, forked from `launch_session_dynamic` after pane
creation begins. Iterates the canonical pane manifest
(`$RUNTIME_DIR/status/*.role`), runs `tmux capture-pane -p -S -15 <target>`
against each pane, and sends `C-m` when the signature matches.

- **Complexity:** ~100 LOC bash. No new deps (`tmux` + `grep` only).
- **Fresh-install:** append one line to `install.sh` for-loop + copy file into
  `shell/`. No hook or settings.json changes.
- **Bash 3.2:** trivial — `while :`, `for f in dir/*.role`, `grep -qF`. No
  associative arrays, no `mapfile`, no `BASH_REMATCH`.
- **Hook interaction:** none. Peer of `doey-router.pid` / `doey-daemon.pid` —
  identical lifecycle: write PID, fork, cleanup via `_kill_doey_session`.
- **Pane discovery:** reads `${RUNTIME_DIR}/status/*.role`, filters
  `info_panel` + `doey-term`. New panes picked up automatically when
  `on-session-start.sh:99-101` writes their `.role` files.
- **False-positive risk:** LOW with literal signature + `grep -qF`. Per-pane
  TTL (60s) bounds exposure window. Per-pane `.trust_done` marker prevents
  re-trigger.
- **Coverage:** phases 1, 2, 3.

### 🥈 Option B — Pre-launch probe

Before each `claude` invocation, inspect `~/.claude.json` and script an Enter
keystroke if directory is un-trusted.

- **Complexity:** medium — per-call-site changes at 5+ launch sites.
- **Fresh-install:** introduces read-dependency on `~/.claude.json`, whose
  schema is an external contract; task brief forbids touching this file.
- **Bash 3.2:** needs `expect` OR flaky sleep-based timing.
- **Hook interaction:** HIGH. Every new launch site must remember the probe.
- **False-positive risk:** HIGH — sending Enter into a pane that already got
  past the dialog types a blank newline at Claude's prompt.

### 🥉 Option C — Per-pane wrapper script

Replace `claude ...` with `claude-trust-wrapped.sh ...` that exec's Claude and
scripts an Enter in parallel.

- **Complexity:** low code, ~8 call-site updates.
- **Fresh-install:** one extra script to install.
- **Bash 3.2:** fine.
- **Hook interaction:** same footgun as B. Breaks the `--settings`
  `--mcp-config` `--append-system-prompt-file` flag pipeline by pushing it
  through a second shell.
- **False-positive risk:** same as B — racy timing.

**Decision:** Option A. Only option covering all three temporal phases without
editing every launch site, and reacts to what the pane actually shows.

## R5 — False-Positive Patterns

**Use `grep -qF 'Quick safety check: Is this a project you created'`** —
74-char literal. Cannot appear in normal Claude output, tool results, or user
prompts without explicit quoting.

Do not use alone:

- `Enter to confirm · Esc to cancel` — appears on other Claude modals.
- `Yes, I trust this folder` without the `❯ 1.` prefix — user might quote it
  in chat.

Per-pane guards:

- `.trust_first_seen` timestamp + 60s TTL → stop watching stale panes.
- `.trust_done` marker after first successful Enter → no double-fire.
- Skip roles `info_panel` and `doey-term` (no Claude in those).

## R6 — Dialog Lifetime

- **Appears:** immediately after `claude` launches in a directory not listed
  in `~/.claude.json`. Well under 1 s on fast hosts; assume < 3 s on slow
  ones. Survives `--dangerously-skip-permissions`.
- **Disappears:** instantly on Enter. No animation.
- **Times out:** no — modal blocks the session indefinitely.
- **Per-pane watch window:** 60 s TTL after first seen. Daemon itself runs
  session-long.

Once accepted, the path is persisted in `~/.claude.json`; subsequent launches
in the same dir do not re-prompt. So the watcher matters on first-launch
panes, and cheaply no-ops thereafter.

## R7 — Integration Points

### Watcher script
- **Location:** `shell/trust-watcher.sh` (new, ~100 LOC, Bash 3.2).
- **Install:** `install.sh` shell-script for-loop (currently around line 424)
  — add `trust-watcher.sh` to the list. Fresh install: ships to
  `$HOME/.local/bin/trust-watcher.sh`.

### Fork site
`shell/doey-session.sh` — inside `launch_session_dynamic`, immediately after
the `doey-daemon` fork block (currently around line 1293) and before
`setup_dashboard`. At that point `session.env` exists, so the watcher can
resolve `RUNTIME_DIR` / `SESSION_NAME`.

```bash
local _tw_bin=""
if [ -x "${HOME}/.local/bin/trust-watcher.sh" ]; then
  _tw_bin="${HOME}/.local/bin/trust-watcher.sh"
elif [ -x "${SESSION_SCRIPT_DIR}/trust-watcher.sh" ]; then
  _tw_bin="${SESSION_SCRIPT_DIR}/trust-watcher.sh"
fi
if [ -n "$_tw_bin" ]; then
  mkdir -p "${runtime_dir}/logs"
  DOEY_RUNTIME="$runtime_dir" SESSION_NAME="$session" \
    "$_tw_bin" --runtime "$runtime_dir" --session "$session" \
    >> "${runtime_dir}/logs/trust-watcher.log" 2>&1 &
  echo $! > "${runtime_dir}/trust-watcher.pid"
fi
```

### Teardown sites
Both `_kill_doey_session` (around line 393) and `_cleanup_old_session` (around
line 822) get a parallel block mirroring the `doey-router` / `doey-daemon`
cleanup:

```bash
if [ -f "$_rt/trust-watcher.pid" ]; then
  kill "$(cat "$_rt/trust-watcher.pid")" 2>/dev/null || true
  rm -f "$_rt/trust-watcher.pid"
fi
```

### Pane discovery
- Iterate `${RUNTIME_DIR}/status/*.role`.
- Role-file basename is pane-safe (`session:W.P` with `:.-` → `_`, written by
  `on-session-start.sh:99`).
- Skip `info_panel` and `doey-term`.
- Decode basename → tmux target by stripping the session-safe prefix and
  splitting `W_P` from the right.

### Wait-for-prompt interaction
`doey_wait_for_prompt` at `shell/doey-send.sh:143-169` waits for `❯` via
`tmux capture-pane` + `grep -qF`. By the time the prompt glyph appears, the
trust dialog is already gone. No coordination needed.

### Hooks
**No hook changes.** `on-session-start.sh` fires *after* Claude's first paint
(by which time the trust dialog already blocks the session). The external
daemon is the correct observer.

## Architecture

```
  doey user command
        │
        ▼
  launch_session_dynamic (shell/doey-session.sh)
        │
        │  fork to background
        ▼
  ┌────────────────────────────────────────────────────────┐
  │  _init_doey_session   →  writes session.env           │
  │  apply_doey_theme                                      │
  │  start doey-router.pid                                 │
  │  start doey-daemon.pid                                 │
  │  ★ start trust-watcher.pid  ◄── 1-line addition       │
  │  setup_dashboard           → claude in 0.1 (Boss)      │
  │  _create_core_team         → claude in 1.0, 1.1, 1.2   │
  │  team window(s)            → claude in W.0, W.1+       │
  └────────────────────────────────────────────────────────┘
                                │
                                ▼
    trust-watcher.sh (long-running, owned by session)
        │
        ├─ every 1s: for f in $RUNTIME/status/*.role
        │     role=$(head -n1 $f);  pane=$(decode $base)
        │     skip if role in {info_panel, doey-term}
        │     skip if .trust_done marker present
        │     skip if .trust_first_seen age > 60s (TTL)
        │     cap=$(tmux capture-pane -p -S -15 -t $pane)
        │     if grep -qF "Quick safety check: Is this a project you created" <<<"$cap"; then
        │         tmux send-keys -t $pane C-m
        │         sleep 0.5
        │         re-check; re-send Enter if still present
        │         touch $base.trust_done
        │     fi
        │
        └─ exits when: session gone OR runtime_dir deleted
                                │
                                ▼
         PID cleaned up by _kill_doey_session / _cleanup_old_session
```

## Summary for implementor

- New file: `shell/trust-watcher.sh` (~100 LOC, Bash 3.2, `set -euo pipefail`).
- Edit `shell/doey-session.sh` — fork after `doey-daemon` block; cleanup in
  `_kill_doey_session` and `_cleanup_old_session`.
- Edit `install.sh` — add `trust-watcher.sh` to the shell-scripts for-loop.
- **No** hook edits, **no** agent edits, **no** `~/.claude.json` changes.
- Fresh-install friendly. No user-local state required.

## Sources

- [trust-prompt-experimental.md](./trust-prompt-experimental.md)
- [trust-prompt-integration.md](./trust-prompt-integration.md)
