# Skill: doey-analyze

Full project analysis: detect doc inaccuracies, contradictions, gaps, and bash 3.2 violations. Dispatches parallel analysis workers, collects reports, then dispatches fix workers.

## Usage
`/doey-analyze`

## Prompt
You are the Doey Window Manager running a two-wave analysis sweep (analyze, then fix).

### Project Context

Use `doey status` to check worker availability before dispatching:
```bash
doey status
```

For tmux operations (dispatching workers, capturing panes), use the standard preamble:
```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```
This preamble is only needed for dispatch and tmux send-keys operations — not for status checks.

### Scope

Analyze ALL context files: CLAUDE.md files, `agents/*.md`, `.claude/hooks/*.sh`, `commands/*.md`, `docs/*.md`, `shell/*.sh`, `.claude/settings.local.json`, `install.sh`, `README.md`, `tests/`, memory files.

### Issue Categories

- **INACCURATE** — doc says X, code does Y (file:line refs)
- **CONTRADICTORY** — file A says X, file B says Y
- **OBSCURE** — unclear or misleading docs
- **GAPS** — undocumented behavior
- **REDUNDANT** — duplicated info (drift risk)
- **CODE QUALITY** — bash 3.2 violations, bugs, race conditions, dead code
- **OUTDATED** — references to removed/changed features

Severity: HIGH (misleading/buggy), MED (confusing/outdated), LOW (nitpick).

### Wave 1: Analysis (parallel)

Dispatch 4 workers via `/doey-dispatch`. **Tell all workers: Do NOT use the Agent tool.** Each writes to `${RUNTIME_DIR}/reports/analyze_<domain>.md`.

**Worker A — Agents & CLAUDE.md:** Read all agent `.md` + both CLAUDE.md. Cross-ref `shell/doey.sh`, `.claude/hooks/`, `commands/`.

**Worker B — Hooks & Safety:** Read all `.claude/hooks/*.sh` + `settings.local.json`. Cross-ref agent defs, `docs/context-reference.md`. Focus: bash 3.2 violations (`declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `[[ =~` capture groups, `${var,,}`/`${var^^}`, `globstar`/`lastpipe`), exit codes, races, dead code.

**Worker C — Commands/Skills:** Read all `commands/*.md`. Cross-ref agent defs, `README.md`, `shell/doey.sh`. Focus: consistent patterns (idle detection, copy-mode, error handling, mkdir -p), bash 3.2 in code blocks.

**Worker D — Docs, README, Install & Shell:** Read `docs/*.md`, `README.md`, `install.sh`, `shell/*.sh`. Cross-ref actual file structure, CLI commands, hook chain. Focus: context-reference.md accuracy, README completeness, install correctness.

### Worker Task Template

```
You are Worker N analyzing [DOMAIN] for Doey Analyze.
Project directory: PROJECT_DIR

**Do NOT use the Agent tool. Read files directly.**

**Step 1:** Read: [LIST]
**Step 2:** Cross-check via Grep: [TARGETS]
**Step 3:** Write report to REPORT_PATH.

Report format:
# Doey Analyze: [DOMAIN]
## Issues Found
### CATEGORY - [severity] file:line — description
## Summary
- Total: N (HIGH: N, MED: N, LOW: N)
- Files needing updates: [list]
```

### Between Waves

After dispatching Wave 1, monitor with:
```bash
doey status
```

Once all 4 workers show FINISHED/READY:
1. Read all reports from `${RUNTIME_DIR}/reports/analyze_*.md`
2. Present consolidated summary: totals by severity, top HIGH issues, files needing attention
3. Propose Wave 2 fix assignments
4. **Ask user for confirmation** before dispatching fixes

### Wave 2: Fix (parallel)

Dispatch workers to fix issues by priority:
- **A:** Fix bash 3.2 violations in hooks (Critical)
- **B:** Fix bash 3.2 violations in commands (Critical)
- **C:** Fix doc inaccuracies — context-reference, README (High)
- **D:** Fix agent definitions and CLAUDE.md (High)

Tell fix workers: use Edit tool (not Write), read before editing, run `bash -n` on shell files after.

### Verification

After Wave 2:
```bash
for f in .claude/hooks/*.sh; do bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"; done
grep -rn '\[\[' .claude/hooks/*.sh | grep -v 'grep\|sed\|echo\|check_pattern\|declare\|printf\|mapfile'
bash shell/context-audit.sh --repo
```

Present results. If clean, offer to commit + push. If issues remain, dispatch another fix round.

### Rules

1. **Always dispatch with "Do NOT use the Agent tool"** — prevents context overflow
2. **Always rename panes** — `/rename analyze-<domain>_$(date +%m%d)` for Wave 1, `/rename fix-<domain>_$(date +%m%d)` for Wave 2
3. **Verify dispatch** — sleep 5s, check for tool activity
4. **Read reports before presenting** — don't summarize from memory
5. **Ask user before Wave 2**
6. **Run /simplify after fixes**
