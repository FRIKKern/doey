#!/usr/bin/env bash
# tests/test-boss-stale-limit.sh
#
# Verifies that `doey-ctl status observe --json` correctly distinguishes
# a STALE rate-limit line in tmux scrollback (must NOT be reported as
# .limited == true) from a FRESH rate-limit line in the last few lines
# above the prompt (MUST be reported as .limited == true && !.limited_stale).
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no printf %T.
# Runs standalone: `bash tests/test-boss-stale-limit.sh`.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOEY_CTL_BIN="/tmp/doey-ctl-test-658"
TS_A="test-658-a-$$"
TS_B="test-658-b-$$"
TEST_RUNTIME="/tmp/doey-test-658-runtime-$$"
mkdir -p "$TEST_RUNTIME/status"

cleanup() {
  tmux kill-session -t "$TS_A" 2>/dev/null || true
  tmux kill-session -t "$TS_B" 2>/dev/null || true
  rm -rf "$TEST_RUNTIME" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Preconditions
command -v tmux >/dev/null 2>&1 || { echo "FAIL: tmux not installed" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "FAIL: jq not installed"   >&2; exit 1; }
command -v go   >/dev/null 2>&1 || { echo "FAIL: go not installed"   >&2; exit 1; }

echo "[build] doey-ctl -> $DOEY_CTL_BIN"
( cd "$PROJECT_DIR/tui" && go build -o "$DOEY_CTL_BIN" ./cmd/doey-ctl )

PASS_A=0
PASS_B=0

# ---------------------------------------------------------------------------
# Case A — STALE limit (line buried high above prompt + lastOutputAge > 60s).
# Expected: .limited != true (null/absent OK).
# ---------------------------------------------------------------------------
echo
echo "[case A] stale limit — expect .limited != true"
tmux new-session -d -s "$TS_A" -x 200 -y 50

# 8 filler lines, then the planted limit line, then 6 more filler lines so
# the limit string sits well above the trailing 5-line scan window.
i=1
while [ $i -le 8 ]; do
  tmux send-keys -t "$TS_A:0" "echo filler-A-$i" Enter
  i=$((i + 1))
done
tmux send-keys -t "$TS_A:0" "echo monthly usage limit reached" Enter
i=1
while [ $i -le 8 ]; do
  tmux send-keys -t "$TS_A:0" "echo filler-after-A-$i" Enter
  i=$((i + 1))
done

# Force lastOutputAge > 60 by sleeping. paneOutputAge() reads the pane
# tty's mtime via tmux display-message — sleeping is the portable way.
echo "[case A] sleeping 65s to age the pane tty mtime..."
sleep 65

JSON_A="$("$DOEY_CTL_BIN" status observe --runtime "$TEST_RUNTIME" --session "$TS_A" --json "0.0" 2>&1 || true)"
echo "[case A] observe JSON:"
echo "$JSON_A"

if echo "$JSON_A" | jq -e '.limited != true' >/dev/null 2>&1; then
  # Bonus: assert the detector saw it but stale-gated it.
  if echo "$JSON_A" | jq -e '.limited_stale == true' >/dev/null 2>&1; then
    echo "[case A] PASS — .limited != true and .limited_stale == true (stale-gated)"
  else
    echo "[case A] PASS — .limited != true (limit line was outside the 5-line tail or detector skipped it)"
  fi
  PASS_A=1
else
  echo "[case A] FAIL — .limited was reported true on a stale buffer"
fi

# ---------------------------------------------------------------------------
# Case B — FRESH limit (line is the last output, no sleep).
# Expected: .limited == true and .limited_stale != true.
# ---------------------------------------------------------------------------
echo
echo "[case B] fresh limit — expect .limited == true && !.limited_stale"
tmux new-session -d -s "$TS_B" -x 200 -y 50

# Single command whose output IS the limit string; lands directly above
# the next prompt, with lastOutputAge < 10s.
tmux send-keys -t "$TS_B:0" "printf 'monthly usage limit reached\\n'" Enter
sleep 2

JSON_B="$("$DOEY_CTL_BIN" status observe --runtime "$TEST_RUNTIME" --session "$TS_B" --json "0.0" 2>&1 || true)"
echo "[case B] observe JSON:"
echo "$JSON_B"

if echo "$JSON_B" | jq -e '.limited == true and (.limited_stale != true)' >/dev/null 2>&1; then
  echo "[case B] PASS — .limited == true and .limited_stale != true"
  PASS_B=1
else
  echo "[case B] FAIL — expected .limited == true && !.limited_stale"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test-boss-stale-limit.sh summary ====="
if [ "$PASS_A" -eq 1 ]; then echo "  Case A (stale)  : PASS"; else echo "  Case A (stale)  : FAIL"; fi
if [ "$PASS_B" -eq 1 ]; then echo "  Case B (fresh)  : PASS"; else echo "  Case B (fresh)  : FAIL"; fi

if [ "$PASS_A" -eq 1 ] && [ "$PASS_B" -eq 1 ]; then
  echo "  Result          : ALL PASS"
  exit 0
fi
echo "  Result          : FAIL"
exit 1
