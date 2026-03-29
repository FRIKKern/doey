# Worktree Test Guide

**Prerequisites:** Clean git repo, no running Doey session, macOS with bash 3.2.

**Setup:**
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION=$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)
```

## Test 1: Fresh Launch (auto-isolated team 4)

```bash
doey stop 2>/dev/null; doey
```

| Check | Command | Expected |
|-------|---------|----------|
| 5 windows | `tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}'` | Window 4 has `[wt]` |
| Worktree branch | `git worktree list` | `team-4` on `doey/team-4-MMDD-HHMM` |
| Team env | `cat "$RUNTIME_DIR/team_4.env"` | Has `WORKTREE_DIR`, `WORKTREE_BRANCH` |
| Settings copied | `ls /tmp/doey/*/worktrees/team-4/.claude/settings.local.json` | Exists |
| Worker CWD | `tmux display-message -t "$SESSION:4.1" -p '#{pane_current_path}'` | Worktree path |
| Info panel badge | `tmux capture-pane -t "$SESSION:0.0" -p \| grep -i "team.*wt\|worktree"` | Team 4 `[wt]` |

## Test 2: `doey add-team --worktree`

```bash
doey add-team --worktree
```

| Check | Command | Expected |
|-------|---------|----------|
| New window | `tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}'` | New window (e.g. 5) |
| Worktree | `git worktree list` | Entry for new team |
| Team env | `cat "$RUNTIME_DIR/team_5.env" \| grep WORKTREE` | Has worktree vars |
| Session updated | `grep TEAM_WINDOWS "$RUNTIME_DIR/session.env"` | Includes new window |

## Test 3: `doey add-team` (no worktree)

```bash
doey add-team 3x2
```

Verify: No `[wt]` in name. `team_N.env` has empty `WORKTREE_DIR`. Workers CWD = main project dir.

## Test 4: `/doey-add-window --worktree`

Run inside any Claude Code pane. Same checks as Test 2.

## Test 5: `/doey-worktree W` (transform existing team)

Requires all workers idle.

```
/doey-worktree 1
```

| Check | Command | Expected |
|-------|---------|----------|
| Window renamed | `tmux list-windows ... \| grep "^1 "` | `1 T1 [worktree]` |
| Worktree exists | `git worktree list \| grep team-1` | Present |
| Team env | `cat "$RUNTIME_DIR/team_1.env" \| grep WORKTREE` | Has worktree vars |
| Worker CWD | `tmux display-message -t "$SESSION:1.1" -p '#{pane_current_path}'` | Worktree path |

## Test 6: `/doey-worktree W --back` (return to main)

Run after Test 5. Optionally create a test file first:

```bash
WT_DIR=$(grep WORKTREE_DIR "$RUNTIME_DIR/team_1.env" | cut -d= -f2- | tr -d '"')
echo "test" > "$WT_DIR/worktree-test.txt"
```

```
/doey-worktree 1 --back
```

| Check | Command | Expected |
|-------|---------|----------|
| Auto-commit | `git log --oneline "$BRANCH" -3` | WIP commit if dirty |
| Worktree removed | `git worktree list \| grep team-1` | No match |
| Team env cleaned | `cat "$RUNTIME_DIR/team_1.env" \| grep WORKTREE` | No worktree vars |
| Window name | `tmux list-windows ... \| grep "^1 "` | `1 T1` (no badge) |
| Worker CWD | `tmux display-message -t "$SESSION:1.1" -p '#{pane_current_path}'` | Main project dir |
| Branch preserved | `git branch \| grep doey/team-1` | Exists |

## Test 7: `/doey-list-windows`

Verify: `[worktree]` badge + branch for worktree teams; nothing extra for normal teams.

## Test 8: `/doey-kill-window W` (kill worktree team)

Setup — commit in worktree team 4:
```bash
WT_DIR=$(grep WORKTREE_DIR "$RUNTIME_DIR/team_4.env" | cut -d= -f2- | tr -d '"')
echo "kill-test" > "$WT_DIR/kill-test.txt"
git -C "$WT_DIR" add -A && git -C "$WT_DIR" commit -m "test commit in worktree"
```

```
/doey-kill-window 4
```

| Check | Command | Expected |
|-------|---------|----------|
| Worktree removed | `ls /tmp/doey/*/worktrees/team-4 2>/dev/null` | No such dir |
| Git pruned | `git worktree list \| grep team-4` | No match |
| Branch preserved | `git branch \| grep doey/team-4` | Exists (had commits) |
| Runtime cleaned | `ls "$RUNTIME_DIR/team_4.env" 2>/dev/null` | No such file |
| Window gone | `tmux list-windows ... \| grep "^4$"` | No match |

## Tests 9–12: Quick Checks

| Test | Action | Verify |
|------|--------|--------|
| 9: `doey stop` | Full teardown | `git worktree list` shows only main. Branches with commits preserved. Session gone. |
| 10: `doey add` | Column expansion in worktree team | New workers have worktree dir as CWD |
| 11: `doey reload` | Hook refresh | `ls "$WT_DIR/.claude/hooks/"` shows hooks in worktree dir |
| 12: `DOEY_TEAM_DIR` | `echo $DOEY_TEAM_DIR` on idle workers | Worktree worker → worktree path; normal worker → main path |

## Tests 13–15: Edge Cases

| Test | Command | Expected |
|------|---------|----------|
| 13: Busy team | `/doey-worktree 1` (busy workers) | Error: busy workers |
| 14: Already isolated | `/doey-worktree 4` (worktree team) | Error: already in worktree |
| 15: --back on normal | `/doey-worktree 1 --back` (not isolated) | Error: not in worktree |

## Test 16: Info Panel

```bash
tmux capture-pane -t "$SESSION:0.0" -p -S -40 | grep -A 20 "TEAM STATUS"
```

Expected: `[wt]` badge in cyan for worktree teams, branch name dimmed.

```
TEAM STATUS
  T1              6W (0 busy, 6 idle)
  T4 [wt]         6W (0 busy, 6 idle)  doey/team-4-0317-1700
```

## Quick Smoke Test

```bash
doey stop 2>/dev/null; doey        # 1. Fresh launch (wait ~30s)
git worktree list | grep team-4 && echo "PASS" || echo "FAIL"  # 2. Worktree created?
doey list-teams                    # 3. Badge visible?
doey kill-team 4                   # 4. Kill worktree team
git worktree list | grep team-4 && echo "FAIL" || echo "PASS"
doey add-team --worktree           # 5. Add worktree team
git worktree list | grep -c "worktrees/team-" | xargs -I{} test {} -ge 1 && echo "PASS" || echo "FAIL"
doey stop                          # 6. Full stop
git worktree list | grep -c "worktrees" | xargs -I{} test {} -eq 0 && echo "PASS" || echo "FAIL"
```

After shell edits: `bash tests/test-bash-compat.sh`
