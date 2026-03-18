# Skill: doey-purge

The one command that audits and fixes everything. Covers context quality (bloat, redundancy, staleness, contradictions) AND code quality (bash 3.2 violations, bugs, dead code) across all files agents consume. Two-wave worker dispatch: audit, then fix.

## Usage
`/doey-purge` — full audit + fix (2-wave worker dispatch)
`/doey-purge runtime` — just clean stale runtime files (quick, no workers)

## Prompt
You are the Doey Window Manager running a full purge — a two-wave sweep that audits every file in the project for context rot and code quality issues, then fixes them.

### Project Context

```bash
RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "${RUNTIME_DIR}/session.env"
WINDOW_INDEX="${DOEY_WINDOW_INDEX:-0}"
TEAM_ENV="${RUNTIME_DIR}/team_${WINDOW_INDEX}.env"
[ -f "$TEAM_ENV" ] && source "$TEAM_ENV"
```

### Quick mode: `/doey-purge runtime`

If the user passed `runtime`, just clean stale files and stop:
```bash
doey purge --force
```
Report what was cleaned and exit. No worker dispatch needed.

### Full mode: `/doey-purge` (default)

#### Step 0: Inventory

```bash
BEFORE="${RUNTIME_DIR}/reports/purge_before.txt"
mkdir -p "${RUNTIME_DIR}/reports"
{
  wc -l "$PROJECT_DIR"/agents/*.md \
        "$PROJECT_DIR"/CLAUDE.md \
        "$PROJECT_DIR"/commands/*.md \
        "$PROJECT_DIR"/docs/*.md \
        "$PROJECT_DIR"/.claude/hooks/*.sh \
        "$PROJECT_DIR"/shell/*.sh \
        "$PROJECT_DIR"/.claude/settings.local.json 2>/dev/null | sort -rn
  echo "--- Memory (Window Manager) ---"
  ls -la ~/.claude/agent-memory/doey-manager/ 2>/dev/null
  echo "--- Memory (Session Manager) ---"
  ls -la ~/.claude/agent-memory/doey-session-manager/ 2>/dev/null
} | tee "$BEFORE"
```

Present as a table. The before-state is saved to `$BEFORE` for diffing after fixes. Then proceed to Wave 1.

#### Wave 1: Audit (4 parallel workers)

Dispatch 4 workers via `/doey-dispatch`. **Tell all workers: Do NOT use the Agent tool.** Each writes to `${RUNTIME_DIR}/reports/purge_<domain>.md`.

##### Issue Categories

Context quality:
- **BLOAT** — Verbose text that could be said in fewer words. Repeated instructions. Overlong examples.
- **REDUNDANCY** — Same info in multiple files (drift risk). Instructions that restate what hooks enforce.
- **STALENESS** — References to files, commands, hooks, or features that no longer exist.
- **CONTRADICTION** — File A says X, file B says Y. Agent says X, hook enforces not-X.
- **DEAD WEIGHT** — Sections no agent reads. Instructions that can't be acted on.

Code quality:
- **BASH 3.2** — `declare -A/-n/-l/-u`, `printf '%(%s)T'`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `[[ =~` capture groups, `${var,,}`/`${var^^}`, `globstar`/`lastpipe`.
- **BUG** — Race conditions, unhandled errors, wrong exit codes, logic errors.
- **DEAD CODE** — Unreachable branches, unused functions, variables set but never read.

Severity: **HIGH** (breaks behavior or misleads agents), **MED** (confusing/outdated), **LOW** (nitpick/style).

##### Worker A — Agent Definitions + CLAUDE.md

Read all `agents/*.md` and `CLAUDE.md`. For each file assess all issue categories.

Cross-reference: `ls commands/`, `ls .claude/hooks/`, `ls agents/`, grep for every referenced file path, command name, and variable.

Focus areas:
- Are env vars documented correctly? Do they match what `session.env` and hooks actually provide?
- Are instructions redundant with hooks (e.g., agent says "always do X" but hook already enforces X)?
- Is the workflow description still accurate?
- Does every referenced command/file exist?

Report format:
```
# Purge Audit: Agent Definitions + CLAUDE.md
## File: agents/doey-manager.md (175 lines)
### Issues
- BLOAT [lines 12-22]: Setup section repeats env vars that hooks already set. Could be 3 lines.
- REDUNDANCY [line 48]: "Always rename pane" — also enforced by doey-dispatch.md step 3.
- STALE [line 95]: References `/doey-restart-window` — command was removed.
### Condensation Estimate: 175 → ~120 lines (-31%)
## Summary
- Total: N (HIGH: N, MED: N, LOW: N)
- Estimated savings: X lines across Y files
```

##### Worker B — Hooks + Shell Scripts + Settings

Read all `.claude/hooks/*.sh`, `shell/*.sh`, `.claude/settings.local.json`, `install.sh`.

Focus areas:
- **Bash 3.2 violations** in every `.sh` file (this is critical — project runs on macOS `/bin/bash`)
- Race conditions between hooks (status file writes, pane detection)
- Exit codes: correct usage of 0/1/2?
- Dead code: functions defined but never called, branches that can't trigger
- Settings: do permission rules match what hooks expect? Are hook registrations complete?
- Cross-ref: do hooks reference variables/files that actually exist?

Report: same format, per file.

##### Worker C — Commands (all `commands/*.md`)

Read all command files. For each assess all issue categories.

Cross-reference: grep each command name in `agents/*.md`, other `commands/*.md`, `docs/*.md`, `.claude/hooks/*.sh`.

Focus areas:
- Commands nobody references (dead weight)
- Commands that overlap in functionality
- Boilerplate repeated across commands (env setup, pane detection)
- Bash 3.2 violations in code blocks
- Consistent patterns: idle detection, copy-mode exit, error handling, mkdir -p
- Do all referenced commands/files/variables exist?

Report: same format, per command file.

##### Worker D — Docs + README + Memory

Read all `docs/*.md`, `README.md`, memory files (`~/.claude/agent-memory/doey-manager/`, `~/.claude/agent-memory/doey-session-manager/`).

Focus areas:
- `docs/context-reference.md`: is every claim still true? Verify each layer against actual files.
- `README.md`: does the command table match actual commands? Are feature descriptions accurate?
- Memory: stale entries about things that changed, entries that duplicate what's in code
- Docs that no agent ever reads or references
- Linode/platform docs: still accurate?

Report: same format, per file.

##### Worker Task Template

```
You are Worker N auditing [DOMAIN] for Doey Purge.
Project directory: PROJECT_DIR

**Do NOT use the Agent tool. Read files directly.**

**Goal:** Find every issue — context rot (bloat, redundancy, staleness, contradictions, dead weight) AND code quality (bash 3.2 violations, bugs, dead code).

**Step 1:** Read all files in your domain: [LIST]
**Step 2:** Cross-reference against actual filesystem (ls, grep) — verify every reference
**Step 3:** For each file, identify specific issues with line numbers and severity
**Step 4:** Estimate how much each file could be condensed
**Step 5:** Write report to REPORT_PATH

**Issue format:**
- CATEGORY [severity] [lines N-M]: Description. Specific fix suggestion.

Be aggressive. If something can be said in fewer words, flag it as BLOAT.
If a hook enforces a rule, the agent def doesn't need to repeat it in detail.
If info is in CLAUDE.md, it doesn't need to be in each agent def.
Every .sh file must pass bash 3.2 compatibility — flag violations as HIGH.
```

#### Between Waves

After all 4 reports land:
1. Read all reports from `${RUNTIME_DIR}/reports/purge_*.md`
2. Present consolidated summary:
   ```
   Doey Purge Audit
   ═════════════════
   Files scanned: 42
   Total issues: 61 (HIGH: 8, MED: 29, LOW: 24)

   By category:
     BLOAT: 22    REDUNDANCY: 11    STALENESS: 8
     CONTRADICTION: 4    BASH 3.2: 6    BUG: 3
     DEAD CODE: 2    DEAD WEIGHT: 5

   Top savings (context):
     agents/doey-manager.md       175 → ~120 lines  (-31%)
     commands/doey-worktree.md    315 → ~200 lines  (-37%)
     docs/context-reference.md    320 → ~250 lines  (-22%)

   Critical (must fix):
     - 6 bash 3.2 violations in hooks (will break on macOS)
     - 3 bugs in hook error handling
     - 4 stale command references
     - 2 contradictions between agent defs and hooks
   ```
3. Propose Wave 2 fix assignments
4. **Ask user for confirmation** before dispatching fixes

#### Wave 2: Fix (4 parallel workers)

Assign by file ownership to avoid edit conflicts:

- **Worker A:** Agent definitions + CLAUDE.md — condense, remove redundancy, fix stale refs
- **Worker B:** Hooks + shell scripts — fix bash 3.2 violations, bugs, dead code. Run `bash -n` after every edit.
- **Worker C:** Commands — condense verbose steps, remove dead cross-refs, fix bash in code blocks
- **Worker D:** Docs + README + memory — update context-reference, fix README, clean stale memory

Tell all fix workers:
- Use `Edit` (not `Write`) — preserve surrounding content
- Read the file before editing
- Condense aggressively: remove filler words, combine steps, eliminate repetition
- **Condense, don't delete** — say the same thing in fewer words, don't lose information
- For `.sh` files: run `bash -n` after every edit to verify syntax
- For commands: bash code blocks must be 3.2 compatible

#### Verification

After Wave 2:
```bash
BEFORE="${RUNTIME_DIR}/reports/purge_before.txt"
AFTER="${RUNTIME_DIR}/reports/purge_after.txt"
wc -l "$PROJECT_DIR"/agents/*.md \
      "$PROJECT_DIR"/CLAUDE.md \
      "$PROJECT_DIR"/commands/*.md \
      "$PROJECT_DIR"/docs/*.md \
      "$PROJECT_DIR"/.claude/hooks/*.sh \
      "$PROJECT_DIR"/shell/*.sh \
      "$PROJECT_DIR"/.claude/settings.local.json 2>/dev/null | sort -rn > "$AFTER"
echo "=== Before/After ==="
diff "$BEFORE" "$AFTER" || true
echo ""
echo "=== Syntax check ==="
for f in "$PROJECT_DIR"/.claude/hooks/*.sh "$PROJECT_DIR"/shell/*.sh; do
  bash -n "$f" && echo "OK: $(basename "$f")" || echo "FAIL: $(basename "$f")"
done
echo ""
echo "=== Context audit ==="
bash "$PROJECT_DIR/shell/context-audit.sh" --repo
```

Present the before/after diff — highlight files that shrank. If syntax or audit issues remain, offer another fix round.

### Rules

1. **Always dispatch with "Do NOT use the Agent tool"** — prevents context overflow
2. **Always rename panes** — `/rename purge-<domain>_$(date +%m%d)` for Wave 1, `/rename fix-<domain>_$(date +%m%d)` for Wave 2
3. **Verify dispatch** — sleep 5s, check for tool activity
4. **Read reports before presenting** — don't summarize from memory
5. **Ask user before Wave 2** — never auto-fix without confirmation
6. **Condense, don't delete** — fewer tokens saying the same thing, not lost information
7. **Preserve hook-enforced behavior** — if a hook enforces a rule, agent defs can mention it briefly but don't need to explain it
8. **Bash 3.2 violations are always HIGH severity** — they break on macOS
