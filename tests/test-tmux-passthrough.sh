#!/usr/bin/env bash
# test-tmux-passthrough.sh — assert doey-masterplan-tui renders cleanly
# under tmux without leaking raw escape-sequence text.
#
# Phase 9 of masterplan-20260426-203854. Bash 3.2 compatible.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"
SESSION="doey-passthru-test-$$"
FIXTURE="consensus"

passed=0
failed=0

_pass() {
  printf '  ok    %s\n' "$1"
  passed=$((passed + 1))
}

_fail() {
  printf '  FAIL  %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then
    printf '         %s\n' "$2" >&2
  fi
  failed=$((failed + 1))
}

_skip() {
  printf '  skip  %s\n' "$1"
  exit 0
}

cleanup() {
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── prerequisites ────────────────────────────────────────────────────

if ! command -v tmux >/dev/null 2>&1; then
  _skip "tmux not available"
fi

binary=""
if command -v doey-masterplan-tui >/dev/null 2>&1; then
  binary="$(command -v doey-masterplan-tui)"
elif [ -x "$HOME/.local/bin/doey-masterplan-tui" ]; then
  binary="$HOME/.local/bin/doey-masterplan-tui"
fi

if [ -z "$binary" ]; then
  echo "  building doey-masterplan-tui"
  if ( cd "$REPO_DIR/tui" && go build -o "/tmp/doey-masterplan-tui-passthru" ./cmd/doey-masterplan-tui ) >/tmp/doey-passthru-build.log 2>&1; then
    binary="/tmp/doey-masterplan-tui-passthru"
  else
    _fail "build failed" "see /tmp/doey-passthru-build.log"
    exit 1
  fi
fi

fixture_dir="$REPO_DIR/tui/internal/planview/testdata/fixtures/$FIXTURE"
if [ ! -d "$fixture_dir" ]; then
  _fail "fixture missing: $fixture_dir"
  exit 1
fi

# ── spawn detached tmux session running the TUI in --demo mode ───────

# Make sure no stale session lingers from a prior run.
tmux kill-session -t "$SESSION" 2>/dev/null || true

if ! tmux new-session -d -s "$SESSION" -x 200 -y 50 "$binary --demo $FIXTURE"; then
  _fail "tmux new-session failed"
  exit 1
fi
_pass "tmux session spawned: $SESSION"

# Give the TUI a moment to draw its first frame. Sleep is permissible
# in test scripts (only forbidden inside the live Subtaskmaster loop).
sleep 1

# ── capture and inspect ──────────────────────────────────────────────

capture="$(tmux capture-pane -t "$SESSION" -p 2>/dev/null || true)"

if [ -z "$capture" ]; then
  _fail "captured pane is empty"
else
  _pass "captured pane is non-empty"
fi

# Look for at least one expected fixture marker so we know the binary
# is actually rendering something, not just clearing the screen.
if printf '%s' "$capture" | grep -qiE 'consensus|phase|architect|critic|reviewer|masterplan'; then
  _pass "captured pane contains plan content"
else
  _fail "captured pane has no plan-related markers" "first 200 chars: $(printf '%s' "$capture" | head -c 200)"
fi

# Raw escape sequence leak: tmux capture-pane -p strips ANSI by default,
# so the *text* should never contain literal "ESC[" sequences. Look for
# the escape character itself (0x1b) and the literal "\x1b[" / "^[[" /
# "\033[" forms that would indicate a passthrough failure.
if printf '%s' "$capture" | grep -qE $'\x1b\\['; then
  _fail "raw ESC[ sequence leaked into captured text"
else
  _pass "no raw ESC[ sequence in captured text"
fi
if printf '%s' "$capture" | grep -qE '\\x1b\[|\\033\[|\^\[\['; then
  _fail "literal escape-sequence string leaked into captured text"
else
  _pass "no literal escape-sequence text in captured pane"
fi

echo
if [ "$failed" -gt 0 ]; then
  printf 'FAIL: %d failed, %d passed\n' "$failed" "$passed" >&2
  exit 1
fi
printf 'PASS: %d checks passed\n' "$passed"
