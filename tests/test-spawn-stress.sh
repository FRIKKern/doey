#!/usr/bin/env bash
# test-spawn-stress.sh — Regression gate for worker-spawn drop-Enter bug
# (task 621). Routes the spawn through doey_send_launch (the W2.2 fix) and
# verifies that 10/10 panes boot even with a stray bracketed-paste-START
# sequence injected into stdin during shell init.
#
# Pre-fix (raw `tmux send-keys "$cmd" Enter`): 5/10 panes deterministically
# fail because readline enters paste mode and treats Enter as literal newline.
# Post-fix (doey_send_launch): the kick-and-verify loop closes any open paste
# (\e[201~) and re-submits Enter until `❯` is observed.
#
# PASS = all panes show SPAWN_OK_PANE_* within timeout.
# FAIL = at least one pane sits at the shell prompt with the command typed
#        but Enter dropped (the bug).
#
# Bash 3.2 compatible.
set -euo pipefail

SESSION="doey-spawn-stress-$$"
WIN=stress
COUNT="${SPAWN_COUNT:-10}"
TIMEOUT="${SPAWN_TIMEOUT:-15}"
STRESS_LOAD="${SPAWN_STRESS:-1}"   # 1 = launch background CPU loop

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
  echo "test-spawn-stress: tmux not installed — skipping" >&2
  exit 0
fi

# Source the helper under test (doey_send_launch lives in shell/doey-send.sh).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/shell/doey-send.sh"

# Optional CPU stress: simulate the busy-host condition under which the
# bug surfaces (worker boot races with a loaded CPU/PTY scheduler).
if [ "$STRESS_LOAD" = "1" ]; then
  # Saturate every core so PTY scheduling is contested during the spawn race
  N_CORES=$(nproc 2>/dev/null || echo 4)
  i=0
  while [ "$i" -lt "$N_CORES" ]; do
    ( yes >/dev/null ) &
    CPU_PIDS="$CPU_PIDS $!"
    i=$((i + 1))
  done
fi

# Mirror shell/doey.sh:133 verbatim
_DRAIN_STDIN='read -t 1 -n 10000 _ 2>/dev/null || true; '

# Build a long payload that mirrors the structure of the real worker launch
# command — many flags, long quoted strings, an --append-system-prompt-file
# argument with a 2KB-ish path. We replace `claude` with a stand-in marker
# script so the test does not require a working claude binary or auth.
TMPDIR_TEST="$(mktemp -d -t doey-spawn-stress.XXXXXX)"
MARKER="$TMPDIR_TEST/spawn_marker.sh"
cat > "$MARKER" <<'MARKER_EOF'
#!/usr/bin/env bash
# Mimic the boot shape of `claude`: print a few lines then sit at a fake
# prompt forever. The marker line proves the parent shell executed the
# command (i.e. Enter was not dropped).
set -e
printf 'STARTING\n'
sleep 0.05
printf 'SPAWN_OK_PANE_%s\n' "${TMUX_PANE:-?}"
# Imitate the ❯ prompt that doey_wait_for_prompt looks for
printf '\xe2\x9d\xaf '
# Stay alive so the pane does not exit and clobber the capture buffer
while :; do sleep 60; done
MARKER_EOF
chmod +x "$MARKER"

# Build a long-flag payload to approximate the real launch command length.
# Real worker cmd is ~400-600 chars (claude path + many flags + prompt path).
LONG_ARGS=""
for f in 1 2 3 4 5 6 7 8 9 10; do
  LONG_ARGS="$LONG_ARGS --flag-$f \"value-$f-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
done
# Note: marker doesn't read these flags, but they pad the typed length.
PAYLOAD="$MARKER $LONG_ARGS"

CMD="${_DRAIN_STDIN}${PAYLOAD}"

echo "test-spawn-stress: COUNT=$COUNT TIMEOUT=${TIMEOUT}s STRESS_LOAD=$STRESS_LOAD"
echo "test-spawn-stress: cmd length = ${#CMD} bytes"

# Fresh tmux session in detached mode
# Slow rcfile that mimics a real interactive shell init (zsh sourcing
# heavy rcfiles, fnm/nvm shims, etc). The spawn race only surfaces when
# the shell takes long enough to draw its prompt that send-keys arrives
# during the init window. Without this, fresh bash panes render their
# prompt in <10ms and the race never triggers.
RC_FILE="$TMPDIR_TEST/slow_rc.bash"
cat > "$RC_FILE" <<'RC_EOF'
# Simulate slow rcfile (fnm/nvm/oh-my-zsh init typically 100-400ms)
sleep 0.4
PS1='$ '
RC_EOF

tmux new-session -d -s "$SESSION" -n "$WIN" -x 200 -y 50 "bash --rcfile '$RC_FILE' -i"
# DO NOT wait for the prompt — this is exactly the race condition the bug
# exposes (keys sent before shell readline is ready).

# Spawn COUNT-1 additional panes — split-window without -d so they're tiled
i=1
while [ "$i" -lt "$COUNT" ]; do
  tmux split-window -t "$SESSION:$WIN" -h "bash --rcfile '$RC_FILE' -i" 2>/dev/null || \
    tmux split-window -t "$SESSION:$WIN" -v "bash --rcfile '$RC_FILE' -i" 2>/dev/null || true
  tmux select-layout -t "$SESSION:$WIN" tiled >/dev/null 2>&1 || true
  i=$((i + 1))
done

# List panes to confirm we got COUNT
N_PANES=$(tmux list-panes -t "$SESSION:$WIN" 2>/dev/null | wc -l | tr -d ' ')
echo "test-spawn-stress: spawned $N_PANES panes"

# Inject a stray bracketed-paste START sequence (\e[200~) into half the panes
# BEFORE launch. This simulates the production failure where an escape
# sequence (from a concurrent claude OSC query response, a leaking outer-term
# response, or any process writing to the pane) lands in stdin during init.
# Bash readline (bracketed-paste enabled by default since 5.1) treats the
# subsequent Enter as literal newline rather than line-submit — this is the
# root cause of the "command typed at prompt but never executed" bug.
#
# Then route the launch through doey_send_launch (the W2.2 fix). The helper's
# pre-clear (close-paste + C-c) plus verify-and-kick loop must defeat the leak.
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

# Wait up to TIMEOUT seconds, polling all panes once per round.
# (Per-pane deadline would let early-failing panes consume the budget for
# late-checking panes — share the timeout across rounds instead.)
FAILED_PANES=""
deadline=$(( $(date +%s) + TIMEOUT ))
declare -a found_arr
i=0
for p in $PANES; do
  found_arr[$i]=0
  i=$((i + 1))
done

while [ "$(date +%s)" -lt "$deadline" ]; do
  all_done=1
  i=0
  for p in $PANES; do
    if [ "${found_arr[$i]}" -eq 0 ]; then
      cap=$(tmux capture-pane -t "$SESSION:$WIN.$p" -p -S -50 2>/dev/null || true)
      if printf '%s' "$cap" | grep -qE 'SPAWN_OK_PANE_'; then
        found_arr[$i]=1
      else
        all_done=0
      fi
    fi
    i=$((i + 1))
  done
  [ "$all_done" -eq 1 ] && break
  sleep 0.25
done

i=0
for p in $PANES; do
  if [ "${found_arr[$i]}" -eq 0 ]; then
    FAILED_PANES="$FAILED_PANES $p"
  fi
  i=$((i + 1))
done

# Report
N_FAILED=0
for f in $FAILED_PANES; do N_FAILED=$((N_FAILED + 1)); done
N_OK=$(( N_PANES - N_FAILED ))

echo
echo "test-spawn-stress: result = $N_OK/$N_PANES booted (helper-internal failures = $LAUNCH_RC)"
if [ "$N_FAILED" -gt 0 ]; then
  echo "test-spawn-stress: FAILED panes:$FAILED_PANES"
  for p in $FAILED_PANES; do
    echo "---- pane $p (last 20 lines) ----"
    tmux capture-pane -t "$SESSION:$WIN.$p" -p -S -20 2>/dev/null || true
  done
  echo "----"
  rm -rf "$TMPDIR_TEST" 2>/dev/null || true
  exit 1
fi

rm -rf "$TMPDIR_TEST" 2>/dev/null || true
echo "test-spawn-stress: PASS"
exit 0
