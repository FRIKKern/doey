#!/usr/bin/env bash
# test-polling-loop-detection.sh — repro test for task #525 wake-loop detector
#
# STATUS: SKELETON (task #539).
#
# This harness exists so that when task #536 (detector + circuit breaker in
# common.sh) lands, the implementing worker can fill in the assertions
# without having to re-derive the stub-env strategy. Until #536 merges the
# script short-circuits to exit 0 with a SKIP message.
#
# SCOPE WHEN ENABLED (will be implemented by #536):
#   - Source .claude/hooks/common.sh directly
#   - Call violation_bump_counter() in a controlled loop of 5 wakes
#   - Assert state-file transitions and stub-JSONL contents
#   - Exercise all three modes: on, shadow, off
#
# TEST-ONLY ENV (also documented in docs/violations.md §5.2):
#
#   DOEY_VIOLATION_STUB
#     When set, violation_bump_counter appends events as JSON lines to
#     this path INSTEAD of calling doey-ctl event log. Lets the test run
#     without a real doey-ctl binary or a seeded sqlite DB.
#
#   DOEY_SKIP_MSG_COUNT
#     When set, taskmaster-wait.sh / reviewer-wait.sh skip the
#     `doey msg count` call and take WAKE_REASON from $DOEY_TEST_WAKE_REASON.
#
#   DOEY_TEST_CLOCK
#     Unix seconds override for `now` inside violation_bump_counter.
#     Enables deterministic window-expiry assertions (120s rolling window).
#
# ACCEPTANCE CHECKLIST (for the #536 worker):
#   [ ] wake 1 → state file exists, consecutive_count=1
#   [ ] wake 3 → DOEY_VIOLATION_STUB has one line with "severity":"warn"
#   [ ] wake 5 → second line with "severity":"breaker"
#                AND state file has breaker_tripped=true
#                AND next_wake_earliest > now (DOEY_TEST_CLOCK + 30)
#   [ ] wake 6 → NO new stub line (latch holds)
#   [ ] touch sentinel + wake 7 → counter reset to 1, breaker_tripped=false
#   [ ] shadow-mode arm: warn+breaker events logged but next_wake_earliest=0
#                        and no nudge message queued
#   [ ] off-mode arm: 10 wakes → stub file empty

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# --- Detect whether task #536 has landed ----------------------------------
# The helper is violation_bump_counter in .claude/hooks/common.sh.
# If it's not defined, skip.
COMMON_SH="${PROJECT_ROOT}/.claude/hooks/common.sh"
if [ ! -f "$COMMON_SH" ] || ! grep -q 'violation_bump_counter' "$COMMON_SH" 2>/dev/null; then
    echo "SKIP: test-polling-loop-detection.sh — task #536 not yet landed"
    echo "      (no violation_bump_counter in $COMMON_SH)"
    echo "      This is expected on main until #536 merges."
    exit 0
fi

# --- Test environment setup (TEST-ONLY ENV) --------------------------------
TMPDIR_BASE="${TMPDIR:-/tmp}/doey-test-525-$$"
mkdir -p "$TMPDIR_BASE/runtime/status"
mkdir -p "$TMPDIR_BASE/session"

export DOEY_VIOLATION_STUB="$TMPDIR_BASE/violations-stub.jsonl"
export DOEY_SKIP_MSG_COUNT=1
export DOEY_TEST_CLOCK=1000000  # deterministic base timestamp
export RUNTIME_DIR="$TMPDIR_BASE/runtime"
export SESSION_NAME="test-525"
export PANE_SAFE="W9.0"
export DOEY_TEAM_WINDOW="W9"
export DOEY_ROLE_ID="subtaskmaster"

cleanup() {
    rm -rf "$TMPDIR_BASE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_fail_count=0
_assert() {
    local _desc="$1" _cond="$2"
    if eval "$_cond"; then
        echo "  OK  $_desc"
    else
        echo "  FAIL $_desc"
        _fail_count=$((_fail_count + 1))
    fi
}

# --- Source the helper (will exist once #536 lands) ------------------------
# shellcheck disable=SC1090
. "$COMMON_SH"

# ==========================================================================
# === ASSERTIONS BELOW ARE PLACEHOLDERS — #536 WORKER FILLS IN            ===
# ==========================================================================

echo "test-polling-loop-detection: on-mode arm"
# TODO (#536): loop 5 wakes, assert:
#   - wake 1: state file created, consecutive_count == 1
#   - wake 3: stub JSONL contains one "severity":"warn" row
#   - wake 5: stub JSONL contains a second "severity":"breaker" row
#            AND state file has breaker_tripped=true
#            AND next_wake_earliest == DOEY_TEST_CLOCK + 30
#   - wake 6: no new rows (latch holds)
#   - touch ${RUNTIME_DIR}/status/${PANE_SAFE}.tool_used_this_turn
#     wake 7: state file reset (consecutive_count=1, breaker_tripped=false)

echo "test-polling-loop-detection: shadow-mode arm"
# TODO (#536): repeat with DOEY_ENFORCE_VIOLATIONS=shadow
#   - warn + breaker events emitted
#   - next_wake_earliest == 0 (no backoff)
#   - breaker_tripped MAY remain false (shadow is side-effect-free)
#   - no nudge message queued

echo "test-polling-loop-detection: off-mode arm"
# TODO (#536): DOEY_ENFORCE_VIOLATIONS=off
#   - 10 wakes in a row
#   - stub JSONL file empty
#   - state file not created

echo "test-polling-loop-detection: window-expiry arm"
# TODO (#536): bump clock past DOEY_TEST_CLOCK + 120 between wakes
#   - counter resets to 1 on first wake past the 120s window

# --- End of placeholders ---------------------------------------------------

if [ "$_fail_count" -gt 0 ]; then
    echo ""
    echo "=== test-polling-loop-detection: ${_fail_count} assertion(s) failed ==="
    exit 1
fi

echo ""
echo "=== test-polling-loop-detection: skeleton checks passed ==="
echo "NOTE: assertions are placeholders pending task #536 implementation."
exit 0
