#!/usr/bin/env bash
# test-send-launch-no-esc-race.sh — Regression test for task 647: ESC-before-
# bracketed-paste race in doey_send_verified / doey_send_launch.
#
# Background: a brief sent to a Claude Code TUI pane uses tmux paste-buffer
# and surrounding send-keys sequences that include ESC (\033) bytes. The
# Claude Code TUI binds bare ESC to "clear input buffer". If a `\e[201~`
# close-paste sequence (or any ESC-prefixed CSI) is delivered with a gap
# before the trailing key, the TUI may interpret the lone ESC as
# clear-input — wiping a brief that was just pasted.
#
# This test spawns a tmux pane with a byte-capture harness, drives
# doey_send_verified and doey_send_launch from shell/doey-send.sh, and
# inspects every byte received by the pane. It asserts:
#
#   [A] Brief content reaches the harness intact.
#   [B] Any \e[201~ paste-close is followed by Enter (0d/0a — pty CR→LF) or
#       C-c (03) within the same write — not orphaned at the tail of the
#       byte stream where Claude TUI could parse the lone ESC as clear-input.
#   [C] No bare ESC byte is interleaved immediately before the brief content
#       (the race fingerprint).
#
# Bonus scenario "slow": harness deliberately does NOT emit \e[?2004h, so a
# correctly-gated implementation would either delay or skip raw paste. The
# test reports diagnostic behavior; it does not yet hard-fail the slow-mode
# brief delivery (see report).
#
# Bash 3.2 compatible. Standalone runnable. Finishes in < 10s.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEND_LIB="${SEND_LIB:-${REPO_ROOT}/shell/doey-send.sh}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "test-send-launch-no-esc-race: tmux not installed — skipping" >&2
  exit 0
fi
if [ ! -f "$SEND_LIB" ]; then
  echo "FAIL: $SEND_LIB not found" >&2
  exit 1
fi

TEST_TMP="$(mktemp -d /tmp/doey-test-647-XXXXXX)"
SESSION="doey-test-647-$$"
HARNESS="${TEST_TMP}/harness.sh"
BYTE_LOG="${TEST_TMP}/bytes.bin"
KEEP_TMP="${KEEP_TMP:-0}"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  if [ "$KEEP_TMP" != "1" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  else
    echo "  (kept $TEST_TMP for postmortem)" >&2
  fi
}
trap cleanup EXIT INT TERM

# Build the harness — runs in target tmux pane. Reads stdin via os.read() at
# ~1ms cadence and logs each read() burst as a separate line in BYTE_LOG with
# format "<epoch_us> <hex>". Bytes that arrive together (same write() syscall
# from tmux) usually land in one burst; bytes split across two send-keys
# invocations land in two bursts. This lets the test distinguish atomic
# (fixed) vs split (broken) close-paste delivery — the core of task 647.
cat > "$HARNESS" <<'HARNESS_EOF'
#!/usr/bin/env python3
import os, sys, time, select, termios

byte_log = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "fast"

fd = 0
attrs = termios.tcgetattr(fd)
attrs[3] &= ~(termios.ICANON | termios.ECHO)
termios.tcsetattr(fd, termios.TCSANOW, attrs)

# Print prompt + (optionally) bracketed-paste mode declaration
sys.stdout.write("❯ ")
if mode == "fast":
    sys.stdout.write("\033[?2004h")
sys.stdout.flush()

f = open(byte_log, "wb", buffering=0)
poller = select.poll()
poller.register(fd, select.POLLIN)
last_event = time.monotonic_ns()
GAP_NS = 2_000_000   # 2ms — bursts separated by >2ms count as distinct writes

burst = b""
while True:
    evs = poller.poll(50)   # 50ms — short enough to detect a 5ms gap
    now = time.monotonic_ns()
    if evs:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        if burst and (now - last_event) > GAP_NS:
            f.write(("%d %s\n" % (last_event // 1000, burst.hex())).encode())
            burst = b""
        burst += chunk
        last_event = now
    else:
        if burst:
            f.write(("%d %s\n" % (last_event // 1000, burst.hex())).encode())
            burst = b""
        # idle — keep polling unless we've been idle long enough that the
        # send is clearly done; in practice the tmux session is killed.
HARNESS_EOF
chmod +x "$HARNESS"

# ── Helpers ──────────────────────────────────────────────────────────────

# hex_offset_of <hex_haystack> <hex_needle>
# Echoes the hex-string offset (chars) of needle in haystack, or empty.
hex_offset_of() {
  local hay="$1" needle="$2"
  case "$hay" in
    *"$needle"*) ;;
    *) return 1 ;;
  esac
  local prefix="${hay%%${needle}*}"
  printf '%s' "${#prefix}"
}

run_one_scenario() {
  local mode="$1"
  local fn="$2"
  local payload="$3"
  local label="${fn}-${mode}"

  echo
  echo "============================================================"
  echo "Scenario: $label"
  echo "============================================================"

  : > "$BYTE_LOG"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -x 200 -y 50 \
    "python3 '$HARNESS' '$BYTE_LOG' '$mode'"

  # Wait for harness prompt
  local i=0 found=0
  while [ "$i" -lt 30 ]; do
    if tmux capture-pane -t "${SESSION}:0.0" -p -S -10 2>/dev/null \
         | /bin/grep -qF '❯'; then
      found=1; break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$found" -ne 1 ]; then
    echo "  FAIL: harness did not print ❯ within 3s"
    return 1
  fi

  # Pre-write BUSY status so doey_send_verified's submission-confirm loop
  # exits fast (saves ~3s per scenario).
  local target="${SESSION}:0.0"
  local target_safe
  target_safe=$(printf '%s' "$target" | tr ':.-' '_')
  mkdir -p "${TEST_TMP}/status" "${TEST_TMP}/locks"
  printf 'STATUS: BUSY\n' > "${TEST_TMP}/status/${target_safe}.status"

  # Drive the send under test in a subshell (keeps our shell options clean).
  (
    set +e
    DOEY_RUNTIME="$TEST_TMP"
    export DOEY_RUNTIME
    PASTE_SETTLE_MS=200
    PASTE_GATE_MS=50
    export PASTE_SETTLE_MS PASTE_GATE_MS
    # shellcheck disable=SC1090
    . "$SEND_LIB"
    case "$fn" in
      verified)  doey_send_verified "$target" "$payload" 1 ;;
      launch)    doey_send_launch   "$target" "$payload" 2 1 ;;
    esac
  ) >/dev/null 2>&1 || true

  # Allow trailing bytes to flush, then kill harness so tee exits.
  sleep 0.5
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  sleep 0.2

  # BYTE_LOG format: one line per burst — "<epoch_us> <hex>"
  echo "  Bursts received (us  hex):"
  if [ -s "$BYTE_LOG" ]; then
    sed 's/^/    /' "$BYTE_LOG"
  else
    echo "    (empty)"
  fi
  # Concatenated hex stream (across all bursts, in order)
  local hex
  hex=$(awk '{print $2}' "$BYTE_LOG" | tr -d '\n' || true)

  local payload_hex
  payload_hex=$(printf '%s' "$payload" | od -An -tx1 | tr -d ' \n')
  local close_hex="1b5b3230317e"   # ESC [ 2 0 1 ~

  local fails=0

  # [A] Payload content delivered
  case "$hex" in
    *"$payload_hex"*)
      echo "  PASS [A] payload bytes present"
      ;;
    *)
      echo "  FAIL [A] payload bytes NOT present in stream"
      fails=$((fails + 1))
      ;;
  esac

  # [D] If \e[201~ appears, it must be in the SAME burst as Enter (0d/0a) or
  #     C-c (03). Atomic write at tmux send-keys level is what defeats the
  #     receiver's bare-ESC parse race (task 647 core invariant).
  local close_hex_d="1b5b3230317e"
  local atomic_violation=""
  while IFS= read -r line; do
    local b="${line#* }"
    case "$b" in
      *"$close_hex_d"*)
        # Strip up to and including the close — remainder is what tmux paired
        # in the same write(). Atomic = remainder contains 0d/0a/03 (Enter or C-c).
        local tail_after_close="${b#*${close_hex_d}}"
        case "$tail_after_close" in
          *0d*|*0a*|*03*) : ;;
          *) atomic_violation="$line" ;;
        esac
        ;;
    esac
  done < "$BYTE_LOG"
  case "$hex" in
    *"$close_hex_d"*)
      if [ -z "$atomic_violation" ]; then
        echo "  PASS [D] \\e[201~ delivered in same burst as Enter/C-c (atomic)"
      else
        echo "  FAIL [D] \\e[201~ delivered in burst WITHOUT trailing Enter/C-c — split write"
        echo "          offending burst: $atomic_violation"
        fails=$((fails + 1))
      fi
      ;;
    *) : ;;  # no close in stream — [D] not applicable
  esac

  # [B] \e[201~ tail must be followed by Enter (0d) or C-c (03)
  case "$hex" in
    *"$close_hex"*)
      local tail="${hex##*${close_hex}}"
      case "$tail" in
        *0d*|*0a*|*03*)
          echo "  PASS [B] \\e[201~ followed atomically by Enter (0d/0a) or C-c (03)"
          ;;
        "")
          echo "  FAIL [B] \\e[201~ at end of stream — no trailing key (orphan ESC race)"
          fails=$((fails + 1))
          ;;
        *)
          echo "  FAIL [B] \\e[201~ trailer lacks Enter/C-c — tail=${tail}"
          fails=$((fails + 1))
          ;;
      esac
      ;;
    *)
      echo "  SKIP [B] no \\e[201~ in stream"
      ;;
  esac

  # [C] No bare ESC byte directly precedes the payload, AND no orphan ESC
  #     appears between the payload end and the \e[201~ close. An ESC inside
  #     this window would be parsed by Claude TUI as bare-ESC = clear-input,
  #     wiping the just-pasted brief (the task 647 fingerprint).
  if [ -n "$payload_hex" ]; then
    local off
    off=$(hex_offset_of "$hex" "$payload_hex" 2>/dev/null || true)
    if [ -n "$off" ] && [ "$off" -ge 2 ]; then
      local before="${hex:0:$off}"
      local last_byte="${before: -2}"
      if [ "$last_byte" = "1b" ]; then
        echo "  FAIL [C1] bare ESC (0x1B) immediately precedes payload — race fingerprint"
        fails=$((fails + 1))
      else
        echo "  PASS [C1] no bare ESC immediately before payload (last byte=0x${last_byte})"
      fi
    elif [ -z "$off" ]; then
      echo "  SKIP [C1] payload not located in stream"
    fi

    # C2: ESC between payload end and the first \e[201~ close.
    if [ -n "$off" ]; then
      local payload_len="${#payload_hex}"
      local after_payload_off=$((off + payload_len))
      local rest="${hex:$after_payload_off}"
      local before_close="${rest%%${close_hex}*}"
      # Only meaningful when close exists and there's content between
      case "$rest" in
        *"$close_hex"*)
          case "$before_close" in
            *1b*)
              echo "  FAIL [C2] bare ESC between payload and \\e[201~ — input-clear race"
              fails=$((fails + 1))
              ;;
            *)
              echo "  PASS [C2] no orphan ESC between payload and \\e[201~"
              ;;
          esac
          ;;
      esac
    fi
  fi

  # [Diagnostic] for slow mode
  if [ "$mode" = "slow" ]; then
    case "$hex" in
      *1b5b3f323030346[68]*)
        # harness emitted \e[?2004h before our send — shouldn't happen in slow
        echo "  NOTE [slow] harness unexpectedly emitted \\e[?2004h"
        ;;
      *"$payload_hex"*)
        echo "  NOTE [slow] brief delivered without \\e[?2004h ack — gating fix would suppress this"
        ;;
      *)
        echo "  NOTE [slow] brief NOT delivered — gating may already be in place"
        ;;
    esac
  fi

  return $fails
}

total_fails=0

run_one_scenario fast verified "BRIEF_647_FAST_PROBE_xyz" \
  || total_fails=$((total_fails + $?))
run_one_scenario slow verified "BRIEF_647_SLOW_PROBE_xyz" \
  || total_fails=$((total_fails + $?))

echo
echo "============================================================"
if [ "$total_fails" -gt 0 ]; then
  echo "RESULT: $total_fails assertion(s) failed"
  exit 1
fi
echo "RESULT: all assertions passed"
exit 0
