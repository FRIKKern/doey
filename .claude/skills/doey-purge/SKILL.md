---
name: doey-purge
description: Two-wave purge — audit every project file for context rot and code issues, then fix. Use when you need to "audit the codebase", "clean up context rot", or "purge stale content".
---

- Session config: !`cat $(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)/session.env 2>/dev/null || true`

Usage: `/doey-purge` (2-wave audit+fix) | `runtime` (clean stale files only)

### Inventory
```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RD}/session.env"
mkdir -p "${RD}/reports"
wc -l "$PROJECT_DIR"/{agents/*.md,CLAUDE.md,.claude/skills/*/SKILL.md,docs/*.md,.claude/hooks/*.sh,shell/*.sh} 2>/dev/null | sort -rn | tee "${RD}/reports/purge_before.txt"
```

### Wave 1: Audit (4 workers via `/doey-dispatch`, no Agent)
Each writes `${RD}/reports/purge_<domain>.md`.
Categories (HIGH/MED/LOW): BLOAT, REDUNDANCY, STALENESS, CONTRADICTION, DEAD WEIGHT, BASH 3.2, BUG, DEAD CODE.
Assignments: A=Agents+CLAUDE.md, B=Hooks+Shell, C=Skills, D=Docs+README.

### Between Waves — **ask user before fixes**

### Wave 2: Fix (same ownership, Edit not Write, `bash -n` after .sh)

### Verify
```bash
source "${RD}/session.env"
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

No Agent tool in worker prompts.
