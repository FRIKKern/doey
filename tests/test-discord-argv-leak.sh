#!/usr/bin/env bash
# test-discord-argv-leak.sh — proves `doey-tui discord send` never carries
# the notification body on argv. Body MUST travel via stdin only, so that
# `ps` on a multi-tenant host cannot observe secrets even momentarily.
#
# Strategy:
#   1. Generate a unique SECRET token.
#   2. Launch `doey-tui discord send --if-bound ...` in the background with
#      the SECRET piped via stdin. --if-bound makes the process exit cleanly
#      without a binding — we only need it to LIVE long enough for ps to
#      sample its argv.
#   3. Sample `ps` argv output; assert the SECRET does not appear anywhere.
#   4. Clean up the backgrounded process.
#
# Skipped (exit 0) when doey-tui is not on PATH.
set -euo pipefail

if ! command -v doey-tui >/dev/null 2>&1; then
  echo "test-discord-argv-leak: skipped (doey-tui not on PATH)"
  exit 0
fi

SECRET="argv-leak-probe-$(date +%s)-$RANDOM-$$"
TMPDIR_LOCAL="$(mktemp -d)"
cleanup() {
  # Kill backgrounded child if still around; swallow errors.
  kill %1 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$TMPDIR_LOCAL" 2>/dev/null || true
}
trap cleanup EXIT

# Use an isolated project dir so --if-bound short-circuits without touching
# the developer's real config/binding.
mkdir -p "$TMPDIR_LOCAL/proj/.doey"
export PROJECT_DIR="$TMPDIR_LOCAL/proj"

# Slow the stdin reader with a larger volume of SECRET bytes so ps has a
# chance to sample argv before the process exits. `yes | head -c` generates
# up to 4000 bytes of repeating SECRET-prefixed lines. Body still travels
# on stdin — argv is what we test.
(
  yes "$SECRET" 2>/dev/null | head -c 4000 | \
    doey-tui discord send \
      --if-bound \
      --title "leak-test" \
      --event leak \
      --task-id leak \
      >/dev/null 2>&1
) &
BG_PID=$!

# Give the subshell a brief moment to exec the binary before sampling.
sleep 0.05 2>/dev/null || sleep 1

leak_found=0
leak_sample=""

# Try both portable ps forms. Either one containing the SECRET is a FAIL.
if out=$(ps -e -o pid=,command= 2>/dev/null); then
  if printf '%s' "$out" | grep -F "$SECRET" >/dev/null 2>&1; then
    leak_found=1
    leak_sample=$(printf '%s' "$out" | grep -F "$SECRET" | head -n 3)
  fi
fi
if [ "$leak_found" -eq 0 ]; then
  if out=$(ps -e -o args= 2>/dev/null); then
    if printf '%s' "$out" | grep -F "$SECRET" >/dev/null 2>&1; then
      leak_found=1
      leak_sample=$(printf '%s' "$out" | grep -F "$SECRET" | head -n 3)
    fi
  fi
fi

# Wait for the background process to finish; ignore its exit code.
wait "$BG_PID" 2>/dev/null || true

if [ "$leak_found" -ne 0 ]; then
  echo "FAIL: SECRET token observed in argv — body leaked to process table"
  echo "--- sample ---"
  printf '%s\n' "$leak_sample"
  echo "--- /sample ---"
  exit 1
fi

echo "PASS: no argv leak detected (body stayed on stdin)"
exit 0
