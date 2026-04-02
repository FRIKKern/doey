# Task #59: Boss & Taskmaster Role Identity Regression

**Date:** 2026-03-31
**Status:** Investigation complete

## Summary

The Boss pane (0.1) has wrong tmux pane names, does implementation work itself, and does not delegate to SM. Root cause: `on-pre-tool-use.sh` gives Boss **unrestricted tool access** (no hook enforcement for source code tools), and the `claude` launch command lacks `--name`, allowing Claude Code to overwrite pane titles.

---

## File-by-File Analysis

### 1. Agent Definitions

**`agents/doey-boss.md`** — Role description and behavioral rules are clear and correct. Boss is defined as a relay/PM that never touches code. However, the tool restriction section reveals the gap:

```
**Hook-enforced (will error if violated):**
- tmux send-keys to ANY pane except Taskmaster (0.2) — BLOCKED.

**Agent-level rules (critical policy — violating wastes irreplaceable context):**
- Read, Edit, Write, Glob, Grep on project source files — FORBIDDEN.
- Agent tool — FORBIDDEN.
- Direct dispatch to teams or workers — FORBIDDEN.
```

The source code and Agent tool blocks are classified as **agent-level** (voluntary compliance), NOT hook-enforced. The Boss model may violate them when the task seems simple enough to do directly.

**`agents/doey-taskmaster.md`** — Correct. SM role is clearly defined as autonomous coordinator. Tool restrictions are also agent-level for source code tools, but SM has additional hook enforcement (AskUserQuestion blocked, `/rename` via send-keys blocked).

### 2. `on-session-start.sh` — Role Assignment

**Role detection is CORRECT.** Lines 51-59:
- Window 0, pane 1 → `boss`
- Window 0, pane matching `TASKMASTER_PANE` (default 0.2) → `taskmaster`

**Runtime role files confirm correct assignment:**
- `/tmp/doey/doey/status/doey_doey_0_1.role` = `boss`
- `/tmp/doey/doey/status/doey_doey_0_2.role` = `taskmaster`

**Pane titles are set correctly** at session start (lines 156-163):
- Boss: `${FULL_PANE_ID} | ${PROJECT_NAME} Boss` (e.g., `d-boss | doey Boss`)
- SM: `${FULL_PANE_ID} | ${PROJECT_NAME} SM` (e.g., `d-sm | doey SM`)

**No issues found in this file.**

### 3. `on-pre-tool-use.sh` — THE ROOT CAUSE

**Lines 174-177 give Boss unrestricted access to ALL tools:**

```bash
if [ "$_DOEY_ROLE" = "boss" ]; then
  _dbg_write "allow_boss_unrestricted"
  exit 0
fi
```

When `_DOEY_ROLE` is `"boss"`, the hook exits with code 0 (allow) for EVERY tool except send-keys to non-SM panes (checked at lines 157-172). This means:

| Tool | Boss Access | Expected per CLAUDE.md |
|------|-------------|----------------------|
| Read/Grep on project source | **ALLOWED** | BLOCKED |
| Edit/Write on project source | **ALLOWED** | BLOCKED |
| Glob on project source | **ALLOWED** | BLOCKED |
| Agent | **ALLOWED** | BLOCKED |
| send-keys to non-SM | Blocked (line 169) | Blocked |
| send-keys to SM (0.2) | Allowed (line 164) | Allowed |

**Compare with Manager enforcement (lines 180-203):** Manager has proper hook blocks for Agent (line 183) and Read/Edit/Write/Glob/Grep on non-task/non-runtime paths (lines 187-203). Boss has NONE of these guards.

**The debug log tag `"allow_boss_unrestricted"` suggests this was intentional.** Someone decided Boss should have no tool restrictions beyond send-keys targeting. This directly contradicts CLAUDE.md's architecture table.

### 4. Pane Title Overwriting

**Current pane titles (from `tmux list-panes`):**
- 0.1: `"⠂ Doey project development session"`
- 0.2: `"✳ Monitor multi-team dynamic grid coordination"`

These are Claude Code's auto-generated task descriptions, NOT the titles set by `on-session-start.sh`. Two contributing factors:

**A. Missing `--name` flag on Boss/SM launch.**

`shell/doey.sh` line 600:
```bash
local _boss_cmd="claude --dangerously-skip-permissions --model ${DOEY_BOSS_MODEL:-$DOEY_TASKMASTER_MODEL} --agent doey-boss"
```

No `--name` flag. Compare with Worker/Manager launches which include `--name`:
- Manager (line 2504): `--name "T${tw} Subtaskmaster"`
- Worker (line 2548): `--name "${w_name}"`

Without `--name`, Claude Code generates its own name from the first prompt content.

**B. Claude Code may overwrite pane titles.** Even though `on-session-start.sh` sets titles correctly, Claude Code's internal mechanisms (statusline, `/rename`, task description display) can overwrite the tmux pane title set by the hook. The `on-session-start.sh` hook runs once at startup; subsequent Claude Code behavior can change the title.

### 5. Environment Variables

**Correct.** `on-session-start.sh` writes the right DOEY_ROLE, DOEY_PANE_INDEX, DOEY_WINDOW_INDEX to `CLAUDE_ENV_FILE` (lines 122-138). The Boss briefing at line 1618 also explicitly says "You are Boss."

### 6. System Prompt Injection

**No Boss or SM system prompt files exist.** Worker system prompts are generated per-pane (`worker-system-prompt-w*.md`), but Boss and SM rely entirely on their agent definitions (`--agent doey-boss`, `--agent doey-taskmaster`). This is fine — the agent files ARE the system prompts.

### 7. Defense-in-Depth Role Inference

`on-pre-tool-use.sh` lines 124-143 correctly fall back to positional role detection if the `.role` file is missing. Window 0, pane 1 → boss. This is working correctly.

---

## CLAUDE.md Discrepancy

CLAUDE.md states:
```
| Boss | Read/Edit/Write/Glob/Grep on project source; send-keys; Agent; implementation work (send-keys allowed) |
```

This implies ALL of these are hook-enforced. In reality, only `send-keys` targeting is hook-enforced. The rest depend on the Boss model voluntarily following its agent definition — which it doesn't always do.

---

## Root Cause

**The Boss has no hook-enforced tool restrictions for source code access.** `on-pre-tool-use.sh` line 174-177 exits with `allow` for every tool when the role is boss (except non-SM send-keys). The agent definition asks Boss to voluntarily avoid source code tools, but this is a soft guideline that the model violates when:

1. The task seems simple enough to handle directly
2. Context pressure makes delegation seem like overhead
3. Post-compact, the model loses track of its role boundaries

This is compounded by the pane title issue: when the Boss's tmux pane shows a generic task description instead of "Boss", it weakens the role identity signal after compaction.

---

## Recommended Fixes

### Fix 1: Add Boss tool restrictions to `on-pre-tool-use.sh` (CRITICAL)

Replace lines 174-177 with Boss-specific restrictions mirroring the Manager pattern. Block Agent, Read/Edit/Write/Glob/Grep on non-task/non-runtime paths:

**File:** `.claude/hooks/on-pre-tool-use.sh`
**Lines:** 174-177

Replace:
```bash
if [ "$_DOEY_ROLE" = "boss" ]; then
  _dbg_write "allow_boss_unrestricted"
  exit 0
fi
```

With Boss restrictions that:
1. Block `Agent` tool entirely
2. Block `Read/Edit/Write/Glob/Grep` unless the path is inside `.doey/tasks/` or `$RUNTIME_DIR/`
3. Allow `Bash` (already has send-keys guard above)
4. Allow all other tools (AskUserQuestion, etc.)

Model the implementation on the existing Manager restrictions at lines 180-203.

### Fix 2: Add `--name` to Boss and SM launch commands

**File:** `shell/doey.sh`
**Line 600:** Add `--name "Boss"`:
```bash
local _boss_cmd="claude --dangerously-skip-permissions --model ${DOEY_BOSS_MODEL:-$DOEY_TASKMASTER_MODEL} --name \"Boss\" --agent doey-boss"
```

**Line 605:** Add `--name "Taskmaster"`:
```bash
local _sm_cmd="claude --dangerously-skip-permissions --model $DOEY_TASKMASTER_MODEL --name \"Taskmaster\" --agent doey-taskmaster"
```

### Fix 3: Update CLAUDE.md tool restrictions table

Clarify which restrictions are hook-enforced vs agent-level, or update the table after Fix 1 to reflect that all listed restrictions are now hook-enforced.

### Fix 4: Update Boss agent definition

After Fix 1, move `Read/Edit/Write/Glob/Grep` and `Agent` from the "Agent-level rules" section to the "Hook-enforced" section in `agents/doey-boss.md`.

---

## Priority

- Fix 1 is **critical** — this is the root cause of Boss doing implementation work
- Fix 2 is **high** — prevents pane title confusion that weakens role identity
- Fixes 3-4 are **medium** — documentation consistency
