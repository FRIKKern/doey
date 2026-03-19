# Skill: doey-simplify-everything

Full codebase simplification across all teams. Session Manager inventories capacity, assigns domains, dispatches to Window Managers.

## Usage
`/doey-simplify-everything`

## Prompt

You are the Session Manager running a codebase-wide simplification. Coordinate Window Managers — never dispatch to workers directly.

### Inventory

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"

DIRTY=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | head -1)
[ -n "$DIRTY" ] && echo "ERROR: Uncommitted changes in $PROJECT_DIR. Commit or stash first." && exit 1

# Line-count snapshot helper (reused in Consolidate)
LINE_COUNT_CMD='wc -l "$PROJECT_DIR"/{agents,commands,docs}/*.md "$PROJECT_DIR"/CLAUDE.md "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh "$PROJECT_DIR"/{README.md,install.sh,.claude/settings.local.json} 2>/dev/null | sort -rn'

echo "Session: $SESSION_NAME | Project: $PROJECT_NAME"
echo ""
TEAM_COUNT=0; TOTAL_WORKERS=0
for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  [ -f "$TEAM_ENV" ] || continue
  WC=$(grep '^WORKER_COUNT=' "$TEAM_ENV" | cut -d= -f2- | tr -d '"')
  WT=$(grep '^WORKTREE_DIR=' "$TEAM_ENV" | cut -d= -f2- | tr -d '"')
  TYPE="local"; [ -n "$WT" ] && TYPE="worktree"
  echo "Team $W: ${WC} workers ($TYPE)"
  TEAM_COUNT=$((TEAM_COUNT + 1))
  TOTAL_WORKERS=$((TOTAL_WORKERS + WC))
done
echo "Total: $TEAM_COUNT teams, $TOTAL_WORKERS workers"

mkdir -p "${RUNTIME_DIR}/reports"
eval "$LINE_COUNT_CMD" | tee "${RUNTIME_DIR}/reports/simplify_before.txt"
```

### Assign domains

| Domain | Files |
|--------|-------|
| **D1: Shell core** | `shell/doey.sh`, `install.sh` |
| **D2: Hooks** | `.claude/hooks/*.sh` |
| **D3: Commands** | `commands/*.md` |
| **D4: Agents + CLAUDE.md** | `agents/*.md`, `CLAUDE.md` |
| **D5: Docs + README** | `docs/*.md`, `README.md` |
| **D6: Shell support** | `shell/{info-panel,context-audit,pane-border-status,tmux-statusbar}.sh`, `tests/` |

**Assignment by team count:** 4+: D1, D2, D3+D4, D5+D6 | 3: D1+D6, D2+D4, D3+D5 | 2: D1+D2+D6, D3+D4+D5 | 1: all

Prefer worktree teams for low-conflict domains (docs, agents). Local teams for hooks/shell core. Present the plan and **ask user for confirmation** before dispatching.

### Dispatch to Window Managers

Send each Window Manager a self-contained task via `tmux load-buffer`/`paste-buffer`.

**Task template** (fill in DOMAIN, N workers, PROJECT_DIR, file list with line counts, RUNTIME_DIR):

```
Run a full simplification of [DOMAIN]. You have N workers — use /doey-dispatch to assign files.
Project directory: PROJECT_DIR

**Goal:** Reduce cognitive load, improve naming, cut ceremony, align patterns, DRY repeated logic.

**Files:** [LIST EVERY FILE with line count]

**Constraints:** No Agent tool. Shell: bash 3.2, run `bash -n` after. Use Edit not Write. Read before editing. Preserve behavior. Commands (.md): bash blocks 3.2 compatible. Rename workers: `/rename simplify-<file>_MMDD`

**Assignment:** 1-3 files/worker by complexity. Largest files = dedicated workers. Share full list for cross-reference.

**When done:** `bash -n` all .sh, write summary to RUNTIME_DIR/reports/simplify_team_W.md (per-file before/after + key changes), report completion.
```

**Dispatch each task:**
```bash
W=<team_window>
MGR_PANE=$(grep '^MANAGER_PANE=' "${RUNTIME_DIR}/team_${W}.env" | cut -d= -f2- | tr -d '"')
TARGET="$SESSION_NAME:${W}.${MGR_PANE}"
tmux copy-mode -q -t "$TARGET" 2>/dev/null
TASKFILE=$(mktemp "${RUNTIME_DIR}/task_XXXXXX.txt")
cat > "$TASKFILE" << 'TASK'
[Full task text here]
TASK
tmux load-buffer "$TASKFILE"
tmux paste-buffer -t "$TARGET"
sleep 0.5
tmux send-keys -t "$TARGET" Enter
rm "$TASKFILE"
# Verify (mandatory)
sleep 5
tmux capture-pane -t "$TARGET" -p -S -5
```

### Monitor

Poll every 60s. Also check Watchdog heartbeats and Window Manager output.
```bash
for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
  [ -f "${RUNTIME_DIR}/reports/simplify_team_${W}.md" ] && echo "Team $W: DONE" || echo "Team $W: working..."
done
```

### Consolidate

Once all teams finish:

```bash
# Reuse LINE_COUNT_CMD from Inventory
eval "$LINE_COUNT_CMD" | tee "${RUNTIME_DIR}/reports/simplify_after.txt"

echo "=== Before/After ==="
diff "${RUNTIME_DIR}/reports/simplify_before.txt" "${RUNTIME_DIR}/reports/simplify_after.txt" || true

echo "=== Syntax check ==="
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done

echo "=== Context audit ==="
bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

Read all `${RUNTIME_DIR}/reports/simplify_team_*.md` and present consolidated results: total before/after line counts, per-domain breakdown, syntax/audit status, key improvements per team. If syntax or audit issues found, offer to dispatch a fix round.

### Rules
1. **Route through Window Managers** — never dispatch to workers directly
2. **Self-contained tasks** — Managers have zero context; include everything
3. **No file conflicts** — each team owns distinct files
4. **Confirm before dispatching** — present the plan first
5. **Verify every dispatch** — capture-pane after 5s
6. **Preserve behavior** — simplify, don't break
7. **Bash 3.2** — all .sh files must work on macOS `/bin/bash`
