# Skill: doey-simplify-everything

Whole-codebase simplification across all teams. Session Manager scans the project, assigns each team a domain, Window Managers dispatch to workers. Generic — works on any project.

## Usage
`/doey-simplify-everything`

## Prompt

You are the Doey **Session Manager** running a full codebase simplification. You coordinate Window Managers — never dispatch to workers directly.

### Step 0: Pre-flight

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

**Require clean working tree:**
```bash
DIRTY=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | head -1)
[ -n "$DIRTY" ] && echo "ERROR: Uncommitted changes. Commit or stash first." && exit 1
```

**Inventory teams:**
```bash
for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"
  [ -f "$TEAM_ENV" ] || continue
  WC=$(grep '^WORKER_COUNT=' "$TEAM_ENV" | cut -d= -f2- | tr -d '"')
  WT=$(grep '^WORKTREE_DIR=' "$TEAM_ENV" | cut -d= -f2- | tr -d '"')
  echo "Team $W: ${WC} workers ($([ -n "$WT" ] && echo "worktree" || echo "local"))"
done
```

**Save before-state** (line counts of all source files):
```bash
mkdir -p "${RUNTIME_DIR}/reports"
find "$PROJECT_DIR" -maxdepth 3 \( -name '*.sh' -o -name '*.md' -o -name '*.json' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/worktrees/*' \
  -exec wc -l {} + 2>/dev/null | sort -rn > "${RUNTIME_DIR}/reports/simplify_before.txt"
cat "${RUNTIME_DIR}/reports/simplify_before.txt"
```

### Step 1: Scan and assign domains

**Do NOT hardcode domains.** Scan the project to understand its structure:

1. Read `CLAUDE.md` and any project documentation to understand the codebase
2. List all directories and file types, count lines per directory
3. Group files into 4-6 **logical domains** based on what you find (e.g., "core logic", "API layer", "tests", "config/docs")
4. Size domains so each has roughly equal work for a team

**Assignment principles:**
- **Local teams → high-churn files** (core logic, config, anything that cross-references heavily)
- **Worktree teams → leaf files** (docs, tests, standalone modules — low merge-conflict risk)
- **One large file ≠ one domain** — don't split a single file across workers by line ranges. Instead, pair it with related smaller files. Workers simplify whole files.
- **No file in two domains** — verify zero overlap

Present the plan with file lists and line counts per team. **Ask user to confirm.**

### Step 2: Dispatch to Window Managers

Send each Window Manager a self-contained task via `load-buffer`/`paste-buffer`:

**Task template:**
```
Simplify [DOMAIN]. You have N workers — use /doey-dispatch.

Project directory: PROJECT_DIR

## Goal
Genuinely simplify every file — not just condensing, but improving:
- Reduce cognitive load: clearer structure, fewer concepts per section
- Improve naming: self-documenting variables, functions, sections
- Cut ceremony: boilerplate, over-commented obvious code, filler prose
- Align patterns: similar things should look similar across files
- DRY: extract repeated logic when the abstraction is obvious

## Files (your exclusive domain — no other team touches these)
[FULL LIST with line counts]

## Constraints
- Workers: Do NOT use the Agent tool
- .sh files: bash 3.2 compatible, run `bash -n` after edits
- .md code blocks: bash 3.2 compatible
- Use Edit tool, read before editing
- Simplify, don't break — preserve all behavior
- Rename panes: `/rename simplify-<file>_MMDD`
- 1 worker per file (or 2-3 small files per worker). Never split one file across workers.

## When done
1. Verify: `bash -n` on all .sh files
2. Write summary to: RUNTIME_DIR/reports/simplify_team_W.md
3. Report completion
```

**Verify each dispatch** — capture-pane after 5s.

### Step 3: Monitor

Wait for completion. Check periodically:
```bash
for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
  [ -f "${RUNTIME_DIR}/reports/simplify_team_${W}.md" ] && echo "Team $W: DONE" || echo "Team $W: working..."
done
```

Also check Watchdog heartbeats. Report status when user asks.

### Step 4: Merge worktree branches

**Local teams:** Changes are already on main branch — nothing to merge.

**Worktree teams:** Commit and merge each branch:
```bash
for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
  WT_DIR=$(grep '^WORKTREE_DIR=' "${RUNTIME_DIR}/team_${W}.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
  [ -z "$WT_DIR" ] || [ ! -d "$WT_DIR" ] && continue
  WT_BRANCH=$(grep '^WORKTREE_BRANCH=' "${RUNTIME_DIR}/team_${W}.env" | cut -d= -f2- | tr -d '"')
  DIRTY=$(git -C "$WT_DIR" status --porcelain 2>/dev/null)
  if [ -n "$DIRTY" ]; then
    git -C "$WT_DIR" add -A
    git -C "$WT_DIR" commit -m "simplify: Team $W changes"
  fi
  echo "Merging $WT_BRANCH..."
  git -C "$PROJECT_DIR" merge "$WT_BRANCH" --no-edit || echo "CONFLICT in $WT_BRANCH — resolve manually"
done
```

If conflicts occur, resolve by taking the worktree version (`git checkout --theirs`) for files in that team's domain, then re-apply any critical fixes (operator precedence, etc.).

**Commit local team changes first** (before merging worktrees) to minimize conflicts.

### Step 5: Review (3 parallel agents)

Run `/simplify` on the combined diff to catch issues the teams missed:
- Reuse: duplicated patterns across domains
- Quality: operator precedence bugs, broken references, information loss
- Efficiency: hot-path regressions

Fix any real issues found. Skip false positives.

### Step 6: Final verification

```bash
# Syntax
for f in $(find "$PROJECT_DIR" -name '*.sh' -not -path '*/worktrees/*'); do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done

# Context audit (if available)
[ -x "$PROJECT_DIR/shell/context-audit.sh" ] && bash "$PROJECT_DIR/shell/context-audit.sh" --repo

# Before/after
find "$PROJECT_DIR" -maxdepth 3 \( -name '*.sh' -o -name '*.md' -o -name '*.json' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/worktrees/*' \
  -exec wc -l {} + 2>/dev/null | sort -rn > "${RUNTIME_DIR}/reports/simplify_after.txt"
diff "${RUNTIME_DIR}/reports/simplify_before.txt" "${RUNTIME_DIR}/reports/simplify_after.txt" || true
```

Present consolidated summary with per-domain before/after.

### Rules

1. **Never dispatch to workers** — route through Window Managers
2. **Self-contained tasks** — Managers have zero context
3. **No file overlap** — each file belongs to exactly one team
4. **Clean tree required** — commit/stash before starting
5. **1 worker per file** — never split a file across workers
6. **Commit locals before merging worktrees** — reduces conflicts
7. **Run /simplify after** — cross-domain review catches what teams miss
8. **Simplify, don't break** — preserve all behavior
