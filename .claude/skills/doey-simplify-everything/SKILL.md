---
name: doey-simplify-everything
description: Full codebase simplification across all teams. Session Manager inventories capacity, assigns domains, dispatches to Window Managers.
---

## Context

!`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); cat "$RD/session.env" 2>/dev/null; for f in "$RD"/team_*.env; do [ -f "$f" ] && echo "--- $(basename $f) ---" && cat "$f"; done; PD=$(grep PROJECT_DIR "$RD/session.env" 2>/dev/null | head -1 | cut -d= -f2); git -C "$PD" status --porcelain 2>/dev/null | head -5 || true`

## Prompt

You are the Session Manager running a codebase-wide simplification. Coordinate Window Managers — never dispatch to workers directly.

### Inventory

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
DIRTY=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | head -1)
[ -n "$DIRTY" ] && echo "ERROR: Uncommitted changes. Commit or stash first." && exit 1

TEAM_COUNT=0; TOTAL_WORKERS=0
for W in $(echo "$TEAM_WINDOWS" | tr ',' ' '); do
  TEAM_ENV="${RUNTIME_DIR}/team_${W}.env"; [ -f "$TEAM_ENV" ] || continue
  WC=$(grep '^WORKER_COUNT=' "$TEAM_ENV" | cut -d= -f2- | tr -d '"')
  WT=$(grep '^WORKTREE_DIR=' "$TEAM_ENV" | cut -d= -f2- | tr -d '"')
  TYPE="local"; [ -n "$WT" ] && TYPE="worktree"
  echo "Team $W: ${WC} workers ($TYPE)"
  TEAM_COUNT=$((TEAM_COUNT + 1)); TOTAL_WORKERS=$((TOTAL_WORKERS + WC))
done
echo "Total: $TEAM_COUNT teams, $TOTAL_WORKERS workers"
mkdir -p "${RUNTIME_DIR}/reports"
wc -l "$PROJECT_DIR"/agents/*.md "$PROJECT_DIR"/CLAUDE.md \
      "$PROJECT_DIR"/.claude/skills/*/SKILL.md "$PROJECT_DIR"/docs/*.md \
      "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh \
      "$PROJECT_DIR"/{README.md,install.sh,.claude/settings.local.json} 2>/dev/null | sort -rn | tee "${RUNTIME_DIR}/reports/simplify_before.txt"
```

### Assign domains

| Domain | Files |
|--------|-------|
| **D1: Shell core** | `shell/doey.sh`, `install.sh` |
| **D2: Hooks** | `.claude/hooks/*.sh` |
| **D3: Skills** | `.claude/skills/*/SKILL.md` |
| **D4: Agents + CLAUDE.md** | `agents/*.md`, `CLAUDE.md` |
| **D5: Docs + README** | `docs/*.md`, `README.md` |
| **D6: Shell support** | `shell/{info-panel,context-audit,pane-border-status,tmux-statusbar}.sh`, `tests/` |

**By team count:** 4+: D1, D2, D3+D4, D5+D6 | 3: D1+D6, D2+D4, D3+D5 | 2: D1+D2+D6, D3+D4+D5 | 1: all

Prefer worktree teams for low-conflict domains. **Ask user for confirmation** before dispatching.

### Dispatch to Window Managers

Send self-contained task via `tmux load-buffer`/`paste-buffer`. Exit copy-mode first, sleep 0.5s after paste, send Enter, verify with capture-pane after 5s.

**Task template:** `Run a full simplification of [DOMAIN]. N workers, use /doey-dispatch. Project: PROJECT_DIR. Goal: reduce cognitive load, improve naming, cut ceremony, DRY. Files: [LIST with line counts]. Constraints: No Agent tool, bash 3.2, bash -n after, Edit not Write, read before editing, preserve behavior. Rename: /rename simplify-<file>_MMDD. When done: write summary to RUNTIME_DIR/reports/simplify_team_W.md.`

### Monitor + Consolidate

Poll every 60s for `${RUNTIME_DIR}/reports/simplify_team_${W}.md`. When all done, re-run `wc -l`, diff, syntax check + context audit:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

Present consolidated results. If issues found, offer a fix round.

### Rules
1. **Route through Window Managers** — never dispatch to workers directly
2. **Self-contained tasks** — Managers have zero context
3. **No file conflicts** — each team owns distinct files
4. **Confirm before dispatching**
5. **Bash 3.2** — all .sh files must work on macOS
