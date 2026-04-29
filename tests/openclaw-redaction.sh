#!/usr/bin/env bash
# tests/openclaw-redaction.sh — verify openclaw-redact.sh strips Authorization
# headers and token= parameters from `set -x` traces. Greppable: any canary
# leaking through fails the test loudly.
set -euo pipefail

_here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../shell/openclaw-redact.sh
source "$_here/../shell/openclaw-redact.sh"

CANARY_H='ZZZZ-CANARY-DO-NOT-LEAK-ZZZZ'
CANARY_T='ZZZZ-PARAM-CANARY-ZZZZ'

tmp=$(mktemp "${TMPDIR:-/tmp}/openclaw-redaction.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# Run a representative `set -x` block with canary credentials. The block
# redirects its stderr (where xtrace goes) through the redaction filter and
# captures the result to $tmp.
{
  set -x
  url='https://example.invalid/api'
  hdr="Authorization: Bearer $CANARY_H"
  body="token=$CANARY_T&kind=question"
  flag="--header Authorization:Bearer-$CANARY_H"
  : "$url" "$hdr" "$body" "$flag"
  set +x
} 2>&1 1>/dev/null | _oc_redact_filter > "$tmp"

# Greppable assertion #1: NO canary substring may appear in the redacted trace.
if matches=$(grep -nE "$CANARY_H|$CANARY_T" "$tmp"); then
  echo "[FAIL] canary leaked through redaction wrapper:" >&2
  printf '%s\n' "$matches" >&2
  echo "------ full trace: ------" >&2
  cat "$tmp" >&2
  exit 1
fi

# Sanity assertion #2: the filter actually ran — we should see <REDACTED>.
if ! grep -q '<REDACTED>' "$tmp"; then
  echo "[FAIL] expected <REDACTED> markers not found — filter may not have engaged" >&2
  echo "------ full trace: ------" >&2
  cat "$tmp" >&2
  exit 1
fi

echo "[PASS] no canary in trace; redaction applied"
echo "------ redacted trace excerpt (first 12 lines) ------"
sed -n '1,12p' "$tmp"

# Also exercise the self-test for good measure.
if oc_redact_self_test; then
  echo "[PASS] oc_redact_self_test"
else
  echo "[FAIL] oc_redact_self_test" >&2
  exit 1
fi
