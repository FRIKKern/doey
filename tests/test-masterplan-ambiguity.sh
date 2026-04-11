#!/usr/bin/env bash
# test-masterplan-ambiguity.sh — Unit tests for masterplan_ambiguity_score.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${PROJECT_ROOT}/shell/doey-masterplan-ambiguity.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: helper not found at $HELPER" >&2
  exit 1
fi

# shellcheck source=../shell/doey-masterplan-ambiguity.sh
. "$HELPER"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS  %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n        expected=%q actual=%q\n' "$label" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}

run() {
  local label="$1" expected="$2" goal="$3"
  local got
  got=$(masterplan_ambiguity_score "$goal")
  assert_eq "$label" "$expected" "$got"
}

printf '== masterplan_ambiguity_score ==\n'

# 1. Vague short prompt
run 'vague short prompt' \
    'AMBIGUOUS' \
    'fix it'

# 2. Prompt containing a file path but too short (has_path but <30 words)
run 'short prompt with file path' \
    'AMBIGUOUS' \
    'update tui/internal/foo.go'

# 3. Prompt with technical terms but no path and short
run 'technical terms short' \
    'AMBIGUOUS' \
    'compilation goroutine deadlock race condition'

# 4. Long prompt (>=30 words) WITH a file path -> CLEAR
run 'long detailed with file path' \
    'CLEAR' \
    'Refactor the masterplan spawn helper in shell/doey-masterplan-spawn.sh so that the consensus gate is enforced before any handoff to the Taskmaster and the Planner always receives both the brief file path and the goal file path on stdin without any manual steps or user-facing prompts at all please ensure the refactor covers edge cases too'

# 5. Long prompt (>=30 words) WITHOUT a file path -> AMBIGUOUS
run 'long detailed no file path' \
    'AMBIGUOUS' \
    'We want to rethink how the planning team coordinates with the interview team so that the brief is automatically propagated to the planner without requiring the user to manually copy anything between directories or sessions because this is currently a major source of friction for everyone involved'

# 6. Very long prompt (>200 chars) with path -> CLEAR
LONG_PROMPT='Please update the doey masterplan skill flow in .claude/skills/doey-masterplan/SKILL.md.tmpl so that after the interview completes the brief is copied to the masterplan plans directory and the spawn helper is invoked automatically and idempotently without requiring any user interaction whatsoever at all.'
run 'very long with path' \
    'CLEAR' \
    "$LONG_PROMPT"

# 7. Edge: empty string
run 'empty string' \
    'AMBIGUOUS' \
    ''

# 8. Edge: single word
run 'single word' \
    'AMBIGUOUS' \
    'refactor'

# 9. Edge: whitespace only
run 'whitespace only' \
    'AMBIGUOUS' \
    '     '

# 10. Path-like token but minimal words
run 'tabs and path short' \
    'AMBIGUOUS' \
    'fix shell/doey.sh'

# 11. Debug function sanity
debug_out=$(masterplan_ambiguity_debug 'fix it')
case "$debug_out" in
  'AMBIGUOUS words=2 has_path=0') assert_eq 'debug function format' 'ok' 'ok' ;;
  *)                               assert_eq 'debug function format' 'AMBIGUOUS words=2 has_path=0' "$debug_out" ;;
esac

printf '\n== summary ==\n  %d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
