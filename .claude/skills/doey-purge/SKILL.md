---
name: doey-purge
description: Two-wave purge — audit every project file for context rot and code issues, then fix.
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`echo "${DOEY_WINDOW_INDEX:-0}"`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`

## Usage

`/doey-purge` — full audit + fix (2-wave dispatch)
`/doey-purge runtime` — clean stale runtime files only (no workers)

## Prompt

Session/team config injected above. Quick mode: run `doey purge --force`, report, stop.

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

Present as table, save for diffing after fixes.

### Wave 1: Audit (4 parallel workers)

Dispatch via `/doey-dispatch`. **All workers: Do NOT use the Agent tool.** Each writes to `${RUNTIME_DIR}/reports/purge_<domain>.md`. Rename panes: `/rename purge-<domain>_$(date +%m%d)`.

**Issue categories** (HIGH = breaks behavior, MED = confusing/outdated, LOW = nitpick): BLOAT, REDUNDANCY, STALENESS, CONTRADICTION, DEAD WEIGHT, BASH 3.2, BUG, DEAD CODE.

**Worker assignments:** A=Agents+CLAUDE.md, B=Hooks+Shell+Settings, C=Skills, D=Docs+README+Memory.

**Report format per file:** `## File: path (N lines)` → Issues with `CATEGORY [severity] [lines]: description + fix` → `Condensation Estimate: N → ~M (-X%)` → Summary totals.

**Worker task template:**
```
You are Worker N auditing [DOMAIN] for Doey Purge.
Project directory: PROJECT_DIR | **No Agent tool — read files directly.**
Goal: context rot + code quality. Read all files in domain: [LIST].
Cross-ref against filesystem. Issues with line numbers + severity.
Condensation estimate per file. Write report to REPORT_PATH.
If a hook enforces a rule, agents don't need to repeat it.
Every .sh file: bash 3.2 — violations are HIGH.
```

### Between Waves

Read all `${RUNTIME_DIR}/reports/purge_*.md`. Present consolidated summary (files scanned, issue counts by category/severity, top savings, critical must-fix). Propose Wave 2 assignments. **Ask user before dispatching fixes.**

### Wave 2: Fix (4 parallel workers)

Assign by file ownership (avoid edit conflicts): A=agents+CLAUDE.md, B=hooks+shell, C=skills, D=docs+README+memory. Rename: `/rename fix-<domain>_$(date +%m%d)`.

All fix workers: `Edit` not `Write`. Read before editing. Condense — **fewer words, not lost information**. `.sh` files: `bash -n` after every edit. Bash 3.2 compatible.

### Verification

Re-run inventory `wc -l` command, diff against `purge_before.txt`, then:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
echo "=== Syntax check ==="
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
echo "=== Context audit ===" && bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

Highlight files that shrank. If issues remain, offer another fix round.

### Rules

1. **No Agent tool** in worker prompts — prevents context overflow
2. **Ask user before Wave 2** — never auto-fix without confirmation
3. **Read reports before presenting** — don't summarize from memory
4. **Bash 3.2 violations are HIGH** — they break on macOS
