# Worktree Feature — Test Guide

## Prerequisites

- Clean git repo (no uncommitted changes on main)
- No running Doey session (`doey stop` first)
- macOS with bash 3.2

## Common Setup

Most tests need the runtime dir and session name. Set these once:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION=$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)
```

---

## Test 1: Fresh Launch (4th team auto-isolated)

Tests `add_dynamic_team_window` with `"auto"` worktree spec during init.

```bash
doey stop 2>/dev/null; doey
```

**Verify:**

| Check | Command | Expected |
|-------|---------|----------|
| 5 windows (0-4) | `tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}'` | Window 4 has `[wt]` in name |
| Worktree branch | `git worktree list` | Entry for `team-4` on `doey/team-4-MMDD-HHMM` |
| Team env vars | `cat "$RUNTIME_DIR/team_4.env"` | Has `WORKTREE_DIR` and `WORKTREE_BRANCH` |
| Settings copied | `ls /tmp/doey/*/worktrees/team-4/.claude/settings.local.json` | File exists |
| Worker CWD | `tmux display-message -t "$SESSION:4.1" -p '#{pane_current_path}'` | Worktree path |
| Info panel badge | `tmux capture-pane -t "$SESSION:0.0" -p \| grep -i "team.*wt\|worktree"` | Team 4 with `[wt]` badge |

---

## Test 2: CLI `doey add-team --worktree`

```bash
doey add-team --worktree
```

**Verify:**

| Check | Command | Expected |
|-------|---------|----------|
| New window exists | `tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}'` | New window (probably 5) |
| Worktree created | `git worktree list` | Entry for new team |
| Team env | `cat "$RUNTIME_DIR/team_5.env" \| grep WORKTREE` | Has worktree vars |
| Session updated | `grep TEAM_WINDOWS "$RUNTIME_DIR/session.env"` | Includes new window |

---

## Test 3: CLI `doey add-team` (no worktree — backward compat)

```bash
doey add-team 3x2
```

**Verify:** New window exists without `[wt]` in name. `team_N.env` has empty `WORKTREE_DIR`. Workers CWD is main project dir.

---

## Test 4: `/doey-add-window --worktree` (slash command)

Run inside any Claude Code pane:
```
/doey-add-window --worktree
```

**Verify:** Same as Test 2 — new team window with worktree isolation.

---

## Test 5: `/doey-worktree W` (transform existing team)

Transforms a running non-worktree team into an isolated worktree. Team must have all idle workers.

```
/doey-worktree 1
```

**Verify:**

| Check | Command | Expected |
|-------|---------|----------|
| Window renamed | `tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' \| grep "^1 "` | `1 T1 [worktree]` |
| Worktree exists | `git worktree list \| grep team-1` | Entry present |
| Team env updated | `cat "$RUNTIME_DIR/team_1.env" \| grep WORKTREE` | Has worktree vars |
| Worker CWD | `tmux display-message -t "$SESSION:1.1" -p '#{pane_current_path}'` | Worktree path |

---

## Test 6: `/doey-worktree W --back` (return to main)

Reverses a worktree transformation. Run after Test 5.

Optionally create a file in the worktree first to test auto-save:
```bash
WT_DIR=$(grep WORKTREE_DIR "$RUNTIME_DIR/team_1.env" | cut -d= -f2- | tr -d '"')
echo "test" > "$WT_DIR/worktree-test.txt"
```

```
/doey-worktree 1 --back
```

**Verify:**

| Check | Command | Expected |
|-------|---------|----------|
| Auto-commit (if dirty) | `git log --oneline "$BRANCH" -3` | WIP commit if changes existed |
| Worktree removed | `git worktree list \| grep team-1` | No match |
| Team env cleaned | `cat "$RUNTIME_DIR/team_1.env" \| grep WORKTREE` | No worktree vars |
| Window name restored | `tmux list-windows ... \| grep "^1 "` | `1 T1` (no `[worktree]`) |
| Worker CWD | `tmux display-message -t "$SESSION:1.1" -p '#{pane_current_path}'` | Main project dir |
| Branch preserved | `git branch \| grep doey/team-1` | Branch still exists |

---

## Test 7: `/doey-list-windows` (worktree badge)

```
/doey-list-windows
```
Or: `doey list-teams`

**Verify:** `[worktree]` badge and branch name for worktree teams; nothing extra for normal teams.

---

## Test 8: `/doey-kill-window W` (kill worktree team)

Setup — make a change in a worktree team (e.g., team 4):
```bash
WT_DIR=$(grep WORKTREE_DIR "$RUNTIME_DIR/team_4.env" | cut -d= -f2- | tr -d '"')
echo "kill-test" > "$WT_DIR/kill-test.txt"
git -C "$WT_DIR" add -A && git -C "$WT_DIR" commit -m "test commit in worktree"
```

```
/doey-kill-window 4
```

**Verify:**

| Check | Command | Expected |
|-------|---------|----------|
| Worktree removed | `ls /tmp/doey/*/worktrees/team-4 2>/dev/null` | No such directory |
| Git pruned | `git worktree list \| grep team-4` | No match |
| Branch preserved | `git branch \| grep doey/team-4` | Branch exists (had commits) |
| Runtime cleaned | `ls "$RUNTIME_DIR/team_4.env" 2>/dev/null` | No such file |
| Window gone | `tmux list-windows -t "$SESSION" -F '#{window_index}' \| grep "^4$"` | No match |

---

## Test 9: `doey stop` (full teardown with worktrees)

```bash
doey stop
```

**Verify:** `git worktree list` shows only main tree. Branches with commits preserved. Session gone.

---

## Test 10: `doey add` (worktree-aware column expansion)

With a worktree team running:
```bash
doey add
```

**Verify:** New workers in the worktree team have the worktree dir as CWD.

---

## Test 11: `doey reload` (worktree hook refresh)

```bash
doey reload
```

**Verify:** Hooks exist in worktree dir:
```bash
WT_DIR=$(grep WORKTREE_DIR "$RUNTIME_DIR/team_4.env" | cut -d= -f2- | tr -d '"')
ls "$WT_DIR/.claude/hooks/"
```

---

## Test 12: Hook integration — `DOEY_TEAM_DIR`

Tests `on-session-start.sh` exports `DOEY_TEAM_DIR` correctly. Only works on idle workers (shell prompt visible).

```bash
# Worktree team worker → should print worktree path
tmux send-keys -t "$SESSION:4.1" 'echo $DOEY_TEAM_DIR' Enter

# Normal team worker → should print main project path
tmux send-keys -t "$SESSION:1.1" 'echo $DOEY_TEAM_DIR' Enter
```

---

## Tests 13-15: Edge Cases

| Test | Command | Expected |
|------|---------|----------|
| **13: Transform busy team** | `/doey-worktree 1` (with busy workers) | Error: "Cannot transform — busy workers: ..." |
| **14: Double isolate** | `/doey-worktree 4` (already isolated) | Error: "Team 4 is already in a worktree..." |
| **15: --back on non-worktree** | `/doey-worktree 1 --back` (not isolated) | Error: "Team 1 is not in a worktree..." |

---

## Test 16: Info Panel Rendering

```bash
tmux capture-pane -t "$SESSION:0.0" -p -S -40 | grep -A 20 "TEAM STATUS"
```

**Expected:**
```
TEAM STATUS
  T1              6W (0 busy, 6 idle)
  T2              6W (0 busy, 6 idle)
  T3              6W (0 busy, 6 idle)
  T4 [wt]         6W (0 busy, 6 idle)  doey/team-4-0317-1700
```

`[wt]` badge in cyan for worktree teams. Branch name dimmed. Non-worktree teams have no badge.

---

## Quick Smoke Test (5 min)

```bash
# 1. Fresh launch — 4 teams?
doey stop 2>/dev/null; doey
# Wait ~30s for boot

# 2. Worktree created?
git worktree list | grep team-4 && echo "PASS" || echo "FAIL"

# 3. Badge visible?
doey list-teams

# 4. Kill worktree team — clean?
doey kill-team 4
git worktree list | grep team-4 && echo "FAIL" || echo "PASS"

# 5. Add worktree team from CLI
doey add-team --worktree
git worktree list | grep -c "worktrees/team-" | xargs -I{} test {} -ge 1 && echo "PASS" || echo "FAIL"

# 6. Full stop — all cleaned?
doey stop
git worktree list | grep -c "worktrees" | xargs -I{} test {} -eq 0 && echo "PASS" || echo "FAIL"
```

---

## Bash 3.2 Compatibility

Run after any shell script edits:
```bash
bash tests/test-bash-compat.sh
```
