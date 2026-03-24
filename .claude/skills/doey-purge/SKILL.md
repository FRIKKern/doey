---
name: doey-purge
description: Two-wave purge — audit every project file for context rot and code issues, then fix. Use when you need to "audit the codebase", "clean up context rot", or "purge stale content".
---

## Context

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`
- Window index: !`echo "${DOEY_WINDOW_INDEX:-0}"`
- Team environment: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/team_${DOEY_WINDOW_INDEX:-0}.env 2>/dev/null || true`

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

Present as table, save for diffing.

### Wave 1: Audit (4 parallel workers)

Dispatch via `/doey-dispatch`. **No Agent tool in worker prompts.** Each writes `${RUNTIME_DIR}/reports/purge_<domain>.md`. Rename panes: `purge-<domain>_$(date +%m%d)`.

**Categories** (HIGH/MED/LOW): BLOAT, REDUNDANCY, STALENESS, CONTRADICTION, DEAD WEIGHT, BASH 3.2, BUG, DEAD CODE.

**Assignments:** A=Agents+CLAUDE.md, B=Hooks+Shell+Settings, C=Skills, D=Docs+README+Memory.

**Report format:** `## File: path (N lines)` → `CATEGORY [severity] [lines]: description + fix` → `Condensation Estimate: N → ~M (-X%)` → Summary.

**Worker template:** `You are Worker N auditing [DOMAIN]. Project: PROJECT_DIR. No Agent tool. Read all files in [LIST]. Cross-ref filesystem. Issues with line numbers + severity. Condensation estimate. Write to REPORT_PATH. Hooks enforce rules → agents needn't repeat. .sh files: bash 3.2 violations = HIGH.`

### Between Waves

Read all `purge_*.md` reports. Present consolidated summary (files, issue counts, top savings, must-fix). Propose Wave 2 assignments. **Ask user before dispatching fixes.**

### Wave 2: Fix (4 parallel workers)

Assign by file ownership (avoid conflicts): A=agents+CLAUDE.md, B=hooks+shell, C=skills, D=docs+README+memory.

All workers: `Edit` not `Write`. Read before editing. Condense — **fewer words, not lost info**. `.sh`: `bash -n` after every edit. Bash 3.2 compatible.

### Verification

Re-run `wc -l`, diff against `purge_before.txt`, then:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
echo "=== Syntax check ==="
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
echo "=== Context audit ===" && bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

### Rules

1. **No Agent tool** in worker prompts — prevents context overflow
2. **Ask user before Wave 2** — never auto-fix without confirmation
3. **Bash 3.2 violations are HIGH** — they break on macOS
