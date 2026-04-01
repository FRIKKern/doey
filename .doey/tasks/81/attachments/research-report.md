# Research Report: Worker Observability (Task #81, S1)

## 1. Claude Code Output Capabilities

### CLI Output Modes

The `claude` CLI has three output modes via `--output-format` (requires `--print`):

| Mode | Flag | Description |
|------|------|-------------|
| Text | `--output-format text` | Default, plain text output |
| JSON | `--output-format json` | Single JSON result on completion |
| Stream JSON | `--output-format stream-json` | Real-time JSONL streaming |

**Key flags for observability:**
- `--include-hook-events` — includes all hook lifecycle events in the output stream (stream-json only)
- `--include-partial-messages` — includes partial message chunks as they arrive (stream-json only)
- `--debug` / `--debug-file <path>` — writes debug logs to stderr or a file
- `--verbose` — overrides verbose mode setting

**However:** Doey workers run in interactive mode (no `--print`), so `--output-format` is **not available**. Interactive sessions write to the terminal, not stdout.

### Local File Storage

| Path | Contents |
|------|----------|
| `~/.claude/sessions/*.json` | Session metadata: `{pid, sessionId, cwd, startedAt, kind, entrypoint, name}` |
| `~/.claude/projects/<project-hash>/*.jsonl` | Full conversation transcripts (JSONL, one entry per message) |
| `~/.claude/projects/<project-hash>/` | Also contains: session dirs, memory files, MEMORY.md |

**Session files** (`~/.claude/sessions/`) are small metadata files (~75 bytes) — useful for mapping PIDs to session IDs but no activity data.

**Conversation JSONL files** (`~/.claude/projects/.../*.jsonl`) contain the full conversation history. These are large and written incrementally. They could be tailed for real-time activity, but:
- Path is hashed (project path → UUID directory)
- Files are keyed by session UUID, not pane ID
- Format is internal and may change between versions

### stderr Behavior

Claude Code writes interactive UI chrome (spinners, progress bars, the `>` prompt) to stderr. No structured data on stderr unless `--debug` is enabled. With `--debug-file /path`, debug output goes to a file — this includes API call timing, tool execution, and internal state changes.

### Recommendation for Q1

**Best option for live worker activity:** `tmux capture-pane` (already used by `stop-results.sh`) or `tmux pipe-pane` for continuous capture. The `--debug-file` flag could provide structured activity data but would require modifying how workers are launched.

---

## 2. Existing Worker Status Infrastructure

### Hook Data Flow

```
on-prompt-submit.sh          → writes .status file (BUSY + first 80 chars of prompt)
  ↓ [worker runs]
stop-status.sh (sync)        → writes .status file (FINISHED/RESERVED/READY)
                              → writes task metadata (TASK_ID, LAST_TASK_TAGS, LAST_FILES)
                              → writes .status to persistent .doey/tasks/<id>.status
                              → notifies SM via message file
stop-results.sh (async)      → writes results JSON (pane_*.json)
                              → writes completion event file
                              → copies result to .doey/tasks/<id>.result.json
                              → attaches output as task attachment
stop-notify.sh (async)       → notification chain to manager/SM/desktop
```

### Status File Format (`RUNTIME_DIR/status/<pane_safe>.status`)

```
PANE: doey-doey:1.1
UPDATED: 2026-04-01T06:22:25+0000
STATUS: BUSY
TASK: You are Worker 1 on the Doey team for project: doey...
```

Additional fields appended on FINISHED:
```
TASK_ID: 79
LAST_TASK_TAGS: <tags>
LAST_TASK_TYPE: <type>
LAST_FILES: file1.sh|file2.go|...
```

### Result JSON Format (`RUNTIME_DIR/results/pane_W_P.json`)

```json
{
  "pane": "1.1",
  "pane_id": "...",
  "full_pane_id": "...",
  "title": "Worker 1",
  "status": "done|error",
  "timestamp": 1774991741,
  "files_changed": ["shell/doey.sh", ...],
  "tool_calls": 42,
  "last_output": "...(captured terminal output)...",
  "task_id": "79",
  "hypothesis_updates": [],
  "evidence": [],
  "needs_follow_up": false,
  "summary": "..."
}
```

### Completion Event Format (`RUNTIME_DIR/status/completion_pane_W_P`)

```
PANE_INDEX="1"
PANE_TITLE="Worker 1"
STATUS="done"
TIMESTAMP=1774991741
```

### Heartbeat Files (`RUNTIME_DIR/status/<pane_safe>.heartbeat`)

Single line: `<epoch_seconds>  <pane_safe_name>`

### Other Runtime Files

| File | Purpose |
|------|---------|
| `context_pct_W_P` | Context window usage percentage (1-3 chars) |
| `*.role` | Pane role string (e.g., "boss", "session_manager") |
| `sm_trigger` | Touch file to wake Session Manager |
| `col_N.collapsed` | Marker for collapsed worker columns |

### Logging Infrastructure

- `_log()` in `common.sh` → writes to `RUNTIME_DIR/logs/<DOEY_PANE_ID>.log`
- `_log_error()` → writes to both per-pane log and shared `errors/errors.log`
- `_debug_log()` → JSONL to per-pane category files in `RUNTIME_DIR/debug/<pane>/`
- **Issue observed:** Only `unknown.log` exists in `/tmp/doey/doey/logs/`, meaning `DOEY_PANE_ID` is not being set for all hooks (likely due to `on-session-start.sh` exit code 1 errors seen in `errors.log`)

### What's Missing

1. **No live activity stream** — status files are point-in-time snapshots, not events
2. **No task label on pane borders** — status files have TASK_ID but it's not surfaced in pane borders
3. **No tool-call-by-tool-call feed** — only aggregate tool count on completion
4. **No duration tracking** — start timestamp is written but elapsed time isn't computed

---

## 3. Pane Border Task Labels

### Current Implementation (`shell/pane-border-status.sh`, 62 lines)

The script is called by tmux via `pane-border-format`:
```
#('${SCRIPT_DIR}/pane-border-status.sh' #{session_name}:#{window_index}.#{pane_index})
```

**What it renders:**
- Window 0: Session Manager panes show `<project> SM`, watchdog panes show `<project> T<n> WD`
- Worker panes: `<pane_title>` + lock icon if reserved
- Falls back to tmux `pane_title` for unrecognized panes
- Prefixes with `FULL_PANE_ID` if available

**Data available at render time:**
- tmux pane_title (set by hooks)
- tmux pane environment variables (`DOEY_FULL_PANE_ID`)
- Runtime directory (`DOEY_RUNTIME` from tmux environment)
- All status files in `RUNTIME_DIR/status/`

### Adding Task Labels

The pane-border-status script already reads `RUNTIME_DIR` and constructs the pane safe name. To add task ID/title:

```bash
# After line 59 (reserved check), before final output:
_STATUS_FILE="${RUNTIME_DIR}/status/${PANE_SAFE}.status"
_TASK_LABEL=""
if [ -f "$_STATUS_FILE" ]; then
  _tid=$(grep '^TASK_ID:' "$_STATUS_FILE" | head -1 | cut -d' ' -f2-)
  [ -n "$_tid" ] && _TASK_LABEL=" #${_tid}"
fi
_prefix_id "${TITLE}${_TASK_LABEL}"
```

**Task title** could also be read from `.doey/tasks/<id>.task` → `TASK_TITLE=` field, but:
- Requires knowing PROJECT_DIR (available from session.env)
- Each tmux refresh invokes this script once per pane — keep it fast
- Reading one extra file is acceptable; parsing task title adds ~2ms

### tmux pane-border-format

tmux's `pane-border-format` supports:
- All `#{}` format variables (pane_title, pane_index, etc.)
- Shell command execution via `#(command)`
- Conditional formatting via `#{?condition,true,false}`
- Style attributes via `#[fg=color,bold]`

The current format runs `pane-border-status.sh` on every status-interval refresh (default: configurable, typically 5-15s). Adding a task label lookup is within performance budget.

### Recommendation

Add task ID to pane borders via the status file (already written by `on-prompt-submit.sh`). Optionally add a short task title (truncated to ~20 chars) from the `.task` file. This gives instant visibility into which worker is doing what.

---

## 4. Activity Feed Format Evaluation

### Option A: JSONL File Per Worker

```
RUNTIME_DIR/activity/<pane_safe>.jsonl
```

| Criterion | Assessment |
|-----------|------------|
| Write frequency | Per hook event (prompt-submit, tool-use, stop) — 1-50/min per worker |
| Read latency | `tail -f` friendly, instant |
| File rotation | Use existing `_rotate_log()` (>500KB → keep last 200 lines) |
| Multi-reader safety | Excellent — append-only, multiple `tail -f` safe |
| Implementation complexity | Low — add `_activity()` helper to `common.sh`, call from existing hooks |
| TUI integration | Good — TUI reader can poll per-file, merge in memory |
| Dashboard integration | Good — `tail -f` or periodic read in info-panel |
| Disk usage | ~1KB per event, ~50KB/worker/hour at peak |

**Format:**
```json
{"ts":1774991741,"pane":"1.1","event":"prompt","task_id":"79","detail":"...first 80 chars..."}
{"ts":1774991745,"pane":"1.1","event":"tool","tool":"Bash","detail":"git status"}
{"ts":1774991800,"pane":"1.1","event":"stop","status":"done","tools":42,"files":3}
```

### Option B: Single Aggregate Stream

```
RUNTIME_DIR/activity/stream.jsonl
```

| Criterion | Assessment |
|-----------|------------|
| Write frequency | All workers interleaved — 5-200 events/min total |
| Read latency | `tail -f` friendly, instant |
| File rotation | Needs rotation — grows faster than per-worker files |
| Multi-reader safety | Risk — concurrent appends from multiple hook processes may interleave lines. Mitigated by atomic `printf` (POSIX guarantees atomic writes <=PIPE_BUF=4096 bytes) |
| Implementation complexity | Low — same as A but single file |
| TUI integration | Simpler — one file to poll |
| Dashboard integration | Simple — one `tail -f` |
| Disk usage | Same total as A, single file |

**Risk:** If two hooks fire simultaneously (e.g., two workers stopping), appends may interleave mid-line if the JSON exceeds PIPE_BUF. Per-worker files avoid this entirely.

### Option C: tmux pipe-pane

```bash
tmux pipe-pane -o -t "$pane" 'cat >> RUNTIME_DIR/capture/<pane_safe>.raw'
```

| Criterion | Assessment |
|-----------|------------|
| Write frequency | Continuous — every terminal character |
| Read latency | Real-time terminal output capture |
| File rotation | Needs aggressive rotation — raw terminal output is huge (~10KB/sec during active work) |
| Multi-reader safety | Excellent — single writer per pane |
| Implementation complexity | Low to set up, HIGH to parse — raw output includes ANSI escapes, cursor movement, line wrapping |
| TUI integration | Poor — raw terminal data needs heavy filtering to extract meaningful events |
| Dashboard integration | Only useful for "last N lines" display, not structured activity |
| Disk usage | **Very high** — ~36MB/worker/hour at peak |

**Also:** `pipe-pane` is limited to one command per pane. If Doey later needs pipe-pane for another purpose, this conflicts.

### Recommendation

**Option A (JSONL per worker)** is the clear winner:
- No concurrency risk (one writer per file)
- `tail -f` friendly for shell consumers
- Easy to merge in Go for TUI
- Structured data without parsing raw terminal output
- Low disk usage with existing rotation infrastructure
- Can be extended incrementally (add events to existing hooks)

---

## 5. TUI Integration: Where Should Activity Live?

### Option 1: TUI Logs Tab — Add "Activity" Sub-Tab

**Current Logs Group structure** (`logsgroup.go`):

```go
var logsGroupItems = []logsGroupEntry{
    {icon: "◆", name: "Logs", desc: "Live log stream"},      // cursor 0
    {icon: "→", name: "Messages", desc: "IPC messages"},     // cursor 1
    {icon: "•", name: "Debug", desc: "Flight recorder"},     // cursor 2
    {icon: "›", name: "Info", desc: "Session overview"},     // cursor 3
}
```

The `LogsGroupModel` uses a split-pane layout (33% left selector, 67% right content) with 4 sub-models. Each sub-model implements `SetSnapshot()`, `SetSize()`, `SetFocused()`, `Update()`, and `View()`.

**Adding an Activity sub-tab would require:**
1. New `ActivityModel` struct (~100-150 lines, similar to `LogViewModel`)
2. Add entry to `logsGroupItems` array
3. Add field + wiring in `LogsGroupModel` (cursor case 4)
4. Add activity data to `runtime.Snapshot` (parsed from JSONL files)
5. Add JSONL reader to `runtime/reader.go`

**Effort:** Medium. The pattern is well-established — copy `LogViewModel` structure.

**Fit:** Good. The Logs tab is already the observability home. Activity fits naturally alongside Logs, Messages, and Debug.

### Option 2: Shell Info Panel (`info-panel.sh`)

**Current info-panel structure** (633 lines):
- Refreshes every 5 minutes (configurable `DOEY_INFO_PANEL_REFRESH`)
- Shows: header, session info, team grid with worker statuses, command reference
- Uses `read_pane_status()` to show per-worker status (BUSY/READY/FINISHED/etc.)
- Lives in pane 0.0 — user lands here on attach

**Adding activity would require:**
1. New section in the render loop that tails activity JSONL files
2. Parse JSONL with `jq` or line-by-line bash
3. Format and display recent events

**Challenges:**
- Info panel refreshes every 5 minutes — not real-time
- Adding `tail -f` would require background process + live update (currently a simple loop)
- The panel is already information-dense
- bash JSONL parsing is slow compared to Go

**Fit:** Poor for live streaming. Could work for "last 5 events" summary at the bottom.

### Option 3: Hybrid — Both

- **TUI Activity sub-tab:** Full scrollable activity stream with filtering
- **Info Panel:** Last 3-5 events as a quick summary section (no streaming, just periodic read)

### Recommendation

**Primary: TUI Logs tab** with a new "Activity" sub-tab. The infrastructure is purpose-built for this — snapshot polling, split-pane layout, keyboard/mouse navigation, auto-scroll. The `LogViewModel` is a direct template.

**Secondary: Info Panel** can show a "Recent Activity" summary (last 5 events) read from the same JSONL files. Low effort since it's just periodic file reads.

---

## Summary of Recommendations

| Area | Recommendation |
|------|---------------|
| Activity data format | **JSONL per worker** (`RUNTIME_DIR/activity/<pane>.jsonl`) |
| Event sources | Existing hooks: `on-prompt-submit.sh` (task start), `on-pre-tool-use.sh` (tool use), `stop-status.sh` (completion) |
| Pane border labels | Add task ID from `.status` file in `pane-border-status.sh` (~5 lines) |
| TUI display | New "Activity" sub-tab in Logs group (follow `LogViewModel` pattern) |
| Shell display | "Recent Activity" summary in info-panel (periodic read, last 5 events) |
| Worker launch | Consider `--debug-file` for structured debug output (future enhancement) |
| Logging fix | Investigate why `DOEY_PANE_ID` is not set (all logs go to `unknown.log`) |

### Implementation Priority

1. **Pane border task labels** — smallest change, highest immediate value
2. **Activity JSONL writer** — `_activity()` helper in `common.sh`, call from 3 hooks
3. **TUI Activity sub-tab** — follows established pattern, medium effort
4. **Info panel summary** — optional, low priority
