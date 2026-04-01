# Debug Mode Design

Flight recorder for multi-agent tmux sessions. Captures hooks, state transitions, IPC, and lifecycle.

## Bug Pattern → Log Category

| Pattern | Category |
|---|---|
| Pane addressing | `hooks` |
| Role resolution | `hooks` |
| Auth exhaustion | `lifecycle` |
| Notification chain | `messages` |
| Race conditions | `state` |
| Bash/zsh compat | N/A (syntax) |
| Install/shipping | N/A (build-time) |

## Toggle: `$RUNTIME_DIR/debug.conf`

Flat key=value, **never sourced** — parsed with `grep`/`case` to prevent syntax errors from killing hooks.

```bash
DOEY_DEBUG=true
DOEY_DEBUG_HOOKS=true
DOEY_DEBUG_LIFECYCLE=true
DOEY_DEBUG_MESSAGES=true
DOEY_DEBUG_STATE=true
DOEY_DEBUG_DISPLAY=false
```

- File existence = master toggle (`[ -f "$RUNTIME_DIR/debug.conf" ]`). No file → zero overhead (one `stat()`)
- Sub-toggles for granularity (e.g., hooks only)
- `DOEY_DEBUG_DISPLAY=true` prints to stderr

### `/doey-debug on|off|status`

- `on`: Creates `debug.conf` + `debug/` directory
- `off`: Removes `debug.conf` (keeps logs)
- `status`: Shows state, log sizes, last entries

## Log Structure

Per-pane files (atomic append not guaranteed across processes):

```
$RUNTIME_DIR/debug/
  {PANE_SAFE}/          # e.g., doey_proj_1_2/
    hooks.jsonl         # hook entry/exit, tool context, role resolution
    lifecycle.jsonl     # pane start/stop/crash, agent, model
    state.jsonl         # status transitions (READY→BUSY→FINISHED)
    messages.jsonl      # IPC sends/receives to/from this pane
```

**View chronologically:**
```bash
cat "$RUNTIME_DIR/debug"/*/hooks.jsonl | jq -s 'sort_by(.ts)' | jq '.[]'
```

## Log Schemas (JSONL)

### hooks.jsonl

```json
{"ts":1711300205012,"pane":"1.2","role":"worker","hook":"on-pre-tool-use","tool":"Bash","cmd":"git status","dur_ms":12,"exit":0,"action":"allow"}
{"ts":1711300205048,"pane":"1.2","role":"worker","hook":"on-pre-tool-use","tool":"Bash","cmd":"git push origin main","dur_ms":3,"exit":2,"action":"block","reason":"git/gh commands"}
{"ts":1711300206100,"pane":"1.0","role":"manager","hook":"stop-notify","tool":"","cmd":"","dur_ms":45,"exit":0,"action":"worker_to_mgr","target":"1.0","delivery":"file"}
```

Fields: `ts` (ms epoch), `pane`, `role`, `hook`, `tool`, `cmd` (first 80 chars), `dur_ms`, `exit` (0/1/2), `action`. Extra per-hook fields (reason, target, delivery).

### lifecycle.jsonl

```json
{"ts":1711300200000,"pane":"1.2","role":"worker","event":"session_start","agent":"doey-worker","model":"sonnet","team_window":"1","project":"my-app"}
{"ts":1711300205000,"pane":"1.2","role":"worker","event":"task_start","prompt":"Implement the auth module..."}
{"ts":1711300260000,"pane":"1.2","role":"worker","event":"stop","status":"FINISHED","files_changed":3,"tool_calls":12}
{"ts":1711300260500,"pane":"1.2","role":"worker","event":"result_captured","result_file":"pane_1_2_1711300260.json"}
```

### state.jsonl

```json
{"ts":1711300205000,"pane":"1.2","from":"READY","to":"BUSY","trigger":"on-prompt-submit"}
{"ts":1711300260000,"pane":"1.2","from":"BUSY","to":"FINISHED","trigger":"stop-status"}
```

### messages.jsonl

```json
{"ts":1711300260100,"from":"1.2","to":"1.0","type":"stop_notify","subject":"Worker done","delivery":"file","success":true}
{"ts":1711300260200,"from":"1.0","to":"0.1","type":"mgr_to_sm","subject":"Team 1 wave complete","delivery":"file","success":true}
```

## Implementation

All in `.claude/hooks/common.sh` (`_init_debug()`, `_debug_log()`, `_ms_now()`, `_debug_hook_entry/exit()`).

- `debug.conf` parsed with `while read`/`case`, never `source`d
- `_ms_now()`: perl `Time::HiRes` with `date +%s` fallback
- `on-pre-tool-use.sh`: inline debug check (no common.sh) — one `stat()` when off

## Risks

| Risk | Mitigation |
|------|-----------|
| Syntax error kills hooks | `while read`/`case`, never `source` |
| Concurrent write corruption | Per-pane files |
| Missing debug/ dir | Lazy `mkdir -p` in `_debug_log` |
| Hot-path overhead | Inline check, one `stat()` when off |
| Log growth | `_rotate_log` (500KB/200 lines). `/tmp/` clears on reboot |
