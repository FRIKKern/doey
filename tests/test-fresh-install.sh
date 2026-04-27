#!/usr/bin/env bash
# test-fresh-install.sh — fresh-install validation for Phase 9 (masterplan-20260426-203854).
#
# Asserts:
#   1. install.sh parses and exits 0 (bash -n).
#   2. shell/doey-doctor.sh parses and (best-effort) runs.
#   3. doey-masterplan-tui binary builds (or already present) and accepts --help.
#
# Default mode is non-destructive: it does NOT actually run `doey uninstall`
# nor reinstall over the live system. Set
# DOEY_FRESH_INSTALL_TEST_DESTRUCTIVE=1 to opt into the full uninstall+reinstall
# sweep (intended for clean CI runners only — this WILL move ~/.local/bin
# entries on a developer machine).
#
# Bash 3.2 compatible. set -euo pipefail.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

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
}

destructive="${DOEY_FRESH_INSTALL_TEST_DESTRUCTIVE:-0}"

echo "fresh-install validation (destructive=$destructive)"
echo "  repo: $REPO_DIR"

# ── 1: install.sh syntax ─────────────────────────────────────────────

if [ -f "$REPO_DIR/install.sh" ]; then
  if bash -n "$REPO_DIR/install.sh"; then
    _pass "install.sh parses cleanly"
  else
    _fail "install.sh has syntax errors"
  fi
else
  _fail "install.sh missing at $REPO_DIR/install.sh"
fi

# ── 2: doey-doctor.sh syntax + doctor run ────────────────────────────

if [ -f "$REPO_DIR/shell/doey-doctor.sh" ]; then
  if bash -n "$REPO_DIR/shell/doey-doctor.sh"; then
    _pass "shell/doey-doctor.sh parses cleanly"
  else
    _fail "shell/doey-doctor.sh has syntax errors"
  fi
else
  _fail "shell/doey-doctor.sh missing"
fi

if [ "$destructive" = "1" ]; then
  echo "  destructive mode: running doey uninstall + bash install.sh"
  if command -v doey >/dev/null 2>&1; then
    if doey uninstall </dev/null >/tmp/doey-fresh-uninstall.log 2>&1; then
      _pass "doey uninstall completed"
    else
      _fail "doey uninstall failed" "see /tmp/doey-fresh-uninstall.log"
    fi
  else
    _skip "doey not on PATH; skipping uninstall step"
  fi
  if bash "$REPO_DIR/install.sh" </dev/null >/tmp/doey-fresh-install.log 2>&1; then
    _pass "bash install.sh succeeded"
  else
    _fail "bash install.sh failed" "see /tmp/doey-fresh-install.log"
  fi
  if bash "$REPO_DIR/shell/doey-doctor.sh" >/tmp/doey-fresh-doctor.log 2>&1; then
    _pass "doey doctor exits 0"
  else
    _fail "doey doctor failed" "see /tmp/doey-fresh-doctor.log"
  fi
else
  _skip "destructive uninstall+install (set DOEY_FRESH_INSTALL_TEST_DESTRUCTIVE=1 to enable)"
fi

# ── 3: doey-masterplan-tui boot check ────────────────────────────────

binary=""
if command -v doey-masterplan-tui >/dev/null 2>&1; then
  binary="$(command -v doey-masterplan-tui)"
elif [ -x "$HOME/.local/bin/doey-masterplan-tui" ]; then
  binary="$HOME/.local/bin/doey-masterplan-tui"
fi

if [ -z "$binary" ]; then
  echo "  building doey-masterplan-tui (binary not on PATH)"
  if ( cd "$REPO_DIR/tui" && go build -o "/tmp/doey-masterplan-tui-fresh" ./cmd/doey-masterplan-tui ) >/tmp/doey-fresh-build.log 2>&1; then
    binary="/tmp/doey-masterplan-tui-fresh"
    _pass "doey-masterplan-tui builds"
  else
    _fail "doey-masterplan-tui failed to build" "see /tmp/doey-fresh-build.log"
  fi
else
  _pass "doey-masterplan-tui present: $binary"
fi

if [ -n "$binary" ] && [ -x "$binary" ]; then
  # --help triggers Go's flag.Parse usage path which exits 0 (or 2 on Go's
  # default ErrHelp). We accept either as long as the binary doesn't panic.
  out_file="$(mktemp -t doey-fresh-help.XXXXXX 2>/dev/null || mktemp)"
  rc=0
  "$binary" --help >"$out_file" 2>&1 || rc=$?
  if grep -qiE 'panic:|runtime error:' "$out_file"; then
    _fail "doey-masterplan-tui --help panicked" "see $out_file"
  else
    _pass "doey-masterplan-tui --help boots without panic (rc=$rc)"
  fi
  rm -f "$out_file"
fi

echo
if [ "$failed" -gt 0 ]; then
  printf 'FAIL: %d failed, %d passed\n' "$failed" "$passed" >&2
  exit 1
fi
printf 'PASS: %d checks passed\n' "$passed"
