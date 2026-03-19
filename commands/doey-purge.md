# Skill: doey-purge

Two-wave audit+fix: finds context rot (bloat, redundancy, staleness, contradictions) and code quality issues (bash 3.2, bugs, dead code), then fixes them.

## Usage
`/doey-purge` — full audit + fix (2-wave worker dispatch)
`/doey-purge runtime` — just clean stale runtime files (runs `doey purge --force`)

## Prompt

### Project Context
Same as `/doey-dispatch` — source `session.env` and team env.

### Quick mode: `/doey-purge runtime`
Run `doey purge --force`, report results, stop.

### Full mode (default)

#### Step 0: Inventory

```bash
BEFORE="${RUNTIME_DIR}/reports/purge_before.txt"
mkdir -p "${RUNTIME_DIR}/reports"
wc -l "$PROJECT_DIR"/{agents,commands,docs}/*.md "$PROJECT_DIR"/CLAUDE.md \
      "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh 2>/dev/null | sort -rn | tee "$BEFORE"
```

#### Wave 1: Audit (4 parallel workers)

Dispatch via `/doey-dispatch`. All workers: **Do NOT use the Agent tool.** Write to `${RUNTIME_DIR}/reports/purge_<domain>.md`.

**Issue categories:** BLOAT, REDUNDANCY, STALENESS, CONTRADICTION, DEAD WEIGHT (context); BASH 3.2, BUG, DEAD CODE (code). Severity: HIGH/MED/LOW.

| Worker | Domain | Files | Key Focus |
|--------|--------|-------|-----------|
| A | Agents + CLAUDE.md | `agents/*.md`, `CLAUDE.md` | Env vars match hooks? Redundant with hooks? Stale refs? |
| B | Hooks + Shell | `.claude/hooks/*.sh`, `shell/*.sh`, settings | Bash 3.2 violations, race conditions, dead code |
| C | Commands | `commands/*.md` | Overlap, repeated boilerplate, bash 3.2 in code blocks |
| D | Docs + Memory | `docs/*.md`, `README.md`, agent memory | Claims still true? Stale entries? |

**Worker task template:**
```
You are Worker N auditing [DOMAIN] for Doey Purge.
Project directory: PROJECT_DIR
**Do NOT use the Agent tool. Read files directly.**
**Goal:** Find every issue — context rot AND code quality.
Step 1: Read all files. Step 2: Cross-reference (ls, grep). Step 3: Issues with lines + severity. Step 4: Condensation estimate. Step 5: Write report to REPORT_PATH.
Format: `CATEGORY [severity] [lines N-M]: Description. Fix suggestion.`
Be aggressive on bloat. Hook-enforced rules don't need agent def repetition. Bash 3.2 violations = HIGH.
```

#### Between Waves

Read all reports. Present consolidated summary (files scanned, issue counts by category/severity, top savings, critical items). Propose Wave 2 assignments. **Ask user before proceeding.**

#### Wave 2: Fix (4 parallel workers)

Assign by file ownership (same A/B/C/D split). Tell fix workers:
- Use `Edit` not `Write`; read before editing
- **Condense, don't delete** — fewer words, same info
- `.sh` files: run `bash -n` after edits
- Code blocks: bash 3.2 compatible

#### Verification

```bash
wc -l "$PROJECT_DIR"/{agents,commands,docs}/*.md "$PROJECT_DIR"/CLAUDE.md \
      "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh 2>/dev/null | sort -rn > "${RUNTIME_DIR}/reports/purge_after.txt"
diff "${RUNTIME_DIR}/reports/purge_before.txt" "${RUNTIME_DIR}/reports/purge_after.txt" || true
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

### Rules
1. Dispatch with "Do NOT use Agent tool"; rename panes (`purge-`/`fix-` + domain + date)
2. Verify dispatch; read reports before presenting
3. Ask user before Wave 2; condense don't delete
4. Bash 3.2 violations = HIGH severity
