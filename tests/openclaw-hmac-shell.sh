#!/usr/bin/env bash
# tests/openclaw-hmac-shell.sh — verify shell HMAC matches a reference impl
# (python3 hmac/hashlib). Confirms the canonical byte construction
#   message = body || 0x00 || ts_ascii_decimal
# matches what W4.2's Go side will compute.
set -euo pipefail

_here=$(cd "$(dirname "$0")" && pwd)
# Source the helper. We need DOEY_PROJECT_DIR set for runtime path helpers,
# but the HMAC functions don't actually touch the project dir.
DOEY_PROJECT_DIR="$_here/.." source "$_here/../shell/doey-openclaw.sh"

_fail=0
_pass=0
_assert() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "[PASS] $label"
    _pass=$(( _pass + 1 ))
  else
    echo "[FAIL] $label"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    _fail=$(( _fail + 1 ))
  fi
}

# ── Test 1: HMAC byte-for-byte vs python3 reference ───────────────────
SECRET_HEX="$(printf '0123456789abcdef%.0s' 1 2 3 4)"   # 64 hex chars = 32 bytes
BODY="hello, world\nmulti-line body"
TS="1700000000"

shell_mac=$(_oc_hmac_compute "$BODY" "$TS" "$SECRET_HEX")

if command -v python3 >/dev/null 2>&1; then
  ref_mac=$(SECRET_HEX="$SECRET_HEX" BODY="$BODY" TS="$TS" python3 -c '
import hmac, hashlib, os, binascii
secret = binascii.unhexlify(os.environ["SECRET_HEX"])
body = os.environ["BODY"].encode()
ts = os.environ["TS"].encode()
msg = body + b"\x00" + ts
print(hmac.new(secret, msg, hashlib.sha256).hexdigest())
')
  _assert "HMAC matches python3 reference" "$ref_mac" "$shell_mac"
else
  echo "[SKIP] python3 unavailable — cannot cross-verify"
fi

# ── Test 2: skew window enforcement ───────────────────────────────────
# Drop a temporary conf so _oc_hmac_verify has a secret to read.
_tmp_conf=$(mktemp)
printf 'bridge_hmac_secret=%s\n' "$SECRET_HEX" > "$_tmp_conf"
chmod 0600 "$_tmp_conf"
OPENCLAW_CONF="$_tmp_conf"

NOW=$(date +%s)
OK_TS="$NOW"
OK_MAC=$(_oc_hmac_compute "$BODY" "$OK_TS")
if _oc_hmac_verify "$BODY" "$OK_TS" "$OK_MAC"; then
  _assert "verify accepts in-window valid" "0" "0"
else
  _assert "verify accepts in-window valid" "0" "$?"
fi

OLD_TS=$(( NOW - 120 ))
OLD_MAC=$(_oc_hmac_compute "$BODY" "$OLD_TS")
if _oc_hmac_verify "$BODY" "$OLD_TS" "$OLD_MAC"; then
  _assert "verify rejects past-skew" "non-zero" "0"
else
  echo "[PASS] verify rejects past-skew"
  _pass=$(( _pass + 1 ))
fi

FUT_TS=$(( NOW + 120 ))
FUT_MAC=$(_oc_hmac_compute "$BODY" "$FUT_TS")
if _oc_hmac_verify "$BODY" "$FUT_TS" "$FUT_MAC"; then
  _assert "verify rejects future-skew" "non-zero" "0"
else
  echo "[PASS] verify rejects future-skew"
  _pass=$(( _pass + 1 ))
fi

# ── Test 3: tampered body fails verify ────────────────────────────────
if _oc_hmac_verify "tampered" "$OK_TS" "$OK_MAC"; then
  _assert "verify rejects tampered body" "non-zero" "0"
else
  echo "[PASS] verify rejects tampered body"
  _pass=$(( _pass + 1 ))
fi

trash "$_tmp_conf" 2>/dev/null || rm -f "$_tmp_conf"

echo "─────────────────────"
echo "Passed: $_pass   Failed: $_fail"
[ "$_fail" -eq 0 ]
