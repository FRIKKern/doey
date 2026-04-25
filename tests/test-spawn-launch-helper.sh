#!/usr/bin/env bash
# test-spawn-launch-helper.sh — Verifies doey_send_launch() defeats the
# bracketed-paste-leak race that breaks worker spawn (task 621).
#
# This is the regression gate for the W2.2 fix. Companion to
# tests/test-spawn-stress.sh (which reproduces the raw bug at the tmux level).
# Here we route the spawn through doey_send_launch — the production path that
# was newly added to shell/doey-send.sh — and confirm 10/10 panes boot even
# when a stray \e[200~ (PASTE_BEGIN) leaks into stdin during init.
#
# Bash 3.2 compatible.
set -euo pipefail

SESSION="doey-spawn-launch-$$"
WIN=stress
COUNT="${SPAWN_COUNT:-10}"
TIMEOUT="${SPAWN_TIMEOUT:-25}"
STRESS_LOAD="${SPAWN_STRESS:-1}"

CPU_PIDS=""

cleanup() {
  if [ -n "$CPU_PIDS" ]; then
    for p in $CPU_PIDS; do
      kill "$p" 2>/dev/null || true
    done
  fi
  tmux kill-session -t "$SESSION" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ! command -v tmux >/dev/null 2>&1; then
  echo "test-spawn-launch-helper: tmux not installed — skipping" >&2
  exit 0
fi

# Resolve repo root and source the helper under test
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/shell/doey-send.sh"

# CPU saturation to amplify the race window
if [ "$STRESS_LOAD" = "1" ]; then
  N_CORES=$(nproc 2>/dev/null || echo 4)
  i=0
  while [ "$i" -lt "$N_CORES" ]; do
    ( yes >/dev/null ) &
    CPU_PIDS="$CPU_PIDS $!"
    i=$((i + 1))
  done
fi

_DRAIN_STDIN='read -t 1 -n 10000 _ 2>/dev/null || true; '

TMPDIR_TEST="$(mktemp -d -t doey-spawn-launch.XXXXXX)"
MARKER="$TMPDIR_TEST/spawn_marker.sh"
cat > "$MARKER" <<'MARKER_EOF'
#!/usr/bin/env bash
set -e
printf 'STARTING\n'
sleep 0.05
printf 'SPAWN_OK_PANE_%s\n' "${TMUX_PANE:-?}"
# Imitate the ❯ prompt that doey_wait_for_prompt looks for
printf '\xe2\x9d\xaf '
while :; do sleep 60; done
MARKER_EOF
chmod +x "$MARKER"

# Long flag tail to mirror real worker cmd length (~600-900 chars).
LONG_ARGS=""
for f in 1 2 3 4 5 6 7 8 9 10; do
  LONG_ARGS="$LONG_ARGS --flag-$f \"value-$f-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
done
PAYLOAD="$MARKER $LONG_ARGS"
CMD="${_DRAIN_STDIN}${PAYLOAD}"

echo "test-spawn-launch-helper: COUNT=$COUNT TIMEOUT=${TIMEOUT}s STRESS_LOAD=$STRESS_LOAD"
echo "test-spawn-launch-helper: cmd length = ${#CMD} bytes"

RC_FILE="$TMPDIR_TEST/slow_rc.bash"
cat > "$RC_FILE" <<'RC_EOF'
sleep 0.4
PS1='$ '
RC_EOF

tmux new-session -d -s "$SESSION" -n "$WIN" -x 200 -y 50 "bash --rcfile '$RC_FILE' -i"

i=1
while [ "$i" -lt "$COUNT" ]; do
  tmux split-window -t "$SESSION:$WIN" -h "bash --rcfile '$RC_FILE' -i" 2>/dev/null || \
    tmux split-window -t "$SESSION:$WIN" -v "bash --rcfile '$RC_FILE' -i" 2>/dev/null || true
  tmux select-layout -t "$SESSION:$WIN" tiled >/dev/null 2>&1 || true
  i=$((i + 1))
done

N_PANES=$(tmux list-panes -t "$SESSION:$WIN" 2>/dev/null | wc -l | tr -d ' ')
echo "test-spawn-launch-helper: spawned $N_PANES panes"

# Inject the bracketed-paste START leak into half the panes (same scenario as
# tests/test-spawn-stress.sh) THEN route the launch through doey_send_launch.
PANES=$(tmux list-panes -t "$SESSION:$WIN" -F '#{pane_index}')
pidx=0
LAUNCH_RC=0
for p in $PANES; do
  if [ $((pidx % 2)) -eq 0 ]; then
    tmux send-keys -t "$SESSION:$WIN.$p" $'\033[200~' 2>/dev/null || true
  fi
  if ! doey_send_launch "$SESSION:$WIN.$p" "$CMD" 5 3; then
    LAUNCH_RC=$((LAUNCH_RC + 1))
  fi
  pidx=$((pidx + 1))
done

# Final verification — independent of doey_send_launch's own check.
deadline=$(( $(date +%s) + TIMEOUT ))
FAILED_PANES=""
for p in $PANES; do
  found=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    cap=$(tmux capture-pane -t "$SESSION:$WIN.$p" -p -S -50 2>/dev/null || true)
    if printf '%s' "$cap" | grep -qE 'SPAWN_OK_PANE_' 2>/dev/null; then
      found=1
      break
    fi
    sleep 0.25
  done
  if [ "$found" -eq 0 ]; then
    FAILED_PANES="$FAILED_PANES $p"
  fi
done

N_FAILED=0
for f in $FAILED_PANES; do N_FAILED=$((N_FAILED + 1)); done
N_OK=$(( N_PANES - N_FAILED ))

echo
echo "test-spawn-launch-helper: result = $N_OK/$N_PANES booted (helper-internal failures = $LAUNCH_RC)"
if [ "$N_FAILED" -gt 0 ]; then
  echo "test-spawn-launch-helper: FAILED panes:$FAILED_PANES"
  for p in $FAILED_PANES; do
    echo "---- pane $p (last 20 lines) ----"
    tmux capture-pane -t "$SESSION:$WIN.$p" -p -S -20 2>/dev/null || true
  done
  echo "----"
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
  exit 1
fi

rm -rf "$TMPDIR_TEST" 2>/dev/null || true
echo "test-spawn-launch-helper: PASS"
exit 0
