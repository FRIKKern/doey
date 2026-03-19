---
name: doey-purge
description: Two-wave purge — audit every project file for context rot and code issues, then fix.
---

## Context

!`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); cat "$RD/session.env" 2>/dev/null; W=$(tmux show-environment DOEY_WINDOW_INDEX 2>/dev/null | cut -d= -f2-); echo "WIN=$W"; cat "$RD/team_${W}.env" 2>/dev/null || true`

## Usage
`/doey-purge` — full audit + fix (2-wave dispatch)
`/doey-purge runtime` — clean stale runtime files only (no workers)

## Prompt

Quick mode: run `doey purge --force`, report, stop.

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

### Wave 1: Audit (4 parallel workers)

Dispatch via `/doey-dispatch`. **All workers: No Agent tool.** Each writes to `${RUNTIME_DIR}/reports/purge_<domain>.md`. Rename: `/rename purge-<domain>_$(date +%m%d)`.

**Issue categories** (HIGH/MED/LOW): BLOAT, REDUNDANCY, STALENESS, CONTRADICTION, DEAD WEIGHT, BASH 3.2, BUG, DEAD CODE.

**Assignments:** A=Agents+CLAUDE.md, B=Hooks+Shell+Settings, C=Skills, D=Docs+README+Memory.

**Report format:** `## File: path (N lines)` -> Issues with `CATEGORY [severity] [lines]: description + fix` -> `Condensation Estimate: N -> ~M (-X%)` -> Summary totals.

**Worker template:** `You are Worker N auditing [DOMAIN]. Project: PROJECT_DIR | No Agent tool. Read all files, cross-ref filesystem. Issues with line numbers + severity. If a hook enforces a rule, agents don't repeat it. Every .sh: bash 3.2 violations = HIGH. Write report to REPORT_PATH.`

### Between Waves

Read all `${RUNTIME_DIR}/reports/purge_*.md`. Present consolidated summary. Propose Wave 2 assignments. **Ask user before dispatching fixes.**

### Wave 2: Fix (4 parallel workers)

Assign by file ownership (no edit conflicts): A=agents+CLAUDE.md, B=hooks+shell, C=skills, D=docs+README+memory.

All fix workers: `Edit` not `Write`. Read before editing. Condense (fewer words, not lost info). `.sh` files: `bash -n` after every edit. Bash 3.2 compatible.

### Verification

Re-run `wc -l`, diff against `purge_before.txt`, then syntax check + context audit:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

### Rules
1. **No Agent tool** in worker prompts
2. **Ask user before Wave 2**
3. **Read reports before presenting**
4. **Bash 3.2 violations are HIGH**
