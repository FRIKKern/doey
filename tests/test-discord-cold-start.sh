#!/usr/bin/env bash
# test-discord-cold-start.sh — cold-start latency gate for `doey discord status`.
# Masterplan line 257: p50 <= 200ms, p95 <= 400ms for the no-network happy path
# (breaker-open or no-binding exit).
#
# Requires GNU date (`date +%s%N`). On macOS install coreutils and use gdate,
# or skip via SKIP_COLD_START=1. The script auto-detects a missing GNU date
# and skips with a clear message.
#
# Environment overrides:
#   COLD_START_ITERATIONS   iteration count (default: 30)
#   COLD_START_P50_MS       p50 threshold in ms (default: 200)
#   COLD_START_P95_MS       p95 threshold in ms (default: 400)
#   SKIP_COLD_START=1       skip the gate entirely
set -euo pipefail

if [ "${SKIP_COLD_START:-0}" = "1" ]; then
  echo "test-discord-cold-start: skipped (SKIP_COLD_START=1)"
  exit 0
fi
if ! command -v doey-tui >/dev/null 2>&1; then
  echo "test-discord-cold-start: skipped (doey-tui not on PATH)"
  exit 0
fi
if ! date +%s%N | grep -Eq '^[0-9]+$'; then
  echo "test-discord-cold-start: skipped (GNU date required; brew install coreutils and use gdate, or SKIP_COLD_START=1)"
  exit 0
fi

# Isolate so the test doesn't hit the developer's real config / project binding.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/xdg/doey" "$TMP/proj/.doey"
export XDG_CONFIG_HOME="$TMP/xdg"
export PROJECT_DIR="$TMP/proj"

N="${COLD_START_ITERATIONS:-30}"
P50_MAX_MS="${COLD_START_P50_MS:-200}"
P95_MAX_MS="${COLD_START_P95_MS:-400}"

samples_file="$TMP/samples.txt"
: > "$samples_file"

i=1
while [ "$i" -le "$N" ]; do
  start=$(date +%s%N)
  doey-tui discord status >/dev/null 2>&1 || true
  end=$(date +%s%N)
  delta_ns=$((end - start))
  delta_ms=$((delta_ns / 1000000))
  printf '%s\n' "$delta_ms" >> "$samples_file"
  i=$((i + 1))
done

sort -n "$samples_file" > "$TMP/sorted.txt"
p50=$(awk 'BEGIN{c=0} {c++; a[c]=$0} END{idx=int(c*0.5 + 0.5); if(idx<1)idx=1; if(idx>c)idx=c; print a[idx]}' "$TMP/sorted.txt")
p95=$(awk 'BEGIN{c=0} {c++; a[c]=$0} END{idx=int(c*0.95 + 0.5); if(idx<1)idx=1; if(idx>c)idx=c; print a[idx]}' "$TMP/sorted.txt")

echo "test-discord-cold-start: n=$N p50=${p50}ms p95=${p95}ms (thresholds p50<=${P50_MAX_MS} p95<=${P95_MAX_MS})"

if [ "$p95" -gt "$P95_MAX_MS" ]; then
  echo "FAIL: p95=${p95}ms exceeds ${P95_MAX_MS}ms threshold" >&2
  exit 1
fi
if [ "$p50" -gt "$P50_MAX_MS" ]; then
  echo "FAIL: p50=${p50}ms exceeds ${P50_MAX_MS}ms threshold" >&2
  exit 1
fi
echo "OK"
