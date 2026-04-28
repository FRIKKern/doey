#!/usr/bin/env bash
# OpenClaw v1 — Phase 1 latency probe.
#
# Local-only — runs under `doey test` or manual invocation. NOT in PR CI
# (needs live daemon). The fresh-install test (openclaw-fresh-install.sh)
# is the PR gate; this test is the round-trip gate that closes Phase 1.
#
# Measures `doey openclaw notify ping --event=probe` round-trip on
# localhost: notify → daemon → channel post. Phase 1 exit budget: 1500ms.
# Skips cleanly if no openclaw.conf or daemon is down — never blocks CI.
set -euo pipefail

LATENCY_BUDGET_MS=1500
CONF="$HOME/.config/doey/openclaw.conf"

if [ ! -f "$CONF" ]; then
  echo "openclaw-latency-probe: SKIP — $CONF not present (local-only opt-in)"
  exit 0
fi

if ! command -v doey >/dev/null 2>&1; then
  echo "openclaw-latency-probe: SKIP — doey CLI not on PATH"
  exit 0
fi

if ! doey openclaw gateway status >/dev/null 2>&1; then
  echo "openclaw-latency-probe: SKIP — openclaw gateway daemon not up"
  exit 0
fi

# Bash 3.2-safe millisecond clock.
# Order: GNU `date +%s%N` → `gdate +%s%N` (macOS coreutils) → python3 →
# second-resolution fallback. Bash 4.2+ time-format builtins are forbidden.
now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case "$ns" in
    *N|"")
      if command -v gdate >/dev/null 2>&1; then
        ns=$(gdate +%s%N)
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time()*1000))'
        return
      else
        echo "$(($(date +%s) * 1000))"
        return
      fi
      ;;
  esac
  echo "$((ns / 1000000))"
}

t0=$(now_ms)
if ! timeout 10 doey openclaw notify ping --event=probe >/dev/null 2>&1; then
  echo "openclaw-latency-probe: FAIL — notify ping returned non-zero"
  exit 1
fi
t1=$(now_ms)

elapsed=$((t1 - t0))

if [ "$elapsed" -lt 0 ]; then
  echo "openclaw-latency-probe: SKIP — clock skew (elapsed=${elapsed}ms)"
  exit 0
fi

echo "openclaw-latency-probe: round-trip ${elapsed}ms (budget ${LATENCY_BUDGET_MS}ms)"

if [ "$elapsed" -ge "$LATENCY_BUDGET_MS" ]; then
  echo "openclaw-latency-probe: FAIL — exceeded ${LATENCY_BUDGET_MS}ms budget"
  exit 1
fi

echo "openclaw-latency-probe: OK"
exit 0
