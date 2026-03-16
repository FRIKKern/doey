# Skill: doey-analyze

Run a full project analysis sweep: dispatch 4 analysis workers in parallel across all domains, consolidate findings, then dispatch fix workers for confirmed issues.

## Usage
`/doey-analyze`

## Prompt
You are running a two-wave project analysis as the Doey Manager.

### Project Context (read once per Bash call)

Every Bash call that touches tmux must start with:

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```

This provides: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`, `PASTE_SETTLE_MS` (default 500). **Always use `${SESSION_NAME}`** — never hardcode session names.

### Overview

| Wave | Purpose | Workers | Output |
|------|---------|---------|--------|
| 1 | Analysis | 4 parallel | `${RUNTIME_DIR}/reports/analyze_<domain>.md` |
| (pause) | Consolidate & confirm | Manager reads reports | Summary to user |
| 2 | Fix | N workers (grouped by domain) | Edited files |
| (verify) | Syntax & compat checks | Manager | Results to user |

---

### Wave 1: Analysis

Dispatch 4 workers in parallel via `/doey-dispatch`. Each analyzes one domain and writes a structured report.

**Before dispatching each worker:**
1. Check idle + not reserved
2. Rename pane: `/rename analyze-<domain>_$(date +%m%d)`
3. Create report directory: `mkdir -p "${RUNTIME_DIR}/reports"`

**After dispatching all 4:**
1. Verify each (sleep 5s, capture-pane)
2. Monitor with `/doey-monitor` until all 4 finish

#### Worker A: Agent Definitions & CLAUDE.md

```
You are Worker A analyzing AGENT DEFINITIONS & CLAUDE.md for the Doey project.
Project directory: ${PROJECT_DIR}

**CRITICAL: Do NOT use the Agent tool. Read files directly yourself.**

**Goal:** Find all inaccuracies, contradictions, obscurities, gaps, and redundancies in agent definitions and CLAUDE.md files.

**Step 1:** Read these files (Read tool):
- ${PROJECT_DIR}/CLAUDE.md
- All files matching agents/*.md (use Glob to find them)
- ${PROJECT_DIR}/.claude/settings.local.json

**Step 2:** Cross-check claims by reading:
- ${PROJECT_DIR}/shell/doey.sh (launch logic, env vars, pane assignments)
- Grep for referenced commands/skills in commands/ directory
- Grep for referenced hooks behavior in .claude/hooks/

**Step 3:** Check specifically:
- Do agent definitions match actual pane assignments in doey.sh?
- Do CLAUDE.md "Important Files" and descriptions match reality?
- Are model assignments (Opus/Haiku) accurate?
- Do agent definitions reference commands that exist?
- Are env vars documented correctly?
- Is the architecture description (Manager/Watchdog/Worker) accurate?

**Step 4:** Write report to ${RUNTIME_DIR}/reports/analyze_agents.md using Write tool.

Report format:
# Doey Analyze: Agent Definitions & CLAUDE.md
## Issues Found
### INACCURATE
- [severity] file:line — what's wrong — what's true
### CONTRADICTORY
- [severity] fileA vs fileB — contradiction
### OBSCURE
- [severity] file:line — what's unclear
### GAPS
- [severity] — what's missing
### REDUNDANT
- [severity] files — what's duplicated
### CODE QUALITY
- [severity] file:line — bugs, issues
### OUTDATED
- [severity] file:line — references to removed/changed features
## Summary
- Total issues: N (HIGH: N, MED: N, LOW: N)
- Files needing updates: [list]
```

#### Worker B: Hooks & Safety Rules

```
You are Worker B analyzing HOOKS & SAFETY RULES for the Doey project.
Project directory: ${PROJECT_DIR}

**CRITICAL: Do NOT use the Agent tool. Read files directly yourself.**

**Goal:** Find bugs, bash 3.2 violations, incorrect exit codes, race conditions, and dead code in all hook scripts.

**Step 1:** Read all hook files:
- ${PROJECT_DIR}/.claude/hooks/common.sh
- ${PROJECT_DIR}/.claude/hooks/on-session-start.sh
- ${PROJECT_DIR}/.claude/hooks/on-prompt-submit.sh
- ${PROJECT_DIR}/.claude/hooks/on-pre-tool-use.sh
- ${PROJECT_DIR}/.claude/hooks/on-pre-compact.sh
- ${PROJECT_DIR}/.claude/hooks/post-tool-lint.sh
- ${PROJECT_DIR}/.claude/hooks/stop-status.sh
- ${PROJECT_DIR}/.claude/hooks/stop-results.sh
- ${PROJECT_DIR}/.claude/hooks/stop-notify.sh
- ${PROJECT_DIR}/.claude/hooks/watchdog-scan.sh

**Step 2:** Read ${PROJECT_DIR}/.claude/settings.local.json for hook registration.

**Step 3:** Check specifically:
- Bash 3.2 violations: declare -A/-n/-l/-u, printf '%(%s)T', mapfile/readarray, |&, &>>, coproc, [[ =~ with capture groups
- Exit codes: 0=allow, 1=block+error, 2=block+feedback — verify each hook uses correctly
- Race conditions: tmp file creation, atomic writes, concurrent access patterns
- Dead code: unreachable branches, unused variables, directories created but never used
- Security: source/eval on world-writable paths, unsanitized input in tmux commands
- Hook event matching: do settings.local.json matchers align with what hooks expect?
- Error handling: does set -euo pipefail interact badly with any patterns?

**Step 4:** Write report to ${RUNTIME_DIR}/reports/analyze_hooks.md using Write tool.

Report format:
# Doey Analyze: Hooks & Safety Rules
## Issues Found
### INACCURATE
- [severity] file:line — what's wrong — what's true
### CONTRADICTORY
- [severity] fileA vs fileB — contradiction
### OBSCURE
- [severity] file:line — what's unclear
### GAPS
- [severity] — what's missing
### REDUNDANT
- [severity] files — what's duplicated
### CODE QUALITY
- [severity] file:line — bugs, bash 3.2 violations
### OUTDATED
- [severity] file:line — references to removed/changed features
## Summary
- Total issues: N (HIGH: N, MED: N, LOW: N)
- Files needing updates: [list]
```

#### Worker C: Commands & Skills

```
You are Worker C analyzing COMMANDS & SKILLS for the Doey project.
Project directory: ${PROJECT_DIR}

**CRITICAL: Do NOT use the Agent tool. Read files directly yourself.**

**Goal:** Find inconsistencies, missing setup steps, bash 3.2 violations in code blocks, and gaps across all command files.

**Step 1:** Read all command files in ${PROJECT_DIR}/commands/ (use Glob to find them).

**Step 2:** Cross-check with:
- ${PROJECT_DIR}/agents/doey-manager.md (commands referenced by Manager)
- ${PROJECT_DIR}/.claude/hooks/common.sh (helper functions used by commands)
- ${PROJECT_DIR}/shell/doey.sh (session.env variables available)

**Step 3:** Check specifically:
- Do all commands follow the pattern: # Skill: name + ## Usage + ## Prompt?
- Do code blocks use correct session.env variables?
- Are mkdir -p calls present where needed (messages/, reports/, research/)?
- Do commands reference helpers that exist (is_worker, is_manager, etc.)?
- Are bash 3.2 violations present in embedded code blocks?
- Do dispatch commands include all mandatory steps (copy-mode, rename, verify)?
- Is PANE_SAFE computed consistently across all commands?
- Do any commands reference files/dirs that don't exist?

**Step 4:** Write report to ${RUNTIME_DIR}/reports/analyze_commands.md using Write tool.

Report format:
# Doey Analyze: [DOMAIN]
## Issues Found
### INACCURATE
- [severity] file:line — what's wrong — what's true
### CONTRADICTORY
- [severity] fileA vs fileB — contradiction
### OBSCURE
- [severity] file:line — what's unclear
### GAPS
- [severity] — what's missing
### REDUNDANT
- [severity] files — what's duplicated
### CODE QUALITY
- [severity] file:line — bugs, issues
### OUTDATED
- [severity] file:line — references to removed/changed features
## Summary
- Total issues: N (HIGH: N, MED: N, LOW: N)
- Files needing updates: [list]
```

#### Worker D: Docs, README, Install & Shell

```
You are Worker D analyzing DOCS, README, INSTALL & SHELL for the Doey project.
Project directory: ${PROJECT_DIR}

**CRITICAL: Do NOT use the Agent tool. Read files directly yourself.**

**Goal:** Find inaccuracies in documentation, install script issues, and shell launcher bugs.

**Step 1:** Read these files:
- ${PROJECT_DIR}/README.md
- ${PROJECT_DIR}/docs/context-reference.md
- ${PROJECT_DIR}/install.sh
- ${PROJECT_DIR}/shell/doey.sh

**Step 2:** Cross-check docs against reality:
- Glob for all files mentioned in README — do they exist?
- Does install.sh copy all necessary files?
- Does context-reference.md accurately describe the context layers?
- Does README architecture match agent definitions?

**Step 3:** Check specifically:
- README: CLI usage, architecture diagram, pane assignments, prerequisites
- context-reference.md: are all context layers documented? Missing any?
- install.sh: does it handle all agents, commands, hooks? Idempotent?
- shell/doey.sh: bash 3.2 violations, error handling, edge cases (no tmux, small terminal)
- Are version numbers, file paths, and directory structures accurate?

**Step 4:** Write report to ${RUNTIME_DIR}/reports/analyze_docs.md using Write tool.

Report format:
# Doey Analyze: [DOMAIN]
## Issues Found
### INACCURATE
- [severity] file:line — what's wrong — what's true
### CONTRADICTORY
- [severity] fileA vs fileB — contradiction
### OBSCURE
- [severity] file:line — what's unclear
### GAPS
- [severity] — what's missing
### REDUNDANT
- [severity] files — what's duplicated
### CODE QUALITY
- [severity] file:line — bugs, issues
### OUTDATED
- [severity] file:line — references to removed/changed features
## Summary
- Total issues: N (HIGH: N, MED: N, LOW: N)
- Files needing updates: [list]
```

---

### Between Waves: Consolidate & Confirm

After all 4 analysis workers finish:

1. **Read all 4 reports** — use the Read tool on each file. Do NOT summarize from memory.

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
ls -la "${RUNTIME_DIR}/reports/analyze_"*.md
```

Then use Read tool on:
- `${RUNTIME_DIR}/reports/analyze_agents.md`
- `${RUNTIME_DIR}/reports/analyze_hooks.md`
- `${RUNTIME_DIR}/reports/analyze_commands.md`
- `${RUNTIME_DIR}/reports/analyze_docs.md`

2. **Present consolidated summary** to the user:

```
## Analysis Complete — 4 domains scanned

| Domain | Issues | HIGH | MED | LOW |
|--------|--------|------|-----|-----|
| Agents & CLAUDE.md | N | N | N | N |
| Hooks & Safety | N | N | N | N |
| Commands & Skills | N | N | N | N |
| Docs & Shell | N | N | N | N |
| **Total** | **N** | **N** | **N** | **N** |

### HIGH Priority Issues
1. [file] — description
2. [file] — description
...

### MED Priority Issues
1. [file] — description
...

Shall I proceed with Wave 2 to fix these issues?
```

3. **Wait for user confirmation** before proceeding to Wave 2. The user may want to:
   - Fix only HIGH issues
   - Skip certain fixes
   - Reprioritize
   - Add additional fixes not found by analysis

---

### Wave 2: Fix

After user confirms, dispatch fix workers grouped by domain. Each worker gets:
- The specific issues to fix (copied from reports)
- The exact files to edit (absolute paths)
- Instructions to use Edit tool (not Write) for all changes
- Instruction to run `bash -n` on every shell file after editing

**Worker task template for fixes:**

```
You are a Worker fixing <DOMAIN> issues for the Doey project.
Project directory: ${PROJECT_DIR}

**CRITICAL: Do NOT use the Agent tool. Read files and edit them directly yourself.**

**Goal:** Fix N issues found during analysis.

**Read each file before editing. Use Edit tool (not Write) for all changes. Run `bash -n` on each file after editing.**

---

**Fix 1: <file> — <description> (<severity>)**
- Read: <absolute path>
- Problem: <what's wrong>
- Fix: <what to change>

**Fix 2: <file> — <description> (<severity>)**
...

**After all edits, run:**
bash -n <each edited shell file>

**Constraints:**
- Bash 3.2 compatible only
- Use Edit tool, not Write
- Read each file fully before editing
- Preserve existing logic — only reorder/fix, don't refactor
```

**Dispatch rules for Wave 2:**
- Group fixes by file ownership — one worker per domain to avoid edit conflicts
- If two domains need to edit the same file, dispatch sequentially
- Rename panes: `/rename fix-<domain>_$(date +%m%d)`

---

### Verification

After all fix workers finish:

1. **Syntax check all hook scripts:**
```bash
cd "${PROJECT_DIR}"
for f in .claude/hooks/*.sh; do
  bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"
done
```

2. **Check for bash 3.2 violations:**
```bash
cd "${PROJECT_DIR}"
grep -rn 'declare -[Anlu]' .claude/hooks/ shell/ 2>/dev/null && echo "VIOLATION: declare flags" || echo "OK: no declare violations"
grep -rn 'mapfile\|readarray' .claude/hooks/ shell/ 2>/dev/null && echo "VIOLATION: mapfile/readarray" || echo "OK: no mapfile violations"
grep -rn "printf '%(%s)T'" .claude/hooks/ shell/ 2>/dev/null && echo "VIOLATION: printf timestamp" || echo "OK: no printf timestamp violations"
```

3. **Present results** to user and suggest running `/simplify` on changed files.

---

### Rules

1. **Always dispatch with "Do NOT use the Agent tool"** — subagent research overflows worker context windows and produces worse results than direct file reads
2. **Always rename panes before dispatching** — `/rename analyze-<domain>_$(date +%m%d)` for Wave 1, `/rename fix-<domain>_$(date +%m%d)` for Wave 2
3. **Always verify dispatch** — sleep 5s, capture-pane, check for activity
4. **Always read reports before presenting** — use Read tool on each report file, do not summarize from memory or prior context
5. **Ask user before Wave 2** — analysis findings may change priorities; the user decides what to fix
6. **Run /simplify after fixes** — catch any quality issues introduced during fixes
7. **Never dispatch to reserved panes** — check reservation status before every dispatch
8. **Assign distinct files per worker** — avoid edit conflicts in Wave 2
