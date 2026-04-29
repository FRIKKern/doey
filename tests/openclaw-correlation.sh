#!/usr/bin/env bash
# tests/openclaw-correlation.sh
# Permissive correlation: oc_correlation_resolve marks the matching open row
# as resolved with the reply_msg_id appended. Idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPROOT=$(mktemp -d -t oc-corr.XXXXXX)
trap 'rm -rf "$TMPROOT" 2>/dev/null || true' EXIT INT TERM

PROJ="${TMPROOT}/proj"
mkdir -p "${PROJ}/.doey"
cat > "${PROJ}/.doey/openclaw-binding" <<EOF
bound_at=2026-04-29T00:00:00Z
gateway_url=https://example.invalid
EOF

export DOEY_PROJECT_DIR="$PROJ"
# shellcheck source=/dev/null
. "${REPO_ROOT}/shell/doey-openclaw.sh"

T1=$(oc_thread_get_or_create T1)
T2=$(oc_thread_get_or_create T2)
TSV="${PROJ}/.doey/openclaw-threads.tsv"

echo "T1 thread: $T1"
echo "T2 thread: $T2"
[ -n "$T1" ] && [ -n "$T2" ] || { echo "FAIL: empty thread ids"; exit 1; }
[ "$T1" != "$T2" ] || { echo "FAIL: T1 and T2 share an id"; exit 1; }

# Resolve T1.
oc_correlation_resolve "$T1" "reply_abc"

# Verify T1 row now resolved with resolved_by=reply_abc.
T1_LINE=$(awk -F'\t' -v tid="$T1" '$2==tid {print; exit}' "$TSV")
T2_LINE=$(awk -F'\t' -v tid="$T2" '$2==tid {print; exit}' "$TSV")

echo "T1 row after resolve: $T1_LINE"
echo "T2 row after resolve: $T2_LINE"

T1_STATUS=$(printf '%s' "$T1_LINE" | awk -F'\t' '{print $4}')
T1_RESOLVED_BY=$(printf '%s' "$T1_LINE" | awk -F'\t' '{print $5}')
T2_STATUS=$(printf '%s' "$T2_LINE" | awk -F'\t' '{print $4}')

fail=0
[ "$T1_STATUS" = "resolved" ] || { echo "FAIL: T1 status=$T1_STATUS (want resolved)"; fail=1; }
[ "$T1_RESOLVED_BY" = "reply_abc" ] || { echo "FAIL: T1 resolved_by=$T1_RESOLVED_BY (want reply_abc)"; fail=1; }
[ "$T2_STATUS" = "open" ] || { echo "FAIL: T2 status=$T2_STATUS (want open — should be untouched)"; fail=1; }

# Idempotency: resolving an already-resolved thread is a no-op success.
if oc_correlation_resolve "$T1" "reply_xyz"; then
  T1_LINE2=$(awk -F'\t' -v tid="$T1" '$2==tid {print; exit}' "$TSV")
  T1_RB2=$(printf '%s' "$T1_LINE2" | awk -F'\t' '{print $5}')
  if [ "$T1_RB2" = "reply_abc" ]; then
    echo "OK: idempotent resolve preserved original resolved_by"
  else
    echo "FAIL: idempotent resolve mutated row (resolved_by=$T1_RB2)"
    fail=1
  fi
else
  echo "FAIL: idempotent resolve returned non-zero"
  fail=1
fi

if [ "$fail" = "0" ]; then
  echo "PASS: correlation"
  exit 0
fi
echo "--- TSV ---"
cat "$TSV"
exit 1
