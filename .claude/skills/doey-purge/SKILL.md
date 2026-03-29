---
name: doey-purge
description: Two-wave purge — audit every project file for context rot and code issues, then fix. Use when you need to "audit the codebase", "clean up context rot", or "purge stale content".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Team env: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`

**Usage:** `/doey-purge` (full 2-wave audit+fix) | `runtime` (clean stale runtime files only)

### Inventory
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
[ -f "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env" ] && source "${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
mkdir -p "${RUNTIME_DIR}/reports"
wc -l "$PROJECT_DIR"/agents/*.md "$PROJECT_DIR"/CLAUDE.md \
      "$PROJECT_DIR"/.claude/skills/*/SKILL.md "$PROJECT_DIR"/docs/*.md \
      "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh \
      "$PROJECT_DIR"/.claude/settings.local.json 2>/dev/null | sort -rn | tee "${RUNTIME_DIR}/reports/purge_before.txt"
```

### Wave 1: Audit (4 workers)
Dispatch via `/doey-dispatch`. No Agent tool. Each writes `${RUNTIME_DIR}/reports/purge_<domain>.md`. Rename panes: `purge-<domain>_$(date +%m%d)`.

**Categories** (HIGH/MED/LOW): BLOAT, REDUNDANCY, STALENESS, CONTRADICTION, DEAD WEIGHT, BASH 3.2, BUG, DEAD CODE.

**Assignments:** A=Agents+CLAUDE.md, B=Hooks+Shell+Settings, C=Skills, D=Docs+README+Memory.

**Report format:** `## File: path (N lines)` → `CATEGORY [severity] [lines]: description + fix` → `Condensation Estimate: N → ~M (-X%)`

### Between Waves
Read all `purge_*.md` reports. Present consolidated summary. **Ask user before dispatching fixes.**

### Wave 2: Fix (4 workers)
Assign by file ownership (no conflicts): A=agents+CLAUDE.md, B=hooks+shell, C=skills, D=docs+README+memory. Edit not Write. Read before editing. `.sh`: `bash -n` after every edit.

### Verification
Re-run `wc -l`, diff against `purge_before.txt`:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
echo "=== Context audit ===" && bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

### Rules
1. Ask user before Wave 2 — never auto-fix without confirmation
2. No Agent tool in worker prompts
