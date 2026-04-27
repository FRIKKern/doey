#!/usr/bin/env bash
# Regression test: on-pre-tool-use.sh blocks worktree/branch creation by default
# for non-Boss/Taskmaster roles, and allows it when DOEY_WORKTREE_OPT_IN=1 is set.
# Task 649 — "Worktrees + branches are forbidden by default".
set -euo pipefail

HOOK="/home/doey/doey/.claude/hooks/on-pre-tool-use.sh"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK" >&2; exit 1; }

# Stub emit_lifecycle_event (defined in common.sh, not sourced when the hook
# runs standalone — without this stub _log_block errors with 127).
STUB=$(mktemp)
TMPREPO=$(mktemp -d)
cleanup() {
  rm -f "$STUB"
  if command -v trash >/dev/null 2>&1; then
    trash "$TMPREPO" 2>/dev/null || rm -rf "$TMPREPO"
  else
    rm -rf "$TMPREPO"
  fi
}
trap cleanup EXIT
printf 'emit_lifecycle_event() { :; }\n' > "$STUB"
export BASH_ENV="$STUB"

# Fresh repo so the hook's git rev-parse calls don't see the parent Doey repo.
(
  cd "$TMPREPO"
  git init -q
  git config user.email test@example.com
  git config user.name test
  : > seed
  git add seed
  git -c commit.gpgsign=false commit -q -m init
)

# The hook detects "linked worktree" via DOEY_WORKTREE env var or by comparing
# git-dir vs git-common-dir. By unsetting DOEY_WORKTREE and running from a
# regular repo, _in_worktree=false → guards activate.
unset DOEY_WORKTREE || true
# Force the role to a non-Boss/Taskmaster identity so guards apply.
export DOEY_ROLE=worker
# Ensure we are NOT in a tmux pane (avoids role lookup via runtime files).
unset TMUX_PANE || true

PASS=0
FAIL=0

run_case() {
  local desc="$1" expected="$2" payload="$3" opt_in="${4:-}"
  local actual=0
  if [ -n "$opt_in" ]; then
    (cd "$TMPREPO" && printf '%s' "$payload" \
      | DOEY_WORKTREE_OPT_IN=1 bash "$HOOK" >/dev/null 2>&1) || actual=$?
  else
    (cd "$TMPREPO" && printf '%s' "$payload" \
      | bash "$HOOK" >/dev/null 2>&1) || actual=$?
  fi
  if [ "$actual" = "$expected" ]; then
    echo "PASS [$actual] $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL [expected=$expected actual=$actual] $desc"
    FAIL=$((FAIL + 1))
  fi
}

# ── BLOCKED (exit 2) without DOEY_WORKTREE_OPT_IN ───────────────────────
run_case "git worktree add ../foo (no opt-in)" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"git worktree add ../foo"}}'

run_case "git checkout -b feat/x (no opt-in)" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -b feat/x"}}'

run_case "git switch -c feat/x (no opt-in)" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"git switch -c feat/x"}}'

run_case "git branch -D foo (no opt-in)" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"git branch -D foo"}}'

# ── ALLOWED (exit 0) — read-only branch operations ──────────────────────
run_case "git branch (no args, list)" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git branch"}}'

run_case "git branch --list" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git branch --list"}}'

# ── ALLOWED (exit 0) — opt-in escape hatch ──────────────────────────────
run_case "git worktree add ../foo (DOEY_WORKTREE_OPT_IN=1)" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"git worktree add ../foo"}}' \
  1

echo
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
