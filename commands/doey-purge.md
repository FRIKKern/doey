# Skill: doey-purge

Audits and fixes everything: context quality (bloat, redundancy, staleness, contradictions) and code quality (bash 3.2 violations, bugs, dead code). Two-wave worker dispatch: audit, then fix.

## Usage
`/doey-purge` — full audit + fix (2-wave dispatch)
`/doey-purge runtime` — clean stale runtime files only (no workers)

## Prompt
Two-wave purge: audit every project file, then fix.

### Preamble

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

### Quick mode: `/doey-purge runtime`

Run `doey purge --force`, report results, stop. No workers needed.

### Full mode (default)

#### Step 0: Inventory

```bash
BEFORE="${RUNTIME_DIR}/reports/purge_before.txt"
mkdir -p "${RUNTIME_DIR}/reports"
{
  wc -l "$PROJECT_DIR"/agents/*.md "$PROJECT_DIR"/CLAUDE.md \
        "$PROJECT_DIR"/commands/*.md "$PROJECT_DIR"/docs/*.md \
        "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh \
        "$PROJECT_DIR"/.claude/settings.local.json 2>/dev/null | sort -rn
  echo "--- Memory (Window Manager) ---"
  ls -la ~/.claude/agent-memory/doey-manager/ 2>/dev/null
  echo "--- Memory (Session Manager) ---"
  ls -la ~/.claude/agent-memory/doey-session-manager/ 2>/dev/null
} | tee "$BEFORE"
```

Present as table, save for diffing after fixes.

#### Wave 1: Audit (4 parallel workers)

Dispatch via `/doey-dispatch`. **All workers: Do NOT use the Agent tool.** Each writes to `${RUNTIME_DIR}/reports/purge_<domain>.md`.

##### Issue Categories

| Category | Description |
|----------|-------------|
| BLOAT | Verbose text, repeated instructions, overlong examples |
| REDUNDANCY | Same info in multiple files; instructions restating hook behavior |
| STALENESS | References to nonexistent files/commands/features |
| CONTRADICTION | Conflicting info between files |
| DEAD WEIGHT | Sections no agent reads |
| BASH 3.2 | `declare -A/-n/-l/-u`, `mapfile`, `|&`, `&>>`, `coproc`, etc. |
| BUG | Race conditions, wrong exit codes, logic errors |
| DEAD CODE | Unreachable branches, unused functions/variables |

Severity: **HIGH** (breaks behavior), **MED** (confusing/outdated), **LOW** (nitpick).

##### Worker Assignments

- **A — Agents + CLAUDE.md:** Read `agents/*.md`, `CLAUDE.md`. Check env var accuracy, hook redundancy, stale refs. Cross-ref against `commands/`, `.claude/hooks/`, `agents/`.
- **B — Hooks + Shell + Settings:** Read `.claude/hooks/*.sh`, `shell/*.sh`, `.claude/settings.local.json`, `install.sh`. Bash 3.2 violations (HIGH), race conditions, exit codes, dead code, setting/hook consistency.
- **C — Commands:** Read `commands/*.md`. Check for dead refs, overlap, repeated boilerplate, bash 3.2 in code blocks. Cross-ref in agents/docs/hooks.
- **D — Docs + README + Memory:** Read `docs/*.md`, `README.md`, memory dirs. Verify context-reference claims, command table accuracy, stale memory.

##### Report Format (per file)

```
## File: path/file.md (N lines)
### Issues
- CATEGORY [severity] [lines N-M]: Description. Fix suggestion.
### Condensation Estimate: N → ~M lines (-X%)
## Summary
- Total: N (HIGH: N, MED: N, LOW: N)
```

##### Worker Task Template

```
You are Worker N auditing [DOMAIN] for Doey Purge.
Project directory: PROJECT_DIR
**Do NOT use the Agent tool. Read files directly.**
Goal: Find every issue — context rot AND code quality.
1. Read all files in your domain: [LIST]
2. Cross-reference against filesystem (ls, grep) — verify every reference
3. Identify issues with line numbers and severity
4. Estimate condensation per file
5. Write report to REPORT_PATH
Be aggressive. If a hook enforces a rule, the agent def doesn't need to explain it.
Every .sh file must pass bash 3.2 — flag violations as HIGH.
```

#### Between Waves

Read all `${RUNTIME_DIR}/reports/purge_*.md`. Present consolidated summary (files scanned, issue counts by category/severity, top savings, critical must-fix items). Propose Wave 2 assignments. **Ask user for confirmation before dispatching fixes.**

#### Wave 2: Fix (4 parallel workers)

Assign by file ownership (avoid edit conflicts): A=agents+CLAUDE.md, B=hooks+shell, C=commands, D=docs+README+memory.

All fix workers: Use `Edit` not `Write`. Read before editing. Condense aggressively — **fewer words, not lost information**. `.sh` files: run `bash -n` after every edit. Commands: bash 3.2 compatible.

#### Verification

```bash
AFTER="${RUNTIME_DIR}/reports/purge_after.txt"
wc -l "$PROJECT_DIR"/agents/*.md "$PROJECT_DIR"/CLAUDE.md \
      "$PROJECT_DIR"/commands/*.md "$PROJECT_DIR"/docs/*.md \
      "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh \
      "$PROJECT_DIR"/.claude/settings.local.json 2>/dev/null | sort -rn > "$AFTER"
echo "=== Before/After ===" && diff "${RUNTIME_DIR}/reports/purge_before.txt" "$AFTER" || true
echo "=== Syntax check ==="
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
echo "=== Context audit ===" && bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

Highlight files that shrank. If issues remain, offer another fix round.

### Rules

1. **Dispatch with "Do NOT use the Agent tool"** — prevents context overflow
2. **Rename panes** — `/rename purge-<domain>_$(date +%m%d)` (Wave 1), `/rename fix-<domain>_$(date +%m%d)` (Wave 2)
3. **Verify dispatch** — sleep 5s, check for tool activity
4. **Read reports before presenting** — don't summarize from memory
5. **Ask user before Wave 2** — never auto-fix without confirmation
6. **Condense, don't delete** — fewer tokens, same information
7. **Bash 3.2 violations are always HIGH** — they break on macOS
