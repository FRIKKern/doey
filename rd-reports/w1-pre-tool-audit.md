# Audit: on-pre-tool-use.sh — Block Path Catalog

**File:** `.claude/hooks/on-pre-tool-use.sh`
**Date:** 2026-03-24
**Analyst:** Worker 1

---

## 1. common.sh Sourcing & Available Functions

`on-pre-tool-use.sh` sources `common.sh` **only on the slow path** (line 103):

```bash
source "$(dirname "$0")/common.sh"
```

This path is reached only when `_DOEY_ROLE` is **not** `manager`, `session_manager`, `git_agent`, or `worker` (i.e., watchdog or unknown role).

### Functions available after `init_hook` (slow path only)

| Function | Purpose |
|----------|---------|
| `init_hook()` | Resolves `RUNTIME_DIR`, `PANE`, `PANE_SAFE`, `SESSION_NAME`, `PANE_INDEX`, `WINDOW_INDEX`, `NOW` |
| `is_watchdog()` | Returns 0 if pane is a watchdog |
| `is_manager()` | Returns 0 if pane is a manager |
| `is_session_manager()` | Returns 0 if pane is session manager |
| `is_worker()` | Returns 0 if pane is a worker |
| `_log()` | Writes timestamped line to `${RUNTIME_DIR}/logs/${DOEY_PANE_ID}.log` |
| `parse_field()` | jq/grep JSON field extraction (INPUT-scoped) |
| `send_to_pane()` | tmux copy-mode + send-keys wrapper |

**Note:** On the fast paths (manager, session_manager, git_agent, worker), `init_hook` is **never called**. Only `_json_str` and `_check_blocked` are available; no `_log()` function exists there.

---

## 2. Context Variables Available Throughout

| Variable | Source | Available |
|----------|--------|-----------|
| `INPUT` | `cat` (line 6) | Always |
| `TOOL_NAME` | `_json_str tool_name` (line 36) | Always |
| `_DOEY_ROLE` | env `DOEY_ROLE` or `.role` file (lines 40–51) | Always |
| `TMUX_PANE` | env | Always (if in tmux) |
| `DOEY_RUNTIME` | env or tmux env | If in tmux |
| `_CMD` / `TOOL_COMMAND` | `_json_str tool_input.command` | Per branch |
| `RUNTIME_DIR` | `init_hook()` | Slow path only |
| `PANE`, `PANE_INDEX`, `WINDOW_INDEX` | `init_hook()` | Slow path only |
| `TEAM_WINDOW` | `${DOEY_TEAM_WINDOW:-}` (line 116) | Watchdog block only |

---

## 3. Block Path Catalog

### BLOCK-01 — Watchdog: write tool usage
- **Lines:** 56–58
- **Condition:** `TOOL_NAME` ∈ {`Edit`, `Write`, `Agent`, `NotebookEdit`} AND `_DOEY_ROLE` = `watchdog`
- **Context vars:** `TOOL_NAME`, `_DOEY_ROLE`
- **Message:** `BLOCKED: Watchdog cannot use <TOOL_NAME> — monitoring role only.`
- **Exit:** 2

---

### BLOCK-02 — Manager/Session Manager: /rename via send-keys
- **Lines:** 68–71
- **Condition:** `_DOEY_ROLE` ∈ {`manager`, `session_manager`} AND `TOOL_NAME` = `Bash` AND `tool_input.command` matches any of:
  - `tmux send-keys ... /rename ...`
  - `... && tmux send-keys ... /rename ...`
  - `... ; tmux send-keys ... /rename ...`
- **Context vars:** `_DOEY_ROLE`, `_CMD`, `_CMD_STRIPPED`
- **Message (2 lines):**
  - `BLOCKED: Never send /rename via send-keys — it opens an interactive prompt that eats the next paste.`
  - `Use: tmux select-pane -t "$PANE" -T "task-name"`
- **Exit:** 2

---

### BLOCK-03 — Git Agent: destructive rm
- **Lines:** 81–82
- **Condition:** `_DOEY_ROLE` = `git_agent` AND `TOOL_NAME` = `Bash` AND command matches:
  - `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`, `rm -rf /Users/`, `rm -rf /home/`
- **Context vars:** `_DOEY_ROLE`, `TOOL_COMMAND`
- **Message:** `BLOCKED: Git Agent cannot run destructive rm.`
- **Exit:** 2

---

### BLOCK-04 — Git Agent: shutdown/reboot
- **Lines:** 83–84
- **Condition:** `_DOEY_ROLE` = `git_agent` AND `TOOL_NAME` = `Bash` AND command matches `shutdown` or `reboot`
- **Context vars:** `_DOEY_ROLE`, `TOOL_COMMAND`
- **Message:** `BLOCKED: Git Agent cannot run system commands.`
- **Exit:** 2

---

### BLOCK-05 — Git Agent: tmux commands
- **Lines:** 85–86
- **Condition:** `_DOEY_ROLE` = `git_agent` AND `TOOL_NAME` = `Bash` AND command matches:
  - `tmux kill-session`, `tmux kill-server`, `tmux send-keys`
- **Context vars:** `_DOEY_ROLE`, `TOOL_COMMAND`
- **Message:** `BLOCKED: Git Agent cannot run tmux commands.`
- **Exit:** 2

---

### BLOCK-06 — Worker: dangerous command patterns
- **Lines:** 95–98
- **Condition:** `_DOEY_ROLE` = `worker` AND `TOOL_NAME` = `Bash` AND command matches `_check_blocked` patterns:
  - `git push`, `git commit`, `gh pr create`, `gh pr merge` → `MSG="git/gh commands"`
  - `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`, `rm -rf /Users/`, `rm -rf /home/` → `MSG="destructive rm"`
  - `shutdown`, `reboot` → `MSG="system commands"`
  - `tmux kill-session`, `tmux kill-server`, `tmux send-keys` → `MSG="tmux commands"`
- **Context vars:** `_DOEY_ROLE`, `TOOL_COMMAND`, `MSG` (set by `_check_blocked`)
- **Message:** `BLOCKED: Workers cannot run <MSG>. Only the Window Manager can do this.`
- **Exit:** 2

---

### BLOCK-07 — Watchdog (slow path): send-keys to crashed Manager
- **Lines:** 119–123
- **Condition:** Slow path (`_DOEY_ROLE` unknown/watchdog), `is_watchdog()` true, command contains `send-keys`/`send-key`/`paste-buffer`/`load-buffer`, `DOEY_TEAM_WINDOW` is set, crash file `${RUNTIME_DIR}/status/manager_crashed_W${TEAM_WINDOW}` exists, and command targets pane `:${TEAM_WINDOW}.0`
- **Context vars:** `TOOL_COMMAND`, `TEAM_WINDOW`, `RUNTIME_DIR`, `_WP` (pane ref)
- **Message (2 lines):**
  - `BLOCKED: Watchdog cannot send keys to crashed Manager pane ${TEAM_WINDOW}.0.`
  - `Write an alert file for the Session Manager instead.`
- **Exit:** 2

---

### BLOCK-08 — Watchdog (slow path): unauthorized keystroke send
- **Lines:** 133–135
- **Condition:** Slow path, `is_watchdog()` true, command contains `send-keys`/`send-key`/`paste-buffer`/`load-buffer`, AND does NOT match any of these allowlisted patterns:
  - `tmux copy-mode` (exact prefix match, line 126)
  - Target is own team window's manager pane `:${TEAM_WINDOW}.0` (line 128)
  - `tmux send-keys -t <target> "/login" Enter` or `"/compact" Enter` (line 131)
  - `tmux send-keys -t <target> Enter` (bare Enter, line 132)
- **Context vars:** `TOOL_COMMAND`, `CLEAN_CMD` (2>/dev/null stripped), `TEAM_WINDOW`, `RUNTIME_DIR`
- **Message (2 lines):**
  - `BLOCKED: Watchdog cannot send keystrokes to worker panes.`
  - `Report stuck workers to the Window Manager instead.`
- **Exit:** 2

---

### BLOCK-09 — Watchdog/Unknown (slow path): dangerous command patterns
- **Lines:** 140–143
- **Condition:** Slow path, `is_watchdog()` OR unknown role, command matches `_check_blocked` patterns (same as BLOCK-06)
- **Context vars:** `TOOL_COMMAND`, `MSG`, `ROLE` (= `"Workers"` or `"Watchdog"`)
- **Message:** `BLOCKED: <ROLE> cannot run <MSG>. Only the Window Manager can do this.`
- **Exit:** 2

---

## 4. Summary Table

| # | Role | Tool | Trigger | Exit |
|---|------|------|---------|------|
| BLOCK-01 | watchdog | Edit/Write/Agent/NotebookEdit | Any non-Bash write tool | 2 |
| BLOCK-02 | manager, session_manager | Bash | send-keys + /rename | 2 |
| BLOCK-03 | git_agent | Bash | destructive rm | 2 |
| BLOCK-04 | git_agent | Bash | shutdown/reboot | 2 |
| BLOCK-05 | git_agent | Bash | tmux kill/send-keys | 2 |
| BLOCK-06 | worker | Bash | git/gh, rm, shutdown, tmux | 2 |
| BLOCK-07 | watchdog (slow) | Bash | send-keys to crashed manager pane | 2 |
| BLOCK-08 | watchdog (slow) | Bash | send-keys to non-allowlisted targets | 2 |
| BLOCK-09 | watchdog/unknown (slow) | Bash | git/gh, rm, shutdown, tmux | 2 |

**Total distinct block types: 9**
**Exit codes used:** 2 only (block + feedback). Exit code 1 is never used.

---

## 5. Observations & Notes

1. **Exit 1 never used.** All blocks use exit 2 (block + feedback). Exit 1 (block + error) is absent.

2. **Fast vs slow path asymmetry.** Roles `manager`, `session_manager`, `git_agent`, `worker` use a fast path that skips `init_hook`. Roles `watchdog` and unknown fall through to the slow path which calls `init_hook` and sources `common.sh`. This means `_log()` is only available in the watchdog/slow-path blocks.

3. **`_check_blocked` is a shared utility** used by both BLOCK-06 (worker fast path) and BLOCK-09 (slow path). It sets `MSG` as a side effect. It trims leading/trailing whitespace and collapses internal spaces before pattern matching.

4. **Watchdog BLOCK-07 is gated by a crash-file sentinel.** The file `manager_crashed_W${TEAM_WINDOW}` must exist on disk for the crash-manager block to fire — without it, even pane `.0` targeting flows through to BLOCK-08's allowlist logic.

5. **Watchdog allowlist (BLOCK-08) uses `CLEAN_CMD`** — the command with trailing `2>/dev/null` stripped — for regex matching. Commands with inline redirects elsewhere may not be normalized.

6. **Role resolution order.** `_DOEY_ROLE` prefers the per-pane `.role` file over the `DOEY_ROLE` env var (lines 41–51), because tmux session env is shared and can be stale. The slow path's `is_watchdog()`/`is_manager()` uses team env files and pane index comparison as a secondary check.
