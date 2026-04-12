# Enforce AskUserQuestion

Stop hook that ensures Boss and Planner roles use the `AskUserQuestion` tool instead of embedding questions as inline text. Violations are logged to a per-project JSONL file.

## Overview

When Boss or Planner stops, the hook inspects the last assistant message in the Claude transcript. If the response ends with an inline question (detected via heuristic) instead of calling `AskUserQuestion`, the hook logs a violation. In block mode it also rejects the turn with exit 2, forcing a retry.

**Why this exists:** Inline text questions are invisible to the Doey coordination layer. `AskUserQuestion` is a tool call that hooks and the TUI can observe, route, and act on. Enforcing it keeps the user-facing question flow structured and machine-readable.

**Scope:** Boss (pane `*.1` in window 0) and Planner (team_role=planner on manager pane `*.0`). Interviewer is explicitly out-of-scope — it has its own allow-clause in `on-pre-tool-use.sh`. Workers and Subtaskmasters are never checked.

## Enforcement Modes

Controlled by `DOEY_ENFORCE_QUESTIONS` environment variable (set in session env or config):

| Mode | Env value | Behavior | Exit code |
|------|-----------|----------|-----------|
| Shadow | `shadow` (default) | Log violation, allow turn to complete | 0 |
| Block | `block` | Log violation, reject turn with feedback | 2 |
| Off | `off` | No-op, skip all checks | 0 |

Shadow is the zero-config default — no setup required after fresh install. The hook fail-opens on any error (ERR trap exits 0).

## Detection Heuristic

The hook applies a three-step check to the last assistant message in the transcript:

### 1. AskUserQuestion short-circuit

If the last assistant message contains a `tool_use` block with `name: "AskUserQuestion"`, the turn is **compliant**. Exit 0 immediately, clear any retry counter.

### 2. Condition A — trailing question mark

The last non-empty line of the final text block ends with `?` or fullwidth `？` (byte-safe match via `LC_ALL=C`). Trailing whitespace is ignored.

### 3. Condition B — intent prefix

After lowercasing and stripping trailing `?`/`？`, the line matches one of:

**Long-form prefixes** (line starts with): `should i`, `do you`, `would you`, `which`, `can you`, `can i`, `want me to`, `or`

**Short-form exact matches:** `ready`, `proceed`, `confirm`, `sound good`, `ok`, `yes or no`

### Violation

A violation fires only when **both** Condition A **and** Condition B are true. A question mark alone is not enough — the line must also match a known intent prefix. This reduces false positives on rhetorical questions or inline explanations.

### Known false negatives

- Questions phrased without a standard prefix (e.g., "Any preference on the approach?")
- Questions split across multiple lines where the last line lacks a `?`
- Questions inside tool_result or system blocks (only assistant text is checked)

## Violations Log

Violations are appended as JSONL to:

```
$PROJECT/.doey/violations/ask-user-question.jsonl
```

Each line is a JSON object:

| Field | Description |
|-------|-------------|
| `ts` | UTC timestamp (`2026-04-12T14:30:00Z`) |
| `role` | `boss` or `planner` |
| `session` | Session ID from transcript |
| `pane` | Pane identifier (e.g., `doey_proj_0_1`) |
| `excerpt` | Sanitized snippet of the violating line |
| `tier` | Always `1` (reserved for future severity tiers) |
| `mode` | `shadow`, `block`, or `warn` (downgraded block after retry cap) |

Read violations with:

```bash
cat .doey/violations/ask-user-question.jsonl | jq .
# Or filter by role:
jq 'select(.role=="boss")' .doey/violations/ask-user-question.jsonl
```

**Dependency:** `jq >= 1.6` for reading violations. The hook itself does not require jq for writing — it uses printf. jq is only needed for the read/query side.

## Block-Flip Procedure

To switch from shadow to block mode:

1. Set the env var in your project config (`.doey/config.sh`):
   ```bash
   export DOEY_ENFORCE_QUESTIONS=block
   ```
   Or set it in the session env for a single session.

2. Restart workers so the env propagates (`doey reload --workers`).

When blocked, the hook:
- Logs the violation with `mode: "block"`
- Prints a `BLOCKED:` reason to stderr describing the violation and suggesting `AskUserQuestion`
- Outputs a JSON `{"decision":"block","reason":"..."}` to stdout
- Exits with code 2, which tells Claude Code to retry the turn

The blocked Claude instance sees the feedback and should retry using `AskUserQuestion` with structured options.

## Retry-Cap Semantics

The retry counter tracks **consecutive user turns** with violations — not Claude Code retries within a single turn. This distinction matters:

- **Increment:** Each time the hook fires in block mode and detects a violation, the counter increments
- **Reset:** The counter resets to 0 on any compliant turn (AskUserQuestion used, or no violation detected)
- **Cap at 3:** On the 3rd consecutive violation, the hook downgrades from block to warn — logs with `mode: "warn"`, clears the counter, and exits 0

This prevents infinite retry loops. After the cap, the turn passes through and the next turn starts fresh.

Counter state is stored at `${RUNTIME_DIR}/status/enforce-retry-${PANE_SAFE}.count`.

**Unknown at flip time:** Claude Code's exact retry behavior when a stop hook returns exit 2 is not fully documented. The retry cap is a safety valve — if Claude Code retries more aggressively than expected, the cap prevents a stuck loop.

## Smoke Test

Manual verification after changes to the hook:

1. Start a doey session in any project
2. Confirm shadow mode is active (default):
   ```bash
   echo $DOEY_ENFORCE_QUESTIONS   # should be empty or "shadow"
   ```
3. In Boss pane (0.1), trigger a plain-text question response (e.g., prompt Boss to ask "Should I proceed?")
4. Check the violations log:
   ```bash
   cat .doey/violations/ask-user-question.jsonl | jq .
   ```
   Should show a `mode: "shadow"` entry
5. Verify Boss was NOT blocked (turn completed normally)
6. Run the automated test suite:
   ```bash
   bash tests/test-enforce-ask-user-question.sh
   ```
   All 11 cases (A-K) should pass

## Rollout Plan

1. **Shadow-only (current):** Default mode for all sessions. Monitor violations log across 3+ sessions to measure false-positive rate
2. **Review:** Analyze collected violations — confirm detection accuracy, check for false positives from rhetorical questions or status updates
3. **Block flip (follow-up task):** Gated on satisfactory false-positive review. Switch default to `block` in config, with `off` escape hatch documented
4. **Interviewer consideration:** Currently out-of-scope. If interview flows generate false positives in Planner mode, add an Interviewer exemption

## Fresh-install gate (isolated environment only)

To verify zero-config shadow-mode default after a clean install, run in an ISOLATED environment — never on a working dev machine.

**Isolated worktree + HOME override:**
```bash
git worktree add /tmp/doey-fresh-install-test main
cd /tmp/doey-fresh-install-test
HOME=/tmp/doey-fresh-home ./install.sh
HOME=/tmp/doey-fresh-home doey   # in a throwaway project dir
# Send a plain-text question from Boss (pane 0.1)
# Verify: ls $PROJECT/.doey/violations/ask-user-question.jsonl
```

**Forbidden** (will wipe your dev state):
```bash
rm -rf ~/.config/doey ~/.local/bin/doey ~/.claude/agents/doey-*   # DO NOT RUN
```

## Per-project gitignore guidance

Violations live at `$PROJECT/.doey/violations/ask-user-question.jsonl` per project. If you don't want them committed, add `.doey/violations/` to your project's own `.gitignore`. Do not modify Doey's own `.gitignore` — it is a different repo.
