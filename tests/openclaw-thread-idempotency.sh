#!/usr/bin/env bash
# tests/openclaw-thread-idempotency.sh
# Concurrent-safety test: 10 racing oc_thread_get_or_create calls per task_id
# must produce exactly ONE TSV row per task and all callers must see the
# SAME thread_id.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPROOT=$(mktemp -d -t oc-idem.XXXXXX)
trap 'rm -rf "$TMPROOT" 2>/dev/null || true' EXIT INT TERM

PROJ="${TMPROOT}/proj"
mkdir -p "${PROJ}/.doey"
# Fake binding so helpers don't refuse.
cat > "${PROJ}/.doey/openclaw-binding" <<EOF
bound_at=2026-04-29T00:00:00Z
gateway_url=https://example.invalid
legacy_discord_suppressed=false
bound_user_ids=
recorded_daemon_version=0.1.0
min_required_version=0.1.0
EOF

export DOEY_PROJECT_DIR="$PROJ"
# shellcheck source=/dev/null
. "${REPO_ROOT}/shell/doey-openclaw.sh"

OUT="${TMPROOT}/out"
mkdir -p "$OUT"

fire() {
  local tag="$1" task="$2"
  oc_thread_get_or_create "$task" > "${OUT}/${tag}.txt" 2>/dev/null
}

i=0
while [ "$i" -lt 10 ]; do
  fire "T1-$i" "T1" &
  fire "T2-$i" "T2" &
  i=$((i+1))
done
wait

# Collect IDs
T1_IDS=$(cat "${OUT}"/T1-*.txt | sort -u)
T2_IDS=$(cat "${OUT}"/T2-*.txt | sort -u)

T1_UNIQ=$(printf '%s\n' "$T1_IDS" | grep -c . || true)
T2_UNIQ=$(printf '%s\n' "$T2_IDS" | grep -c . || true)

TSV="${PROJ}/.doey/openclaw-threads.tsv"
ROWS=$(grep -c . "$TSV" 2>/dev/null || echo 0)
T1_ROWS=$(awk -F'\t' '$1=="T1"' "$TSV" | grep -c . || true)
T2_ROWS=$(awk -F'\t' '$1=="T2"' "$TSV" | grep -c . || true)

fail=0
echo "T1 unique ids returned to callers: $T1_UNIQ (expect 1)"
echo "T2 unique ids returned to callers: $T2_UNIQ (expect 1)"
echo "TSV total rows: $ROWS (expect 2)"
echo "TSV T1 rows: $T1_ROWS (expect 1)"
echo "TSV T2 rows: $T2_ROWS (expect 1)"

[ "$T1_UNIQ" = "1" ] || { echo "FAIL: T1 callers saw multiple thread_ids"; fail=1; }
[ "$T2_UNIQ" = "1" ] || { echo "FAIL: T2 callers saw multiple thread_ids"; fail=1; }
[ "$T1_ROWS" = "1" ] || { echo "FAIL: T1 produced $T1_ROWS rows"; fail=1; }
[ "$T2_ROWS" = "1" ] || { echo "FAIL: T2 produced $T2_ROWS rows"; fail=1; }

if [ "$fail" = "0" ]; then
  echo "PASS: thread idempotency"
  exit 0
fi
echo "--- TSV contents ---"
cat "$TSV" || true
exit 1
