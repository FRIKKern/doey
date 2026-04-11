# Worktree Test Guide

**Prerequisites:** Clean git repo, no running Doey session, macOS with bash 3.2. **Setup:**

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
SESSION=$(grep SESSION_NAME= "$RUNTIME_DIR/session.env" | cut -d= -f2)
```

> A bare `doey` launch creates only the dashboard + core team — no auto-worktreed teams. Use `doey add-team --worktree` (Test 1) or `/doey-add-window --worktree` (Test 3) to create one.

## Test 1: `doey add-team --worktree`

```bash
doey add-team --worktree
```

| Check | Command | Expected |
|-------|---------|----------|
| New window | `tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}'` | New window (e.g. 5) |
| Worktree | `git worktree list` | Entry for new team |
| Team env | `cat "$RUNTIME_DIR/team_5.env" \| grep WORKTREE` | Has worktree vars |
| Session updated | `grep TEAM_WINDOWS "$RUNTIME_DIR/session.env"` | Includes new window |

## Test 2: `doey add-team` (no worktree)

```bash
doey add-team 3x2
```

Verify: No `[wt]` in name. `team_N.env` has empty `WORKTREE_DIR`. Workers CWD = main project dir.

## Test 3: `/doey-add-window --worktree`

Run inside any Claude Code pane. Same checks as Test 1.

## Test 4: `/doey-worktree W` (transform existing team)

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

## Test 5: `/doey-worktree W --back` (return to main)

Run after Test 4. Optional setup: create a test file in `$WT_DIR/worktree-test.txt`.

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

## Test 6: `/doey-list-windows`

Verify: `[worktree]` badge + branch for worktree teams; nothing extra for normal teams.

## Test 7: `/doey-kill-window W` (kill worktree team)

Setup: First create a worktree team via Test 1 (`doey add-team --worktree`); note its window number `N`. Commit a file inside its worktree, then run `/doey-kill-window N`.

| Check | Command | Expected |
|-------|---------|----------|
| Worktree removed | `ls /tmp/doey/*/worktrees/team-N 2>/dev/null` | No such dir |
| Git pruned | `git worktree list \| grep team-N` | No match |
| Branch preserved | `git branch \| grep doey/team-N` | Exists (had commits) |
| Runtime cleaned | `ls "$RUNTIME_DIR/team_N.env" 2>/dev/null` | No such file |
| Window gone | `tmux list-windows ... \| grep "^N "` | No match |

## Tests 8–11: Quick Checks

| Test | Action | Verify |
|------|--------|--------|
| 8: `doey stop` | Full teardown | `git worktree list` shows only main. Branches with commits preserved. Session gone. |
| 9: `doey add` | Column expansion in worktree team | New workers have worktree dir as CWD |
| 10: `doey reload` | Hook refresh | `ls "$WT_DIR/.claude/hooks/"` shows hooks in worktree dir |
| 11: `DOEY_TEAM_DIR` | `echo $DOEY_TEAM_DIR` on idle workers | Worktree worker → worktree path; normal worker → main path |

## Tests 12–14: Edge Cases

| Test | Command | Expected |
|------|---------|----------|
| 12: Busy team | `/doey-worktree 1` (busy workers) | Error: busy workers |
| 13: Already isolated | `/doey-worktree N` (worktree team N) | Error: already in worktree |
| 14: --back on normal | `/doey-worktree 1 --back` (not isolated) | Error: not in worktree |

## Test 15: Info Panel

`tmux capture-pane -t "$SESSION:0.0" -p -S -40 | grep -A 20 "TEAM STATUS"` — expect `[wt]` badge in cyan for worktree teams, branch name dimmed.

## Quick Smoke Test

```bash
doey stop 2>/dev/null; doey        # 1. Fresh launch (dashboard + core team only)
doey add-team --worktree           # 2. Add worktree team (note its window number, e.g. 2)
git worktree list | grep -c "worktrees/team-" | xargs -I{} test {} -ge 1 && echo "PASS" || echo "FAIL"
doey list-teams                    # 3. Badge visible?
doey kill-team 2                   # 4. Kill worktree team (use the number from step 2)
git worktree list | grep team-2 && echo "FAIL" || echo "PASS"
doey stop                          # 5. Full stop
git worktree list | grep -c "worktrees" | xargs -I{} test {} -eq 0 && echo "PASS" || echo "FAIL"
```

After shell edits: `bash tests/test-bash-compat.sh`
