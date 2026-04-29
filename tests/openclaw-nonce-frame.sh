#!/usr/bin/env bash
# tests/openclaw-nonce-frame.sh — round-trip BEGIN/END frame parsing.
set -euo pipefail

_fail=0
_pass=0
_assert() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "[PASS] $label"
    _pass=$(( _pass + 1 ))
  else
    echo "[FAIL] $label"
    printf '        expected: %s\n' "$expected"
    printf '        actual:   %s\n' "$actual"
    _fail=$(( _fail + 1 ))
  fi
}

# WrapBody: emit "BEGIN nonce=<n>\n<body>\nEND nonce=<n>\n"
wrap_body() {
  local nonce="$1" body="$2"
  printf 'BEGIN nonce=%s\n%s\nEND nonce=%s\n' "$nonce" "$body" "$nonce"
}

# ParseFramed: extract begin nonce, end nonce, body. Returns 0 on match.
# Outputs: line1=begin, line2=end, line3..=body (caller distinguishes).
parse_framed() {
  local input="$1"
  local begin end body
  begin=$(printf '%s' "$input" | grep -oE 'BEGIN nonce=[a-fA-F0-9]+' | head -1 | sed 's/BEGIN nonce=//')
  end=$(printf '%s' "$input" | grep -oE 'END nonce=[a-fA-F0-9]+' | tail -1 | sed 's/END nonce=//')
  body=$(printf '%s' "$input" | awk '
    /^BEGIN nonce=/ { capture=1; next }
    /^END nonce=/   { capture=0 }
    capture==1      { print }
  ')
  if [ -z "$begin" ] || [ -z "$end" ] || [ "$begin" != "$end" ]; then
    return 1
  fi
  # Strip the trailing \n awk may have added past last body line.
  printf '%s\n%s\n%s' "$begin" "$end" "$body"
  return 0
}

# ── Test 1: round-trip ────────────────────────────────────────────────
NONCE="abcdef0123456789"
BODY=$'hello\nworld\nthird line'
WRAPPED=$(wrap_body "$NONCE" "$BODY")
if PARSED=$(parse_framed "$WRAPPED"); then
  begin_got=$(printf '%s\n' "$PARSED" | sed -n '1p')
  end_got=$(printf '%s\n' "$PARSED"   | sed -n '2p')
  body_got=$(printf '%s\n' "$PARSED"  | sed -n '3,$p')
  _assert "round-trip begin nonce"  "$NONCE" "$begin_got"
  _assert "round-trip end nonce"    "$NONCE" "$end_got"
  _assert "round-trip body recovery" "$BODY" "$body_got"
else
  _assert "round-trip parse_framed succeeds" "0" "1"
fi

# ── Test 2: mismatched nonces rejected ────────────────────────────────
BAD=$'BEGIN nonce=aaaa\nfoo\nEND nonce=bbbb\n'
if parse_framed "$BAD" >/dev/null 2>&1; then
  _assert "mismatched BEGIN/END rejected" "non-zero" "0"
else
  echo "[PASS] mismatched BEGIN/END rejected"
  _pass=$(( _pass + 1 ))
fi

# ── Test 3: missing END rejected ──────────────────────────────────────
INCOMPLETE=$'BEGIN nonce=cafebabe\nfoo\n'
if parse_framed "$INCOMPLETE" >/dev/null 2>&1; then
  _assert "missing END rejected" "non-zero" "0"
else
  echo "[PASS] missing END rejected"
  _pass=$(( _pass + 1 ))
fi

echo "─────────────────────"
echo "Passed: $_pass   Failed: $_fail"
[ "$_fail" -eq 0 ]
