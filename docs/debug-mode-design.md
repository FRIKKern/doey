# Doey Debug Mode — Design Document

## Motivation

122 bug-fix commits across 5 recurring patterns. When things go wrong in a multi-agent tmux session, reconstructing what happened requires manually reading status files, capture-pane, git log, and errors.log. Debug mode provides a flight recorder that captures the full story automatically.

## Bug Pattern → Log Category Mapping

Grounded in real commit history, not speculation:

| Bug Pattern (commit count) | What would help debug it | Log Category |
|---|---|---|
| Pane addressing (18+) | Which pane was targeted, resolved address, role applied | `hooks` |
| Watchdog loops (10+) | Full scan results, state detected, action taken, cooldown | `watchdog` |
| Role resolution (8+) | Role source (env var vs file vs fallback), stale detection | `hooks` |
| Auth exhaustion (5+) | Instance start times, launch stagger, rate limit hits | `lifecycle` |
| Notification chain (5+) | Message from→to, delivery method, success/failure | `messages` |
| Race conditions (8+) | Timing of concurrent ops, lock contention, state transitions | `state` |
| Bash/zsh compat (8+) | N/A — syntax issues, not runtime | (not logged) |
| Install/shipping (12+) | N/A — build-time issues, not runtime | (not logged) |

## Toggle Mechanism (WordPress-style)

### Config file: `$RUNTIME_DIR/debug.conf`

Flat key=value format. **Never sourced** — parsed with `grep`/`case` to prevent syntax errors from killing hooks.

```bash
DOEY_DEBUG=true
DOEY_DEBUG_HOOKS=true
DOEY_DEBUG_WATCHDOG=true
DOEY_DEBUG_LIFECYCLE=true
DOEY_DEBUG_MESSAGES=true
DOEY_DEBUG_STATE=true
DOEY_DEBUG_DISPLAY=false
```

- File existence IS the master toggle (`[ -f "$RUNTIME_DIR/debug.conf" ]`)
- When file doesn't exist: zero overhead (one `stat()` syscall, ~0.05ms)
- Sub-toggles allow granularity (e.g., just hooks, just watchdog)
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
  watchdog_W{N}.jsonl   # single-writer: watchdog scan details per team
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

### watchdog_W{N}.jsonl — Scan details per team

Single-writer (one watchdog per team). Covers watchdog behavior loops.

```json
{"ts":1711300230000,"window":1,"cycle":42,"dur_ms":450,"panes":{"1":{"state":"WORKING","hash_changed":true,"cpu_delta":12},"2":{"state":"IDLE","hash_changed":false},"3":{"state":"IDLE","hash_changed":false}},"anomalies":[]}
{"ts":1711300260000,"window":1,"cycle":43,"dur_ms":380,"panes":{"1":{"state":"IDLE","hash_changed":true},"2":{"state":"IDLE","hash_changed":false},"3":{"state":"IDLE","hash_changed":false}},"anomalies":[],"wave_complete":true}
{"ts":1711300290000,"window":1,"cycle":44,"dur_ms":520,"panes":{"1":{"state":"IDLE"},"2":{"state":"STUCK","hash_changed":false,"stuck_count":3}},"anomalies":["PROMPT_STUCK:2"]}
```

## Implementation in common.sh

### Config parsing (safe, never sourced)

```bash
# Parse debug.conf as flat key=value. Never source it.
_init_debug() {
  _DOEY_DEBUG=""
  _DOEY_DEBUG_HOOKS=""
  _DOEY_DEBUG_LIFECYCLE=""
  _DOEY_DEBUG_STATE=""
  _DOEY_DEBUG_MESSAGES=""
  _DOEY_DEBUG_WATCHDOG=""
  _DOEY_DEBUG_DISPLAY=""
  [ -f "${RUNTIME_DIR}/debug.conf" ] || return 0
  while IFS='=' read -r _dk _dv; do
    case "$_dk" in
      DOEY_DEBUG)           _DOEY_DEBUG="$_dv" ;;
      DOEY_DEBUG_HOOKS)     _DOEY_DEBUG_HOOKS="$_dv" ;;
      DOEY_DEBUG_LIFECYCLE) _DOEY_DEBUG_LIFECYCLE="$_dv" ;;
      DOEY_DEBUG_STATE)     _DOEY_DEBUG_STATE="$_dv" ;;
      DOEY_DEBUG_MESSAGES)  _DOEY_DEBUG_MESSAGES="$_dv" ;;
      DOEY_DEBUG_WATCHDOG)  _DOEY_DEBUG_WATCHDOG="$_dv" ;;
      DOEY_DEBUG_DISPLAY)   _DOEY_DEBUG_DISPLAY="$_dv" ;;
    esac
  done < "${RUNTIME_DIR}/debug.conf"
}
```

### Millisecond timing (macOS bash 3.2 compatible)

```bash
_ms_now() {
  /usr/bin/perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000' 2>/dev/null \
    || echo "$(date +%s)000"
}
```

perl ships with macOS, Time::HiRes is a core module, ~15ms overhead (debug-only).

### Debug log writer

```bash
# Write JSONL to per-pane category file. No-op when debug off.
# Usage: _debug_log <category> <msg> [key=value ...]
_debug_log() {
  [ "${_DOEY_DEBUG:-}" = "true" ] || return 0
  local cat="$1" msg="$2"; shift 2
  local pane_dir="${RUNTIME_DIR}/debug/${PANE_SAFE:-unknown}"
  [ -d "$pane_dir" ] || mkdir -p "$pane_dir" 2>/dev/null
  local ts; ts=$(_ms_now)
  local extras=""
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    extras="${extras},\"${k}\":\"${v}\""
  done
  printf '{"ts":%s,"pane":"%s","role":"%s","cat":"%s","msg":"%s"%s}\n' \
    "$ts" "${PANE:-unknown}" "${DOEY_ROLE:-unknown}" "$cat" "$msg" "$extras" \
    >> "${pane_dir}/${cat}.jsonl" 2>/dev/null
  [ "${_DOEY_DEBUG_DISPLAY:-}" = "true" ] && \
    printf '[DOEY-DEBUG] %s %s %s\n' "$cat" "$msg" "$*" >&2
  return 0
}
```

### Hook entry/exit timing

```bash
_debug_hook_entry() {
  [ "${_DOEY_DEBUG_HOOKS:-}" = "true" ] || return 0
  _HOOK_START_MS=$(_ms_now)
  _debug_log hooks "entry" "hook=${_DOEY_HOOK_NAME:-unknown}"
  trap '_debug_hook_exit $?' EXIT
}

_debug_hook_exit() {
  [ "${_DOEY_DEBUG_HOOKS:-}" = "true" ] || return 0
  local exit_code="${1:-0}" end_ms dur_ms
  end_ms=$(_ms_now)
  dur_ms=$(( end_ms - ${_HOOK_START_MS:-$end_ms} ))
  [ "$dur_ms" -lt 0 ] && dur_ms=0
  _debug_log hooks "exit" "hook=${_DOEY_HOOK_NAME:-unknown}" "dur_ms=$dur_ms" "exit=$exit_code"
}
```

### Integration into init_hook()

```bash
init_hook() {
  if [ -z "${INPUT:-}" ]; then INPUT=$(cat); fi
  [ -z "${TMUX_PANE:-}" ] && exit 0
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) || exit 0
  [ -z "$RUNTIME_DIR" ] && exit 0
  PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}:#{window_index}.#{pane_index}') || exit 0
  PANE_SAFE=${PANE//[-:.]/_}
  SESSION_NAME="${PANE%%:*}"
  PANE_INDEX="${PANE##*.}"
  local wp="${PANE#*:}"
  WINDOW_INDEX="${wp%.*}"
  NOW=$(date '+%Y-%m-%dT%H:%M:%S%z')
  _ensure_dirs
  _init_debug    # <-- NEW: load debug config after RUNTIME_DIR is set
}
```

### Per-hook integration (one new line each)

```bash
# In each hook, after _DOEY_HOOK_NAME= line:
_DOEY_HOOK_NAME="stop-status"
_debug_hook_entry                   # <-- add this line
```

### on-pre-tool-use.sh (hot path — lightweight)

Does NOT source common.sh. Minimal inline check:

```bash
# Near top, after _RD is resolved:
_DBG=false
[ -n "$_RD" ] && [ -f "$_RD/debug.conf" ] && _DBG=true

# At exit points:
if [ "$_DBG" = "true" ]; then
  _pdir="$_RD/debug/${_PS:-unknown}"
  [ -d "$_pdir" ] || mkdir -p "$_pdir" 2>/dev/null
  printf '{"ts":"%s","pane":"%s","role":"%s","cat":"hooks","msg":"%s","hook":"on-pre-tool-use","tool":"%s"}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$_WP" "$_DOEY_ROLE" "$_action" "$TOOL_NAME" \
    >> "$_pdir/hooks.jsonl" 2>/dev/null
fi
```

Cost when off: one `[ -f ]` stat. Cost when on: one `date` + one `printf >>`. No perl, no subprocesses beyond date.

## Integration Points Summary

| File | Change | Lines | Category logged |
|------|--------|-------|-----------------|
| `common.sh` | `_init_debug`, `_debug_log`, `_ms_now`, hook entry/exit | ~60 | (infrastructure) |
| `common.sh` `init_hook()` | Add `_init_debug` call | 1 | — |
| `on-session-start.sh` | `_debug_hook_entry` + lifecycle events | ~5 | hooks, lifecycle |
| `on-prompt-submit.sh` | `_debug_hook_entry` + state transition | ~3 | hooks, state |
| `on-pre-tool-use.sh` | Lightweight inline debug (no common.sh) | ~8 | hooks |
| `on-pre-compact.sh` | `_debug_hook_entry` | 1 | hooks |
| `post-tool-lint.sh` | `_debug_hook_entry` | 1 | hooks |
| `stop-status.sh` | `_debug_hook_entry` + state transition | ~3 | hooks, state |
| `stop-results.sh` | `_debug_hook_entry` + lifecycle event | ~3 | hooks, lifecycle |
| `stop-notify.sh` | `_debug_hook_entry` + message event | ~5 | hooks, messages |
| `watchdog-scan.sh` | Cycle logging (inline, own file) | ~15 | watchdog |
| `watchdog-wait.sh` | Wake event | ~3 | watchdog |
| `session-manager-wait.sh` | Wake event | ~3 | watchdog |
| `.claude/skills/doey-debug/SKILL.md` | New skill | ~50 | — |

**Total: ~160 lines of new code. Zero behavioral change when debug is off.**

## Risk Mitigations (from Critic)

| Risk | Mitigation |
|------|-----------|
| debug.conf syntax error kills hooks | Parse with `while read`/`case`, never `source` |
| Concurrent writes corrupt JSONL | Per-pane files (each pane writes to own directory) |
| debug/ dir missing on first write | Lazy `mkdir -p` in `_debug_log`, skill creates dir on `on` |
| Hot-path overhead (on-pre-tool-use) | Inline check, no common.sh, no perl. One `stat()` when off |
| Watchdog scan drift | Own log file, non-blocking writes, cap line size |
| Log growth | `_rotate_log` on debug files (existing pattern). `/tmp/` clears on reboot |

## Log Rotation

Apply existing `_rotate_log()` (500KB threshold, keep last 200 lines) to debug JSONL files. Call from `_debug_log` every N writes (e.g., every 100th call, checked via a counter variable) to avoid stat-on-every-write overhead.

## What This Does NOT Cover (Intentionally)

- **Bash/shell command logging**: Every Bash tool call's full output. Too noisy, too large. The hook timing + tool name + exit code is sufficient.
- **Context window tracking**: Claude's internal context consumption. Not observable from hooks.
- **Agent reload/settings**: One-time events, visible in session start logs.
- **Performance profiling**: Millisecond-level timing per hook IS included. System-level CPU/memory is watchdog's domain (already in watchdog scans).
