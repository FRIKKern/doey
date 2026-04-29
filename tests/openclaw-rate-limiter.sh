#!/usr/bin/env bash
# tests/openclaw-rate-limiter.sh
# Tests for the OpenClaw outbound rate ceiling library.
#   - baseline allow + suppression
#   - post-burst flush trigger
#   - sustained burst tick
#   - cross-bucket isolation
#
# Total wall-clock: ~5s (sleeps are unavoidable for time-window logic).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPROOT=$(mktemp -d -t oc-rate.XXXXXX)
trap 'rm -rf "$TMPROOT" 2>/dev/null || true' EXIT INT TERM

export RUNTIME_DIR="$TMPROOT"

# shellcheck source=/dev/null
. "${REPO_ROOT}/shell/openclaw-rate-limiter.sh"

fail=0

note() { printf '[rate-limit-test] %s\n' "$*"; }

# ──────────────────────────────────────────────────────────────────────
# Test 1: baseline — first 5 pass, next 5 in same second are suppressed.
# ──────────────────────────────────────────────────────────────────────
note "Test 1: baseline allow + suppression"
pass=0; supp=0; i=0
while [ "$i" -lt 10 ]; do
  if oc_rate_check t1 r1; then
    pass=$((pass + 1))
  else
    supp=$((supp + 1))
  fi
  i=$((i + 1))
done
note "  pass=$pass supp=$supp (expected pass>=5, supp>=1, total=10)"
if [ "$((pass + supp))" -ne 10 ]; then
  echo "FAIL: total events != 10"; fail=1
fi
if [ "$pass" -lt 5 ]; then
  echo "FAIL: fewer than 5 events passed"; fail=1
fi
if [ "$supp" -lt 1 ]; then
  echo "FAIL: no events were suppressed (race on second boundary?)"; fail=1
fi

# ──────────────────────────────────────────────────────────────────────
# Test 2: post-burst flush — 6 events => 1 suppressed; sleep 2; flush fires.
# ──────────────────────────────────────────────────────────────────────
note "Test 2: post-burst flush"
i=0
while [ "$i" -lt 6 ]; do
  oc_rate_check t2 r1 || true
  i=$((i + 1))
done
sleep 2
msg=$(oc_rate_pending_flush t2 r1 || true)
note "  flush message: '$msg'"
case "$msg" in
  *"events suppressed in last second"*) : ;;
  *) echo "FAIL: post-burst flush did not produce expected message"; fail=1 ;;
esac
oc_rate_consume_flush t2 r1
msg2=$(oc_rate_pending_flush t2 r1 || true)
if [ -n "$msg2" ]; then
  echo "FAIL: flush still pending after consume_flush: '$msg2'"; fail=1
fi

# ──────────────────────────────────────────────────────────────────────
# Test 3: sustained burst tick — events span seconds; tick fires after 1s.
# ──────────────────────────────────────────────────────────────────────
note "Test 3: sustained burst tick"
i=0
while [ "$i" -lt 5 ]; do oc_rate_check t3 r1 || true; i=$((i + 1)); done
sleep 1
i=0
while [ "$i" -lt 5 ]; do oc_rate_check t3 r1 || true; i=$((i + 1)); done
sleep 1
i=0; pass=0; supp=0
while [ "$i" -lt 10 ]; do
  if oc_rate_check t3 r1; then pass=$((pass + 1)); else supp=$((supp + 1)); fi
  i=$((i + 1))
done
note "  third burst: pass=$pass supp=$supp (expected pass>=5, supp>=1)"
if [ "$pass" -lt 5 ] || [ "$supp" -lt 1 ]; then
  echo "FAIL: third burst did not produce both passed and suppressed events"; fail=1
fi
sleep 1
msg3=$(oc_rate_pending_flush t3 r1 || true)
note "  tick flush message: '$msg3'"
case "$msg3" in
  *"events suppressed in last second"*) : ;;
  *) echo "FAIL: sustained-burst tick did not fire"; fail=1 ;;
esac

# ──────────────────────────────────────────────────────────────────────
# Test 4: cross-bucket isolation — bucket A's burst must not affect B.
# ──────────────────────────────────────────────────────────────────────
note "Test 4: cross-bucket isolation"
# Drain A in current second.
i=0
while [ "$i" -lt 12 ]; do oc_rate_check tA rX || true; i=$((i + 1)); done
# B should still allow 5 in same second.
b_pass=0; b_supp=0; i=0
while [ "$i" -lt 5 ]; do
  if oc_rate_check tB rX; then b_pass=$((b_pass + 1)); else b_supp=$((b_supp + 1)); fi
  i=$((i + 1))
done
note "  bucket B: pass=$b_pass supp=$b_supp (expected pass=5, supp=0)"
if [ "$b_pass" -ne 5 ] || [ "$b_supp" -ne 0 ]; then
  echo "FAIL: bucket B was affected by bucket A's burst"; fail=1
fi

# ──────────────────────────────────────────────────────────────────────
# Test 5: built-in self test.
# ──────────────────────────────────────────────────────────────────────
note "Test 5: oc_rate_self_test"
if ! oc_rate_self_test; then
  echo "FAIL: oc_rate_self_test reported failure"; fail=1
fi

if [ "$fail" = "0" ]; then
  echo "PASS: openclaw-rate-limiter"
  exit 0
fi
echo "FAIL: one or more rate-limiter checks failed"
exit 1
