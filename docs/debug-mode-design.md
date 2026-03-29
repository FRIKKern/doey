# Doey Debug Mode — Design Document

## Motivation

122 bug-fix commits across 5 recurring patterns. When things go wrong in a multi-agent tmux session, reconstructing what happened requires manually reading status files, capture-pane, git log, and errors.log. Debug mode provides a flight recorder that captures the full story automatically.

## Bug Pattern → Log Category Mapping

Grounded in real commit history, not speculation:

| Bug Pattern | What would help | Log Category |
|---|---|---|
| Pane addressing (18+) | Pane targeted, resolved address, role applied | `hooks` |
| Role resolution (8+) | Role source (env/file/fallback), stale detection | `hooks` |
| Auth exhaustion (5+) | Start times, launch stagger, rate limit hits | `lifecycle` |
| Notification chain (5+) | Message from→to, delivery, success/failure | `messages` |
| Race conditions (8+) | Timing of concurrent ops, state transitions | `state` |
| Bash/zsh compat (8+) | N/A — syntax issues, not runtime | — |
| Install/shipping (12+) | N/A — build-time issues, not runtime | — |

## Toggle Mechanism (WordPress-style)

### Config file: `$RUNTIME_DIR/debug.conf`

Flat key=value format. **Never sourced** — parsed with `grep`/`case` to prevent syntax errors from killing hooks.

```bash
DOEY_DEBUG=true
DOEY_DEBUG_HOOKS=true
DOEY_DEBUG_LIFECYCLE=true
DOEY_DEBUG_MESSAGES=true
DOEY_DEBUG_STATE=true
DOEY_DEBUG_DISPLAY=false
```

- File existence IS the master toggle (`[ -f "$RUNTIME_DIR/debug.conf" ]`)
- When file doesn't exist: zero overhead (one `stat()` syscall, ~0.05ms)
- Sub-toggles allow granularity (e.g., just hooks, just lifecycle)
- `DOEY_DEBUG_DISPLAY=true` prints debug info to stderr (opt-in, for human debugging)

### Skill: `/doey-debug on|off|status`

- `on`: Creates `debug.conf` + `$RUNTIME_DIR/debug/` directory
- `off`: Removes `debug.conf` (keeps logs for post-mortem)
- `status`: Shows enabled/disabled, log sizes, last entry per category

## Log Structure

**Per-pane files** to eliminate concurrent write races (Critic finding: macOS doesn't guarantee atomic appends to shared files across processes).

```
$RUNTIME_DIR/debug/
  {PANE_SAFE}/          # e.g., doey_proj_1_2/
    hooks.jsonl         # hook entry/exit, tool context, role resolution
    lifecycle.jsonl     # pane start/stop/crash, agent, model
    state.jsonl         # status transitions (READY→BUSY→FINISHED)
    messages.jsonl      # IPC sends/receives to/from this pane
```

**Viewing all hooks across panes (chronological):**
```bash
cat "$RUNTIME_DIR/debug"/*/hooks.jsonl | sort -t'"' -k4 | less
# Or with jq:
cat "$RUNTIME_DIR/debug"/*/hooks.jsonl | jq -s 'sort_by(.ts)' | jq '.[]'
```

## Log Schemas (JSONL)

### hooks.jsonl — Every hook execution

The single most valuable category. Covers pane addressing, role resolution, and tool blocking bugs.

```json
{"ts":1711300205012,"pane":"1.2","role":"worker","hook":"on-pre-tool-use","tool":"Bash","cmd":"git status","dur_ms":12,"exit":0,"action":"allow"}
{"ts":1711300205048,"pane":"1.2","role":"worker","hook":"on-pre-tool-use","tool":"Bash","cmd":"git push origin main","dur_ms":3,"exit":2,"action":"block","reason":"git/gh commands"}
{"ts":1711300206100,"pane":"1.0","role":"manager","hook":"stop-notify","tool":"","cmd":"","dur_ms":45,"exit":0,"action":"worker_to_mgr","target":"1.0","delivery":"file"}
```

Fields:
- `ts`: millisecond epoch (perl Time::HiRes on macOS, `date +%s` fallback)
- `pane`: window.pane_index
- `role`: resolved role (and source: env/file/fallback — when debug_display is on)
- `hook`: hook script name
- `tool`: tool name (for pre-tool-use, post-tool-lint)
- `cmd`: first 80 chars of command (Bash tool only)
- `dur_ms`: hook execution time
- `exit`: hook exit code (0=allow, 1=error, 2=block+feedback)
- `action`: what happened (allow/block/init/busy/finished/etc)
- Extra fields per hook (reason, target, delivery, etc)

### lifecycle.jsonl — Pane start/stop/crash

Covers auth exhaustion and startup race conditions.

```json
{"ts":1711300200000,"pane":"1.2","role":"worker","event":"session_start","agent":"doey-worker","model":"sonnet","team_window":"1","project":"my-app"}
{"ts":1711300205000,"pane":"1.2","role":"worker","event":"task_start","prompt":"Implement the auth module..."}
{"ts":1711300260000,"pane":"1.2","role":"worker","event":"stop","status":"FINISHED","files_changed":3,"tool_calls":12}
{"ts":1711300260500,"pane":"1.2","role":"worker","event":"result_captured","result_file":"pane_1_2_1711300260.json"}
```

Events: `session_start`, `task_start`, `compact`, `stop`, `result_captured`, `notification_sent`

### state.jsonl — Status transitions with timestamps

Covers race conditions between status checks and state changes.

```json
{"ts":1711300205000,"pane":"1.2","from":"READY","to":"BUSY","trigger":"on-prompt-submit"}
{"ts":1711300260000,"pane":"1.2","from":"BUSY","to":"FINISHED","trigger":"stop-status"}
```

### messages.jsonl — IPC between panes

Covers notification chain bugs (Manager↔SM, Worker→Manager delivery failures).

```json
{"ts":1711300260100,"from":"1.2","to":"1.0","type":"stop_notify","subject":"Worker done","delivery":"file","success":true}
{"ts":1711300260200,"from":"1.0","to":"0.1","type":"mgr_to_sm","subject":"Team 1 wave complete","delivery":"file","success":true}
```

## Implementation

All debug infrastructure lives in `.claude/hooks/common.sh` — see `_init_debug()`, `_debug_log()`, `_ms_now()`, `_debug_hook_entry()`, `_debug_hook_exit()`. The source code is the authoritative reference; this design doc covers the *why*, not the *what*.

Key implementation decisions:
- `debug.conf` is parsed with `while read`/`case`, never `source`d (prevents syntax errors from killing hooks)
- `_ms_now()` uses perl `Time::HiRes` (ships with macOS, ~15ms overhead, debug-only) with `date +%s` fallback
- `on-pre-tool-use.sh` uses inline debug check (no common.sh) for hot-path performance: one `stat()` when off, one `date` + `printf` when on
- Each hook adds one line (`_debug_hook_entry`) after setting `_DOEY_HOOK_NAME`

## Risk Mitigations

| Risk | Mitigation |
|------|-----------|
| debug.conf syntax error kills hooks | Parse with `while read`/`case`, never `source` |
| Concurrent writes corrupt JSONL | Per-pane files (each pane writes to own directory) |
| debug/ dir missing on first write | Lazy `mkdir -p` in `_debug_log` |
| Hot-path overhead (on-pre-tool-use) | Inline check, no common.sh, no perl. One `stat()` when off |
| Log growth | `_rotate_log` (500KB/200 lines). `/tmp/` clears on reboot |
