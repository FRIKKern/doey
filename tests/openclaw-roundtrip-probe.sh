#!/usr/bin/env bash
# tests/openclaw-roundtrip-probe.sh
# Phase 2 round-trip latency gate: from boss-idle touch → unwrapped paste
# delivered to Boss pane in < 2000ms.
#
# This probe REQUIRES live components: bridge binary, hooks, and a Boss
# pane. When prerequisites are missing, exit 77 (SKIP) with a clear reason.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ_DIR="${DOEY_PROJECT_DIR:-$REPO_ROOT}"

skip() {
  echo "SKIP: $*" >&2
  exit 77
}

# Prereq 1: binding must exist.
[ -f "${PROJ_DIR}/.doey/openclaw-binding" ] \
  || skip "no .doey/openclaw-binding (run /doey-openclaw-connect first)"

# Prereq 2: bridge binary must exist (W4.1 deliverable).
BIN="${PROJ_DIR}/tui/openclaw-bridge"
[ -x "$BIN" ] || skip "openclaw-bridge binary missing at $BIN — run: cd tui && go build -o openclaw-bridge ./cmd/openclaw-bridge"

# Prereq 3: HMAC secret must be readable from openclaw.conf.
CONF="$HOME/.config/doey/openclaw.conf"
[ -f "$CONF" ] || skip "openclaw.conf missing"
SECRET=$(grep '^bridge_hmac_secret=' "$CONF" 2>/dev/null | cut -d= -f2-) || SECRET=""
[ -n "$SECRET" ] || skip "bridge_hmac_secret unset in openclaw.conf"

# Prereq 4: python3 (for HMAC) — graceful skip if absent.
command -v python3 >/dev/null 2>&1 || skip "python3 not available for HMAC signing"

# Runtime queue path.
PROJ_NAME=$(basename "$PROJ_DIR")
RT="/tmp/doey/${PROJ_NAME}"
mkdir -p "$RT" 2>/dev/null || true

QUEUE="${RT}/inbound-queue.jsonl"
IDLE_MARK="${RT}/boss-idle"
PASTE_LOG="${RT}/openclaw-paste.log"

# We cannot consume into a real Boss pane from this probe, so we look for
# the bridge's paste sentinel file. If the bridge writes nothing observable,
# we cannot fairly time the round-trip — skip rather than false-fail.
[ -w "$RT" ] || skip "runtime dir $RT not writable"

# Stub gateway response: hand-craft a JSON line with HMAC + nonce.
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
TS=$(date +%s)
BODY='{"thread_id":"probe-thread","reply_msg_id":"probe-reply","content":"hello"}'

SIG=$(SECRET="$SECRET" BODY="$BODY" NONCE="$NONCE" TS="$TS" python3 - <<'PY'
import hmac, hashlib, os, sys
secret = os.environ["SECRET"].encode()
msg = (os.environ["NONCE"] + "." + os.environ["TS"] + "." + os.environ["BODY"]).encode()
sys.stdout.write(hmac.new(secret, msg, hashlib.sha256).hexdigest())
PY
)

LINE=$(printf '{"nonce":"%s","ts":%s,"sig":"%s","body":%s}' "$NONCE" "$TS" "$SIG" "$BODY")

# T0: write inbound + idle-edge.
START_NS=$(date +%s%N 2>/dev/null || echo "")
[ -n "$START_NS" ] || skip "date +%s%N not supported (BSD date) — needs GNU coreutils"

printf '%s\n' "$LINE" >> "$QUEUE"
touch "$IDLE_MARK"

# Poll for paste sentinel up to 2s.
DEADLINE_NS=$((START_NS + 2000000000))
DELIVERED=0
while :; do
  NOW_NS=$(date +%s%N)
  if [ -f "$PASTE_LOG" ] && grep -q "probe-reply" "$PASTE_LOG" 2>/dev/null; then
    DELIVERED=1
    END_NS="$NOW_NS"
    break
  fi
  [ "$NOW_NS" -ge "$DEADLINE_NS" ] && break
  sleep 0.05 2>/dev/null || sleep 1
done

if [ "$DELIVERED" = "0" ]; then
  # Cannot time a delivery that never arrived. If components are wired this
  # is a hard fail; otherwise skip with a clear reason.
  PIDF="${RT}/openclaw-bridge.pid"
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    echo "FAIL: bridge running but paste sentinel never observed within 2s"
    exit 1
  fi
  skip "bridge not running and paste sentinel never appeared — pipe not yet wired"
fi

DELTA_NS=$((END_NS - START_NS))
DELTA_MS=$((DELTA_NS / 1000000))
echo "round-trip latency: ${DELTA_MS}ms"

if [ "$DELTA_MS" -lt 2000 ]; then
  echo "PASS: round-trip < 2000ms"
  exit 0
fi
echo "FAIL: round-trip ${DELTA_MS}ms exceeded 2000ms gate"
exit 1
