#!/usr/bin/env bash
set -euo pipefail

# test-perf-baseline.sh — Measure and record performance baselines for doey.sh
#
# Measures:
#   1. Time to source doey.sh (function loading)
#   2. Time for doey --version
#   3. Time to source the full module chain
#
# Writes JSON results to /tmp/doey/perf-baseline.json
# Reports human-readable results to stdout

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_DIR="${PROJECT_ROOT}/shell"

# ── Bash 3.2 compatible nanosecond timer ─────────────────────────────
# macOS date returns "<epoch>N" literally for %N; detect and fall back
_now_ns() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case "$ns" in
    *N) echo "$(date +%s)000000000" ;;
    *)  echo "$ns" ;;
  esac
}

_elapsed_ms() {
  local start="$1" end="$2"
  # Bash 3.2 doesn't handle large integers well with $(()),
  # so use awk for the division
  awk "BEGIN { printf \"%.2f\", ($end - $start) / 1000000 }"
}

echo "=== Doey Performance Baseline ==="
echo ""

# ── Test 1: Time to source doey.sh ───────────────────────────────────
echo "1. Sourcing doey.sh..."
t1_start=$(_now_ns)
(
  source "${SHELL_DIR}/doey.sh" __doey_source_only
)
t1_end=$(_now_ns)
t1_ms=$(_elapsed_ms "$t1_start" "$t1_end")
echo "   Source doey.sh: ${t1_ms}ms"

# ── Test 2: Time for doey --version ──────────────────────────────────
echo "2. Running doey --version..."
t2_start=$(_now_ns)
if command -v doey >/dev/null 2>&1; then
  doey --version >/dev/null 2>&1 || true
else
  bash "${SHELL_DIR}/doey.sh" version >/dev/null 2>&1 || true
fi
t2_end=$(_now_ns)
t2_ms=$(_elapsed_ms "$t2_start" "$t2_end")
echo "   doey --version: ${t2_ms}ms"

# ── Test 3: Time to source full module chain ─────────────────────────
echo "3. Sourcing full module chain..."

# All safe-to-source modules
safe_modules="doey-constants.sh doey-go-check.sh doey-go-helpers.sh doey-ipc-helpers.sh doey-plan-helpers.sh doey-roles.sh doey-send.sh doey-task-helpers.sh"

t3_start=$(_now_ns)
(
  source "${SHELL_DIR}/doey.sh" __doey_source_only
  for mod in $safe_modules; do
    [ -f "${SHELL_DIR}/${mod}" ] && { source "${SHELL_DIR}/${mod}" || true; }
  done
)
t3_end=$(_now_ns)
t3_ms=$(_elapsed_ms "$t3_start" "$t3_end")
echo "   Full module chain: ${t3_ms}ms"

# ── Write JSON results ───────────────────────────────────────────────
output_dir="/tmp/doey"
mkdir -p "$output_dir"
output_file="${output_dir}/perf-baseline.json"

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$output_file" <<EOF
{
  "timestamp": "${timestamp}",
  "measurements": {
    "source_doey_sh_ms": ${t1_ms},
    "doey_version_ms": ${t2_ms},
    "full_module_chain_ms": ${t3_ms}
  },
  "shell": "$(bash --version | head -1)",
  "platform": "$(uname -s)-$(uname -m)"
}
EOF

echo ""
echo "Results written to ${output_file}"
echo ""
echo "=== Summary ==="
echo "  Source doey.sh:      ${t1_ms}ms"
echo "  doey --version:      ${t2_ms}ms"
echo "  Full module chain:   ${t3_ms}ms"
echo ""
echo "DONE"
