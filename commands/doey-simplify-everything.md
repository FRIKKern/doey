# Skill: doey-simplify-everything

Whole-codebase simplification across all teams. Session Manager inventories capacity, researches the codebase, assigns each team a domain, and lets Window Managers dispatch to their workers. Three waves: research, review, fix.

## Usage
`/doey-simplify-everything`

## Prompt

You are the Doey **Session Manager** running a full codebase simplification. You coordinate Window Managers — you never dispatch to workers directly.

### Step 0: Inventory

Count teams and workers:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
echo "Session: $SESSION_NAME | Project: $PROJECT_NAME"
echo ""
TEAM_COUNT=0
TOTAL_WORKERS=0
for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  [ -f "$TEAM_ENV" ] || continue
  WC=$(grep '^WORKER_COUNT=' "$TEAM_ENV" | cut -d= -f2- | tr -d '"')
  WT=$(grep '^WORKTREE_DIR=' "$TEAM_ENV" | cut -d= -f2- | tr -d '"')
  TYPE="local"
  [ -n "$WT" ] && TYPE="worktree"
  echo "Team $W: ${WC} workers ($TYPE)"
  TEAM_COUNT=$((TEAM_COUNT + 1))
  TOTAL_WORKERS=$((TOTAL_WORKERS + WC))
done
echo ""
echo "Total: $TEAM_COUNT teams, $TOTAL_WORKERS workers"
```

Save the before-state:
```bash
BEFORE="${RUNTIME_DIR}/reports/simplify_before.txt"
mkdir -p "${RUNTIME_DIR}/reports"
wc -l "$PROJECT_DIR"/{agents,commands,docs}/*.md "$PROJECT_DIR"/CLAUDE.md \
      "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh \
      "$PROJECT_DIR"/{README.md,install.sh,.claude/settings.local.json} 2>/dev/null | sort -rn | tee "$BEFORE"
```

### Step 1: Assign domains to teams

The codebase has 6 domains. Assign based on how many teams are available:

| Domain | Files | Focus |
|--------|-------|-------|
| **D1: Shell core** | `shell/doey.sh` (4k lines), `install.sh` | Largest file. Simplify functions, reduce duplication, improve readability |
| **D2: Hooks** | `.claude/hooks/*.sh` (13 files) | Simplify logic, reduce nesting, improve variable naming, DRY across hooks |
| **D3: Commands** | `commands/*.md` (21 files) | Simplify instructions, reduce boilerplate, align patterns, improve clarity |
| **D4: Agents + CLAUDE.md** | `agents/*.md`, `CLAUDE.md` | Simplify prose, reduce redundancy with hooks, sharpen instructions |
| **D5: Docs + README** | `docs/*.md`, `README.md` | Simplify explanations, cut outdated content, improve scannability |
| **D6: Shell support + tests** | `shell/{info-panel,context-audit,pane-border-status,tmux-statusbar}.sh`, `tests/` | Simplify display logic, improve test coverage |

**Assignment rules:**
- **4+ teams:** D1, D2, D3+D4, D5+D6 (one domain per team, combine smaller ones)
- **3 teams:** D1+D6, D2+D4, D3+D5
- **2 teams:** D1+D2+D6, D3+D4+D5
- **1 team:** All domains (Window Manager runs waves internally)

**Worktree teams** can only edit files in their worktree copy. Assign them domains where merge conflicts are unlikely (docs, agents), or prefer local teams for high-conflict areas (hooks, shell core). If all teams are local, ignore this rule.

Present the assignment plan:
```
Simplify-Everything Plan
════════════════════════
Teams: N | Workers: M | Domains: 6

  Team 1 (local, 6w)  → D1: Shell core (doey.sh, install.sh)
  Team 2 (local, 6w)  → D2: Hooks (13 files)
  Team 3 (wt, 6w)     → D3+D4: Commands + Agents
  Team 4 (wt, 2w)     → D5+D6: Docs + support scripts

Proceed?
```

**Ask user for confirmation** before dispatching.

### Step 2: Dispatch to Window Managers

Send each Window Manager a self-contained task. Use `tmux load-buffer` / `paste-buffer` for the task (it will be multi-line).

**Task template for each Window Manager:**

```
Run a full simplification of [DOMAIN]. You have N workers — use /doey-dispatch to assign files.

Project directory: PROJECT_DIR

## Goal
Make every file simpler, clearer, and more concise. Not just condensing — genuinely simplifying:
- Reduce cognitive load: fewer concepts per paragraph, clearer structure
- Remove indirection: inline small helpers, flatten unnecessary nesting
- Improve naming: variables, functions, sections should be self-documenting
- Cut ceremony: boilerplate that adds no value, over-commented obvious code
- Align patterns: similar things should look similar across files
- DRY: extract repeated logic, but only when the abstraction is obvious

## Your files
[LIST EVERY FILE with line count — the Manager needs this to plan worker assignments]

## Constraints
- Tell all workers: Do NOT use the Agent tool
- Shell files (.sh): must remain bash 3.2 compatible (macOS /bin/bash). Run `bash -n` after edits.
- Use Edit tool, not Write. Read before editing.
- Simplify, don't break — preserve all behavior and functionality
- Commands (.md): bash code blocks must be 3.2 compatible
- Rename worker panes: `/rename simplify-<file>_MMDD`

## Worker assignment strategy
Each worker gets 1-3 files based on complexity. Largest files get dedicated workers.
Give each worker the full file list so they can cross-reference, but tell them which files to EDIT.

## When done
1. Run `bash -n` on all .sh files in your domain
2. Write a brief summary to: RUNTIME_DIR/reports/simplify_team_W.md
   Format: per-file before/after line counts + key changes
3. Report completion
```

**Dispatch to each Window Manager:**
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
```

**Verify each dispatch** (mandatory):
```bash
sleep 5
tmux capture-pane -t "$TARGET" -p -S -5
```

### Step 3: Monitor

After dispatching all teams, monitor for completion:
```bash
# Check for team reports
for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
  REPORT="${RUNTIME_DIR}/reports/simplify_team_${W}.md"
  if [ -f "$REPORT" ]; then
    echo "Team $W: DONE"
  else
    echo "Team $W: working..."
  fi
done
```

Also check Watchdog heartbeats and Window Manager pane output. Poll every 60s until all teams report done (or the user checks in).

### Step 4: Consolidate & verify

Once all teams finish:

```bash
# Before/after comparison
AFTER="${RUNTIME_DIR}/reports/simplify_after.txt"
wc -l "$PROJECT_DIR"/{agents,commands,docs}/*.md "$PROJECT_DIR"/CLAUDE.md \
      "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh \
      "$PROJECT_DIR"/{README.md,install.sh,.claude/settings.local.json} 2>/dev/null | sort -rn | tee "$AFTER"

echo "=== Before/After ==="
diff "${RUNTIME_DIR}/reports/simplify_before.txt" "$AFTER" || true

echo ""
echo "=== Syntax check ==="
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done

echo ""
echo "=== Context audit ==="
bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

Read all team reports from `${RUNTIME_DIR}/reports/simplify_team_*.md` and present a consolidated summary:

```
Simplify-Everything — Results
══════════════════════════════
Teams: 4 | Workers used: 20 | Duration: ~Xm

Before: 10,891 lines across 52 files
After:  ~X,XXX lines (-XX%)

By domain:
  D1 Shell core     4,087 → X,XXX  (-XX%)  Team 1
  D2 Hooks          1,630 → X,XXX  (-XX%)  Team 2
  D3 Commands       1,574 → X,XXX  (-XX%)  Team 3
  D4 Agents           551 →   XXX  (-XX%)  Team 3
  D5 Docs           1,921 → X,XXX  (-XX%)  Team 4
  D6 Support          336 →   XXX  (-XX%)  Team 4

Syntax: 18/18 .sh files pass
Audit:  clean / N issues

Key improvements:
  [per-team highlights from reports]
```

If syntax or audit issues found, offer to dispatch a fix round to the relevant team.

### Rules

1. **Never dispatch to workers** — always route through Window Managers
2. **Self-contained tasks** — Window Managers have zero context; include everything
3. **No file conflicts** — each team owns distinct files; verify no overlap
4. **Ask user before dispatching** — present the plan first
5. **Verify every dispatch** — capture-pane after 5s
6. **Simplify, don't break** — preserve behavior; this is refactoring, not rewriting
7. **Bash 3.2** — all .sh files must work on macOS `/bin/bash`
