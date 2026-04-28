#!/usr/bin/env bash
# test-send-submit.sh — Regression test for task 657: silent-success when
# bracketed-paste swallows trailing Enter on long fenced payloads.
#
# Spawns a tmux pane running a Python harness that:
#   1. Prints "❯ " + declares bracketed-paste support (\e[?2004h).
#   2. Reads stdin in raw mode and logs every byte burst to bytes.bin.
#   3. On a real Enter (0x0d/0x0a) outside an open \e[200~ … \e[201~ paste,
#      writes "STATUS: BUSY\nUPDATED: <epoch>\n" to the runtime status file
#      (mirrors on-prompt-submit.sh:72-76).
#   4. In sabotage mode, swallows incoming 0x0d/0x0a so Enter never lands.
#
# Five scenarios:
#   P1 short single-line "hello"
#   P2 3-line message with \n separators
#   P3 ≥1000-char single-line lorem
#   P4 triple-backtick fenced markdown block
#   P5 (sabotage) swallows Enter — verifier MUST return non-zero
#
# Bash 3.2 compatible. Standalone. <30s.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEND_LIB="${SEND_LIB:-${REPO_ROOT}/shell/doey-send.sh}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "test-send-submit: tmux not installed — skipping" >&2
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "test-send-submit: python3 not installed — skipping" >&2
  exit 0
fi
if [ ! -f "$SEND_LIB" ]; then
  echo "FAIL: $SEND_LIB not found" >&2
  exit 1
fi

TEST_TMP="$(mktemp -d /tmp/doey-test-657-XXXXXX)"
SESSION="doey-test-657-$$"
HARNESS="${TEST_TMP}/harness.py"
BYTE_LOG="${TEST_TMP}/bytes.bin"
KEEP_TMP="${KEEP_TMP:-0}"

mkdir -p "${TEST_TMP}/status" "${TEST_TMP}/locks"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  if [ "$KEEP_TMP" != "1" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  else
    echo "  (kept $TEST_TMP for postmortem)" >&2
  fi
}
trap cleanup EXIT INT TERM

cat > "$HARNESS" <<'HARNESS_EOF'
#!/usr/bin/env python3
import os, sys, time, select, termios

byte_log_path = sys.argv[1]
status_file = sys.argv[2]
mode = sys.argv[3] if len(sys.argv) > 3 else "fast"

fd = 0
attrs = termios.tcgetattr(fd)
attrs[3] &= ~(termios.ICANON | termios.ECHO)
termios.tcsetattr(fd, termios.TCSANOW, attrs)

sys.stdout.write("❯ ")
sys.stdout.write("\033[?2004h")
sys.stdout.flush()

f = open(byte_log_path, "wb", buffering=0)
poller = select.poll()
poller.register(fd, select.POLLIN)
last_event = time.monotonic_ns()
GAP_NS = 2_000_000

burst = b""
in_paste = False
PASTE_OPEN = b"\x1b[200~"
PASTE_CLOSE = b"\x1b[201~"

def write_busy():
    try:
        with open(status_file, "w") as sf:
            sf.write("STATUS: BUSY\n")
            sf.write("UPDATED: %d\n" % int(time.time()))
    except OSError:
        pass

def process_burst(b):
    global in_paste
    i = 0
    n = len(b)
    while i < n:
        if not in_paste and b[i:i+6] == PASTE_OPEN:
            in_paste = True
            i += 6
            continue
        if in_paste and b[i:i+6] == PASTE_CLOSE:
            in_paste = False
            i += 6
            continue
        c = b[i]
        if not in_paste and c in (0x0d, 0x0a):
            if mode != "sabotage":
                write_busy()
        i += 1

while True:
    evs = poller.poll(50)
    now = time.monotonic_ns()
    if evs:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        if mode == "sabotage":
            chunk = bytes(b for b in chunk if b not in (0x0d, 0x0a))
        if burst and (now - last_event) > GAP_NS:
            f.write(("%d %s\n" % (last_event // 1000, burst.hex())).encode())
            burst = b""
        burst += chunk
        process_burst(chunk)
        last_event = now
    else:
        if burst:
            f.write(("%d %s\n" % (last_event // 1000, burst.hex())).encode())
            burst = b""
HARNESS_EOF
chmod +x "$HARNESS"

PASS=0
FAIL=0
_pass() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

mtime_of() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0
}

run_one_scenario() {
  local id="$1"
  local mode="$2"
  local expected_rc="$3"
  local payload="$4"

  echo
  echo "============================================================"
  echo "Scenario $id (mode=$mode, expect_rc=$expected_rc, len=${#payload})"
  echo "============================================================"

  : > "$BYTE_LOG"
  tmux kill-session -t "$SESSION" 2>/dev/null || true

  local target="${SESSION}:0.0"
  local target_safe
  target_safe=$(printf '%s' "$target" | tr ':.-' '_')
  local status_file="${TEST_TMP}/status/${target_safe}.status"

  printf 'STATUS: READY\nUPDATED: %d\n' "$(($(date +%s) - 5))" > "$status_file"
  if command -v touch >/dev/null 2>&1; then
    touch -d "@$(($(date +%s) - 5))" "$status_file" 2>/dev/null || true
  fi

  tmux new-session -d -s "$SESSION" -x 200 -y 50 \
    "python3 '$HARNESS' '$BYTE_LOG' '$status_file' '$mode'"

  local i=0 found=0
  while [ "$i" -lt 30 ]; do
    if tmux capture-pane -t "$target" -p -S -10 2>/dev/null \
         | /bin/grep -qF '❯'; then
      found=1; break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$found" -ne 1 ]; then
    _fail "[$id] harness did not print ❯ within 3s"
    return 0
  fi

  local pre_mtime
  pre_mtime=$(mtime_of "$status_file")

  local rc=0
  set +e
  (
    set +e
    DOEY_RUNTIME="$TEST_TMP"
    export DOEY_RUNTIME
    PASTE_SETTLE_MS=200
    PASTE_GATE_MS=50
    export PASTE_SETTLE_MS PASTE_GATE_MS
    # shellcheck disable=SC1090
    . "$SEND_LIB"
    doey_send_verified "$target" "$payload" 1
  ) >/dev/null 2>&1
  rc=$?
  set -e

  sleep 0.5
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  sleep 0.2

  if [ "$expected_rc" = "0" ]; then
    if [ "$rc" -eq 0 ]; then
      _pass "[A][$id] doey_send_verified returned 0"
    else
      _fail "[A][$id] expected rc=0, got $rc"
    fi
  else
    if [ "$rc" -ne 0 ]; then
      _pass "[A][$id] doey_send_verified returned non-zero ($rc) — no silent success"
    else
      _fail "[A][$id] expected non-zero rc, got 0 (silent-success regression!)"
    fi
  fi

  local cur_status="" cur_mtime
  if [ -f "$status_file" ]; then
    cur_status=$(grep '^STATUS:' "$status_file" 2>/dev/null \
                 | head -1 | sed 's/^STATUS:[[:space:]]*//' || true)
  fi
  cur_mtime=$(mtime_of "$status_file")

  if [ "$expected_rc" = "0" ]; then
    if [ "$cur_status" = "BUSY" ]; then
      _pass "[B][$id] status file STATUS=BUSY"
    else
      _fail "[B][$id] expected STATUS=BUSY, got '$cur_status'"
    fi
    if [ "$cur_mtime" -gt "$pre_mtime" ]; then
      _pass "[C][$id] status mtime advanced ($pre_mtime → $cur_mtime)"
    else
      _fail "[C][$id] mtime did not advance (pre=$pre_mtime cur=$cur_mtime)"
    fi
  else
    if [ "$cur_status" = "BUSY" ] && [ "$cur_mtime" -gt "$pre_mtime" ]; then
      _fail "[E][$id] status file shows fresh BUSY despite sabotage — harness leak"
    else
      _pass "[E][$id] no fresh BUSY (status='$cur_status' mtime_delta=$((cur_mtime - pre_mtime)))"
    fi
  fi

  local hex payload_hex
  hex=$(awk '{print $2}' "$BYTE_LOG" 2>/dev/null | tr -d '\n' || true)
  payload_hex=$(printf '%s' "$payload" | od -An -tx1 | tr -d ' \n')
  if [ -n "$payload_hex" ] && [ -n "$hex" ]; then
    case "$hex" in
      *"$payload_hex"*)
        local prefix="${hex%%${payload_hex}*}"
        local off="${#prefix}"
        if [ "$off" -ge 2 ]; then
          local last_byte="${prefix: -2}"
          if [ "$last_byte" = "1b" ]; then
            _fail "[D][$id] bare ESC (0x1B) immediately precedes payload — race fingerprint"
          else
            _pass "[D][$id] no bare ESC immediately before payload (last=0x${last_byte})"
          fi
        else
          _pass "[D][$id] payload at stream start — no preceding bytes"
        fi
        ;;
      *)
        printf '  SKIP [D][%s] payload bytes not located in stream\n' "$id"
        ;;
    esac
  fi
}

build_lorem() {
  local base="lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua "
  local out=""
  while [ "${#out}" -lt 1024 ]; do
    out="${out}${base}"
  done
  printf '%s' "$out"
}
LOREM="$(build_lorem)"

P4_PAYLOAD="$(printf 'Here:\n```bash\n#!/bin/bash\necho test\n```\nDone')"
P2_PAYLOAD="$(printf 'line one\nline two\nline three')"

run_one_scenario P1 fast     0 "hello"
run_one_scenario P2 fast     0 "$P2_PAYLOAD"
run_one_scenario P3 fast     0 "$LOREM"
run_one_scenario P4 fast     0 "$P4_PAYLOAD"
run_one_scenario P5 sabotage 1 "$LOREM"

echo
echo "============================================================"
printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
