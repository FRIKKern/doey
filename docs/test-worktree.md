# Worktree Feature — Test Guide

## Prerequisites

- A clean git repo (no uncommitted changes in main)
- No existing Doey session running (`doey stop` first)
- macOS with bash 3.2 (`/bin/bash --version`)

---

## Test 1: Fresh Launch (4th team auto-isolated)

**What it tests:** Step 9 in init — `add_dynamic_team_window` with `"auto"` worktree spec.

```bash
doey stop 2>/dev/null; doey
```

**Verify:**

```bash
# 1. Four team windows should exist
tmux list-windows -t "$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2- | xargs -I{} grep SESSION_NAME= {}/session.env | cut -d= -f2)" -F '#{window_index} #{window_name}'
# Expected: 0 (Dashboard), 1, 2, 3, 4
# Window 4 should have [wt] in its name

# 2. Worktree branch created
git worktree list
# Expected: /tmp/doey/<project>/worktrees/team-4 on branch doey/team-4-MMDD-HHMM

# 3. team_4.env has WORKTREE_DIR and WORKTREE_BRANCH
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
cat "$RUNTIME_DIR/team_4.env"
# Expected: WORKTREE_DIR="/tmp/doey/.../worktrees/team-4"
#           WORKTREE_BRANCH="doey/team-4-..."

# 4. settings.local.json copied
ls -la /tmp/doey/*/worktrees/team-4/.claude/settings.local.json
# Expected: file exists

# 5. Workers in team 4 have correct CWD
SESSION=$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)
tmux display-message -t "$SESSION:4.1" -p '#{pane_current_path}'
# Expected: /tmp/doey/<project>/worktrees/team-4

# 6. Info panel shows [wt] badge
tmux capture-pane -t "$SESSION:0.0" -p | grep -i "team.*wt\|worktree"
# Expected: Team 4 with [wt] badge
```

**Pass criteria:** Window 4 exists with `[wt]` name, worktree on disk, team env has worktree vars, workers CWD is the worktree path, info panel shows badge.

---

## Test 2: CLI `doey add-team --worktree`

**What it tests:** CLI parser + `add_dynamic_team_window` with worktree from CLI.

```bash
doey add-team --worktree
```

**Verify:**

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)

# 1. New window exists (probably window 5)
tmux list-windows -t "$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)" -F '#{window_index} #{window_name}'

# 2. Worktree created
git worktree list
# Expected: new entry for team-5

# 3. team env has worktree vars
cat "$RUNTIME_DIR/team_5.env" | grep WORKTREE

# 4. TEAM_WINDOWS updated in session.env
grep TEAM_WINDOWS "$RUNTIME_DIR/session.env"
```

**Pass criteria:** New team window with worktree branch, team env correct, session.env updated.

---

## Test 3: CLI `doey add-team` (no worktree — backward compat)

**What it tests:** Regular team creation still works without worktree.

```bash
doey add-team 3x2
```

**Verify:**

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)

# 1. New window, no [wt] in name
tmux list-windows -t "$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)" -F '#{window_index} #{window_name}'

# 2. No worktree vars in team env
NEW_WIN=6  # adjust based on actual window index
cat "$RUNTIME_DIR/team_${NEW_WIN}.env" | grep WORKTREE
# Expected: WORKTREE_DIR=""  (or empty)

# 3. Workers CWD is the main project dir
SESSION=$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)
tmux display-message -t "$SESSION:${NEW_WIN}.1" -p '#{pane_current_path}'
# Expected: main project path, NOT a worktree path
```

**Pass criteria:** Team created normally, no worktree, workers in main project dir.

---

## Test 4: `/doey-add-window --worktree` (slash command)

**What it tests:** The slash command version of add-window with worktree.

Run inside any Claude Code pane (Session Manager or Window Manager):
```
/doey-add-window --worktree
```

**Verify:** Same as Test 2 — new team window with worktree isolation.

---

## Test 5: `/doey-worktree W` (transform existing team)

**What it tests:** Transforming a running non-worktree team into an isolated worktree.

**Setup:** Make sure team 1 has all idle workers.

Run in Session Manager or Window Manager for team 1:
```
/doey-worktree 1
```

**Verify:**

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION=$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)

# 1. Window name updated
tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' | grep "^1 "
# Expected: "1 T1 [worktree]"

# 2. Worktree created
git worktree list | grep team-1

# 3. team_1.env updated
cat "$RUNTIME_DIR/team_1.env" | grep WORKTREE

# 4. Workers relaunched in worktree dir
tmux display-message -t "$SESSION:1.1" -p '#{pane_current_path}'
# Expected: worktree path

# 5. Workers responsive (give them 30s to boot)
sleep 30
tmux capture-pane -t "$SESSION:1.1" -p | grep "bypass permissions"
```

**Pass criteria:** Team 1 now isolated, workers running in worktree dir, window renamed.

---

## Test 6: `/doey-worktree W --back` (return to main)

**What it tests:** Reversing a worktree transformation.

**Setup:** Team 1 must be in worktree mode (from Test 5). Optionally make a file change first:

```bash
# In the worktree dir, create a test file
WT_DIR=$(grep WORKTREE_DIR "$RUNTIME_DIR/team_1.env" | cut -d= -f2- | tr -d '"')
echo "test" > "$WT_DIR/worktree-test.txt"
```

Run in Session Manager or Window Manager:
```
/doey-worktree 1 --back
```

**Verify:**

```bash
# 1. Uncommitted changes auto-saved (if any)
BRANCH=$(grep WORKTREE_BRANCH "$RUNTIME_DIR/team_1.env" | cut -d= -f2- | tr -d '"')
git log --oneline "$BRANCH" -3
# Expected: auto-commit "doey: WIP from team 1 worktree" if there were changes

# 2. Worktree removed
git worktree list | grep team-1
# Expected: no match (worktree gone)

# 3. team_1.env cleaned
cat "$RUNTIME_DIR/team_1.env" | grep WORKTREE
# Expected: no WORKTREE_DIR or WORKTREE_BRANCH lines

# 4. Window name restored
tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' | grep "^1 "
# Expected: "1 T1" (no [worktree])

# 5. Workers back in main project dir
tmux display-message -t "$SESSION:1.1" -p '#{pane_current_path}'
# Expected: main project dir

# 6. Branch preserved (not deleted)
git branch | grep doey/team-1
# Expected: branch still exists for manual merge
```

**Pass criteria:** Workers back in main dir, worktree removed, branch preserved, auto-commit if dirty.

---

## Test 7: `/doey-list-windows` (worktree badge)

**What it tests:** List command shows `[worktree]` badge for isolated teams.

```
/doey-list-windows
```

Or from CLI:
```bash
doey list-teams
```

**Verify:** Output shows `[worktree]` and branch name for worktree teams, nothing extra for normal teams.

---

## Test 8: `/doey-kill-window W` (kill worktree team)

**What it tests:** Killing a worktree team auto-saves and cleans up.

**Setup:** Have a worktree team (e.g., team 4 from launch or add one with `doey add-team --worktree`). Make a change in the worktree:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
WT_DIR=$(grep WORKTREE_DIR "$RUNTIME_DIR/team_4.env" | cut -d= -f2- | tr -d '"')
echo "kill-test" > "$WT_DIR/kill-test.txt"
git -C "$WT_DIR" add -A && git -C "$WT_DIR" commit -m "test commit in worktree"
```

Now kill:
```
/doey-kill-window 4
```

**Verify:**

```bash
# 1. Worktree removed from disk
ls /tmp/doey/*/worktrees/team-4 2>/dev/null
# Expected: no such directory

# 2. Worktree pruned from git
git worktree list | grep team-4
# Expected: no match

# 3. Branch preserved (had commits)
git branch | grep doey/team-4
# Expected: branch still exists

# 4. team_4.env removed
ls "$RUNTIME_DIR/team_4.env" 2>/dev/null
# Expected: no such file

# 5. Window gone
tmux list-windows -t "$SESSION" -F '#{window_index}' | grep "^4$"
# Expected: no match
```

**Pass criteria:** Worktree cleaned, branch preserved, runtime files removed, window gone.

---

## Test 9: `doey stop` (full teardown with worktrees)

**What it tests:** `_kill_doey_session` iterates all teams, safe-removes each worktree.

**Setup:** Have at least one worktree team running.

```bash
doey stop
```

**Verify:**

```bash
# 1. All worktrees removed
git worktree list
# Expected: only the main working tree

# 2. Branches preserved (if they had commits)
git branch | grep doey/
# Expected: branches from teams that had commits

# 3. Session gone
tmux has-session -t doey-* 2>/dev/null && echo "STILL RUNNING" || echo "STOPPED"
```

---

## Test 10: `doey add` column expansion (worktree-aware)

**What it tests:** `doey_add_column` reads WORKTREE_DIR and uses it for new pane CWDs.

**Setup:** Have a worktree team running.

```bash
doey add   # adds column to first team window
```

If team 4 is the worktree team, add a column specifically there:
```bash
# Check which team windows exist and which have worktrees
doey list-teams
```

**Verify:** New workers in the worktree team have the worktree dir as CWD, not the main project dir.

---

## Test 11: `doey reload` (worktree hook refresh)

**What it tests:** `reload_session` refreshes hooks in worktree directories.

```bash
doey reload
```

**Verify:**

```bash
# Check hooks exist in worktree
WT_DIR=$(grep WORKTREE_DIR "$RUNTIME_DIR/team_4.env" | cut -d= -f2- | tr -d '"')
ls "$WT_DIR/.claude/hooks/" 2>/dev/null
# Expected: hooks present (copied from main repo)
```

---

## Test 12: Hook integration — `DOEY_TEAM_DIR`

**What it tests:** `on-session-start.sh` exports `DOEY_TEAM_DIR` correctly.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION=$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)

# For a worktree team worker:
tmux send-keys -t "$SESSION:4.1" 'echo $DOEY_TEAM_DIR' Enter
sleep 2
tmux capture-pane -t "$SESSION:4.1" -p | tail -5
# Expected: worktree path

# For a normal team worker:
tmux send-keys -t "$SESSION:1.1" 'echo $DOEY_TEAM_DIR' Enter
sleep 2
tmux capture-pane -t "$SESSION:1.1" -p | tail -5
# Expected: main project path
```

**Note:** This only works if the worker has a shell prompt (idle). Don't run this against a busy Claude instance.

---

## Test 13: Edge case — transform busy team (should fail)

**What it tests:** `/doey-worktree` refuses to transform when workers are busy.

**Setup:** Send a task to team 1 so at least one worker is BUSY.

```
/doey-worktree 1
```

**Expected:** Error message: "Cannot transform — busy workers: ..."

---

## Test 14: Edge case — double isolate (should fail)

**What it tests:** `/doey-worktree` on an already-isolated team.

```
/doey-worktree 4
```

**Expected:** Error: "Team 4 is already in a worktree... Use `/doey-worktree 4 --back` to return first"

---

## Test 15: Edge case — `--back` on non-worktree team (should fail)

```
/doey-worktree 1 --back
```

**Expected:** Error: "Team 1 is not in a worktree — nothing to return from"

---

## Test 16: Info panel rendering

**What it tests:** `info-panel.sh` TEAM STATUS section.

```bash
SESSION=$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)
tmux capture-pane -t "$SESSION:0.0" -p -S -40 | grep -A 20 "TEAM STATUS"
```

**Expected output pattern:**
```
TEAM STATUS
  T1              6W (0 busy, 6 idle)
  T2              6W (0 busy, 6 idle)
  T3              6W (0 busy, 6 idle)
  T4 [wt]         6W (0 busy, 6 idle)  doey/team-4-0317-1700
```

- `[wt]` badge in cyan for worktree teams
- Branch name dimmed at end
- Non-worktree teams have no badge or branch

---

## Quick Smoke Test (5 min)

If you just want a fast pass/fail:

```bash
# 1. Fresh launch — does it start with 4 teams?
doey stop 2>/dev/null; doey
# Wait for boot (~30s)

# 2. Is team 4 a worktree?
git worktree list | grep team-4 && echo "PASS: worktree created" || echo "FAIL"

# 3. List teams — badge visible?
doey list-teams

# 4. Kill worktree team — clean?
doey kill-team 4
git worktree list | grep team-4 && echo "FAIL: worktree not cleaned" || echo "PASS: worktree removed"

# 5. Add worktree team from CLI
doey add-team --worktree
git worktree list | grep -c "worktrees/team-" | xargs -I{} test {} -ge 1 && echo "PASS" || echo "FAIL"

# 6. Full stop — all cleaned?
doey stop
git worktree list | grep -c "worktrees" | xargs -I{} test {} -eq 0 && echo "PASS: all clean" || echo "FAIL"
```

---

## Bash 3.2 Compatibility

Already automated — run anytime after edits:

```bash
bash tests/test-bash-compat.sh
```

Expected: `PASS: All shell scripts are bash 3.2 compatible.`
