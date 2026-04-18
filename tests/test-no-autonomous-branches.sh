#!/usr/bin/env bash
# Regression test: on-pre-tool-use.sh must block autonomous branch/worktree
# creation, including the Agent tool's isolation:"worktree" parameter.
# Task 603.
set -euo pipefail

HOOK="/home/doey/doey/.claude/hooks/on-pre-tool-use.sh"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK" >&2; exit 1; }

# Stub emit_lifecycle_event (defined in common.sh, not sourced by the hook in
# standalone invocations — without this stub _log_block errors with 127).
STUB=$(mktemp)
trap 'rm -f "$STUB"' EXIT
printf 'emit_lifecycle_event() { :; }\n' > "$STUB"
export BASH_ENV="$STUB"

# Ensure the hook believes it is NOT in a linked worktree.
unset DOEY_WORKTREE || true

PASS=0
FAIL=0

run_case() {
  local desc="$1" expected="$2" payload="$3" allow_agent_wt="${4:-}"
  local actual=0
  if [ -n "$allow_agent_wt" ]; then
    printf '%s' "$payload" | DOEY_ALLOW_AGENT_WORKTREE=1 bash "$HOOK" >/dev/null 2>&1 || actual=$?
  else
    printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1 || actual=$?
  fi
  if [ "$actual" = "$expected" ]; then
    echo "PASS [$actual] $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL [expected=$expected actual=$actual] $desc"
    FAIL=$((FAIL + 1))
  fi
}

# ── BLOCKED (exit 2) — autonomous branch/worktree creation ──────────────
run_case "git checkout -b x" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -b x"}}'

run_case "git switch -c x" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"git switch -c x"}}'

run_case "git branch newthing" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"git branch newthing"}}'

run_case "git worktree add ../wt -b x" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"git worktree add ../wt -b x"}}'

run_case "Agent isolation:worktree (no escape hatch)" 2 \
  '{"tool_name":"Agent","tool_input":{"isolation":"worktree","description":"d","prompt":"p"}}'

# ── ALLOWED (exit 0) — safe/read-only ops and sanctioned paths ──────────
run_case "git checkout -- file" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -- file"}}'

run_case "git branch --list" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git branch --list"}}'

run_case "git branch --show-current" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git branch --show-current"}}'

run_case "Agent isolation:worktree (DOEY_ALLOW_AGENT_WORKTREE=1)" 0 \
  '{"tool_name":"Agent","tool_input":{"isolation":"worktree","description":"d","prompt":"p"}}' \
  1

echo
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
