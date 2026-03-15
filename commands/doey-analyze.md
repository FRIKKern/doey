# Skill: doey-analyze

Run a full project analysis to detect documentation obscurities, inaccuracies, contradictions, gaps, and bash 3.2 violations across all context files. Dispatches parallel analysis workers, collects reports, then dispatches fix workers.

## Usage
`/doey-analyze`

## Prompt
You are the Doey Manager running a full-project analysis sweep. This is a two-wave operation: first analyze, then fix.

### Project Context

Every Bash call that touches tmux must start with:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
```
This gives you: `SESSION_NAME`, `PROJECT_DIR`, `PROJECT_NAME`, `WORKER_PANES`, `WATCHDOG_PANE`.

### What to Analyze

The analysis covers ALL context files that Claude Code instances consume:

| Category | Location | Examples |
|----------|----------|---------|
| CLAUDE.md files | Project root + parents | Architecture, conventions, important files |
| Agent definitions | `agents/*.md` | Manager, Watchdog, Test Driver roles |
| Hook scripts | `.claude/hooks/*.sh` | Safety rules, context injection, status tracking |
| Commands/skills | `commands/*.md` | Slash commands available to agents |
| Documentation | `docs/*.md` | Context reference, platform guides |
| Shell scripts | `shell/*.sh` | CLI launcher, utilities |
| Config | `.claude/settings.local.json` | Permissions, hook registration |
| Install | `install.sh` | What gets installed where |
| Other | `README.md`, `tests/`, memory files | User-facing docs, E2E tests |

### Issue Categories

Each worker classifies findings as:

- **INACCURATE** — doc says X, code does Y (with file:line references)
- **CONTRADICTORY** — file A says X, file B says Y
- **OBSCURE** — unclear, misleading, or confusing documentation
- **GAPS** — undocumented behavior that should be documented
- **REDUNDANT** — same thing in multiple places (drift risk)
- **CODE QUALITY** — bash 3.2 violations, bugs, race conditions, dead code
- **OUTDATED** — references to removed or changed features

Severity: HIGH (actively misleading/buggy), MED (confusing/outdated), LOW (nitpick).

### Wave 1: Analysis (parallel)

Dispatch 4 workers, each owning a domain. Use `/doey-dispatch` or direct dispatch. **Tell workers: Do NOT use the Agent tool — read files directly to avoid context overflow.**

Each worker writes a structured report to `${RUNTIME_DIR}/reports/analyze_<domain>.md`.

#### Worker A: Agent Definitions & CLAUDE.md
- **Read:** All agent `.md` files, both CLAUDE.md files
- **Cross-ref:** `shell/doey.sh` (launch logic, env vars), `.claude/hooks/` (actual rules), `commands/` (referenced commands)
- **Report:** `${RUNTIME_DIR}/reports/analyze_agents.md`

#### Worker B: Hooks & Safety Rules
- **Read:** All 10 `.claude/hooks/*.sh` files, `.claude/settings.local.json`
- **Cross-ref:** Agent definitions (claimed behaviors), `docs/context-reference.md` (hook descriptions)
- **Focus:** Bash 3.2 violations (`[[ ]]`, `shopt`, `read -a`, `$'\n'`, `+=`), exit code accuracy, race conditions, dead code
- **Report:** `${RUNTIME_DIR}/reports/analyze_hooks.md`

#### Worker C: Commands/Skills
- **Read:** All 17 `commands/*.md` files
- **Cross-ref:** Agent definitions (command references), `README.md` (command table), `shell/doey.sh` (session.env vars)
- **Focus:** Consistent patterns (idle detection, copy-mode, error handling, mkdir -p), bash 3.2 in code blocks
- **Report:** `${RUNTIME_DIR}/reports/analyze_commands.md`

#### Worker D: Docs, README, Install & Shell
- **Read:** `docs/context-reference.md`, `README.md`, `install.sh`, `docs/*.md`, `shell/*.sh`
- **Cross-ref:** Actual file structure, actual CLI commands, actual hook chain
- **Focus:** context-reference.md accuracy (master architecture doc), README completeness, install correctness
- **Report:** `${RUNTIME_DIR}/reports/analyze_docs.md`

### Worker Task Template

```
You are Worker N analyzing [DOMAIN] for the Doey Analyze project.
Project directory: PROJECT_DIR

**CRITICAL: Do NOT use the Agent tool. Read files directly yourself.**

**Goal:** Find all inaccuracies, contradictions, obscurities, gaps, and redundancies.

**Step 1:** Read these files (Read tool): [LIST]
**Step 2:** Cross-check claims via Grep: [TARGETS]
**Step 3:** Write report to REPORT_PATH using Write tool.

Report format:
# Doey Analyze: [DOMAIN]
## Issues Found
### INACCURATE - [severity] file:line — what's wrong — what's true
### CONTRADICTORY - [severity] fileA vs fileB — contradiction
### OBSCURE - [severity] file:line — what's unclear
### GAPS - [severity] — what's missing
### REDUNDANT - [severity] files — what's duplicated
### CODE QUALITY - [severity] file:line — bugs, bash 3.2 violations
## Summary
- Total issues: N (HIGH: N, MED: N, LOW: N)
- Files needing updates: [list]
```

### Between Waves

After all 4 reports land:
1. Read all 4 report files from `${RUNTIME_DIR}/reports/analyze_*.md`
2. Present a consolidated summary table to the user: totals by severity, top HIGH issues, files needing most attention
3. Propose Wave 2 fix assignments
4. **Ask the user for confirmation** before dispatching fixes

### Wave 2: Fix (parallel)

Based on analysis findings, dispatch workers to fix issues. Typical assignment:

| Worker | Task | Priority |
|--------|------|----------|
| A | Fix bash 3.2 violations in hooks | Critical |
| B | Fix bash 3.2 violations in commands | Critical |
| C | Fix documentation inaccuracies (context-reference, README) | High |
| D | Fix agent definitions and CLAUDE.md | High |

**Important:** Tell fix workers to use Edit tool (not Write), read files before editing, and run `bash -n` on shell files after editing.

### Verification

After Wave 2, run:
```bash
# Syntax check all hooks
for f in .claude/hooks/*.sh; do bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"; done

# Check for bash 3.2 violations
grep -rn '\[\[' .claude/hooks/*.sh | grep -v 'grep\|sed\|echo\|check_pattern\|declare\|printf\|mapfile'

# Context audit
bash shell/context-audit.sh --repo
```

Present results to user. If clean, offer to commit + push. If issues remain, dispatch another fix round.

### Rules

1. **Always dispatch with "Do NOT use the Agent tool"** — subagent research overflows context and triggers compaction data loss
2. **Always rename panes before dispatching** — `/rename analyze-<domain>_$(date +%m%d)` for Wave 1, `/rename fix-<domain>_$(date +%m%d)` for Wave 2
3. **Always verify dispatch** — sleep 5s, check for tool activity
4. **Always read reports before presenting** — don't summarize from memory
5. **Ask user before Wave 2** — analysis findings may change priorities
6. **Run /simplify after fixes** — catches reuse opportunities and quality issues the fix workers missed
