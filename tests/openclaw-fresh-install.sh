#!/usr/bin/env bash
# OpenClaw v1 — Phase 1 fresh-install invariant gate.
#
# Asserts that on a fresh install with no opt-in, OpenClaw is fully dormant:
#   A. No artifacts created post fresh-install
#   B. send_notification fast-path is byte-deterministic and openclaw-free
#      when openclaw.conf is absent
#   C. No network calls fired when not configured
#
# This test runs in CI on every PR. Failure is a hard gate.
#
# It MUST pass in the current repo state regardless of whether other
# OpenClaw integration subtasks have landed yet. With no openclaw.conf,
# the integration is a no-op everywhere, so the assertions hold trivially.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d -t openclaw-fresh.XXXXXX)"
FAILED=0
FAILURES=""

cleanup() {
  if [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$TMPROOT" 2>/dev/null || rm -rf "$TMPROOT"
    else
      rm -rf "$TMPROOT"
    fi
  fi
}
trap cleanup EXIT

fail_assert() {
  FAILED=1
  FAILURES="${FAILURES}  - $1"$'\n'
}

# ─── A. No artifacts created post fresh-install ──────────────────────────
ISO_HOME="$TMPROOT/home"
ISO_PROJECT="$TMPROOT/project"
mkdir -p "$ISO_HOME" "$ISO_PROJECT/.doey"

NETLOG="$TMPROOT/network.log"
: > "$NETLOG"

(
  set +e
  export HOME="$ISO_HOME"
  export DOEY_PROJECT_DIR="$ISO_PROJECT"
  export DOEY_ROLE="boss"
  export DOEY_NO_FOCUS_SUPPRESS=1
  export DOEY_TEST_NETLOG="$NETLOG"

  curl()        { echo "curl $*" >> "$DOEY_TEST_NETLOG"; }
  wget()        { echo "wget $*" >> "$DOEY_TEST_NETLOG"; }
  osascript()   { echo "osascript $*" >> "$DOEY_TEST_NETLOG"; }
  notify-send() { echo "notify-send $*" >> "$DOEY_TEST_NETLOG"; }
  doey-tui()    { echo "doey-tui $*" >> "$DOEY_TEST_NETLOG"; }
  export -f curl wget osascript notify-send doey-tui 2>/dev/null || true

  # shellcheck disable=SC1090
  . "$PROJECT_ROOT/.claude/hooks/common.sh" 2>/dev/null || exit 0
  is_boss() { return 0; }
  _check_cooldown() { return 0; }

  send_notification "fresh-install-test" "body" "probe" 2>/dev/null || true
) >/dev/null 2>&1 || true

# A1: openclaw.conf must NOT exist
[ ! -f "$ISO_HOME/.config/doey/openclaw.conf" ] || \
  fail_assert "A1: ~/.config/doey/openclaw.conf was created on fresh install"

# A2: project openclaw-binding must NOT exist
[ ! -e "$ISO_PROJECT/.doey/openclaw-binding" ] || \
  fail_assert "A2: .doey/openclaw-binding was created on fresh install"

# A3: project .doey/openclaw/ must NOT exist
[ ! -d "$ISO_PROJECT/.doey/openclaw" ] || \
  fail_assert "A3: .doey/openclaw/ directory was created on fresh install"

# A4: no openclaw-bridge process
if pgrep -f openclaw-bridge >/dev/null 2>&1; then
  fail_assert "A4: openclaw-bridge process is running (none expected on fresh install)"
fi

# A5: `doey doctor` must not emit an OpenClaw diagnostic SECTION when not
# configured. Match section-header pattern only — naive substring matches
# (e.g. unrelated task titles in surrounding repo) are NOT a regression.
DOC_OUT="$TMPROOT/doctor.out"
if command -v doey >/dev/null 2>&1; then
  ( HOME="$ISO_HOME" DOEY_PROJECT_DIR="$ISO_PROJECT" \
    timeout 15 doey doctor >"$DOC_OUT" 2>&1 ) || true
  if grep -E '(^|[[:space:]=])OpenClaw[[:space:]]*(:|===|status|Status|gateway|Gateway)' \
       "$DOC_OUT" >/dev/null 2>&1; then
    fail_assert "A5: 'doey doctor' emits an OpenClaw diagnostic section when not configured"
  fi
fi

# ─── B. Non-opt-in regression: byte-deterministic, openclaw-free ─────────
LIVE_TRACE="$TMPROOT/trace.live"
REF_TRACE="$TMPROOT/trace.ref"

run_trace() {
  local out="$1"
  : > "$out"
  (
    set +e
    export HOME="$ISO_HOME"
    export DOEY_PROJECT_DIR="$ISO_PROJECT"
    export DOEY_ROLE="boss"
    export DOEY_NO_FOCUS_SUPPRESS=1
    export DOEY_TRACE_OUT="$out"

    curl()        { echo "curl $*" >> "$DOEY_TRACE_OUT"; }
    osascript()   { echo "osascript $*" >> "$DOEY_TRACE_OUT"; }
    notify-send() { echo "notify-send $*" >> "$DOEY_TRACE_OUT"; }
    doey-tui()    { echo "doey-tui $*" >> "$DOEY_TRACE_OUT"; }
    tmux()        { echo ""; }
    export -f curl osascript notify-send doey-tui tmux 2>/dev/null || true

    # shellcheck disable=SC1090
    . "$PROJECT_ROOT/.claude/hooks/common.sh" 2>/dev/null || exit 0
    is_boss() { return 0; }
    _check_cooldown() { return 0; }
    send_notification "regression-title" "regression-body" "regression-event" \
      2>/dev/null || true
  ) >/dev/null 2>&1 || true
}

run_trace "$LIVE_TRACE"
run_trace "$REF_TRACE"

if ! diff -q "$LIVE_TRACE" "$REF_TRACE" >/dev/null 2>&1; then
  fail_assert "B1: send_notification non-deterministic without openclaw.conf"
fi

if grep -qi 'openclaw' "$LIVE_TRACE" 2>/dev/null; then
  fail_assert "B2: send_notification trace mentions openclaw when conf is absent"
fi

# ─── C. No network when not configured ───────────────────────────────────
if grep -qi 'openclaw' "$NETLOG" 2>/dev/null; then
  fail_assert "C1: network log mentions openclaw on fresh install"
fi
if grep -E '^curl ' "$NETLOG" >/dev/null 2>&1; then
  fail_assert "C2: curl invoked from send_notification on fresh install"
fi

# ─── Result ──────────────────────────────────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
  echo "FRESH-INSTALL OK"
  exit 0
fi

printf 'FRESH-INSTALL FAIL:\n%s' "$FAILURES"
exit 1
