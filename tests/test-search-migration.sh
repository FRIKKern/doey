#!/usr/bin/env bash
# test-search-migration.sh — verifies the v4 search migration is idempotent
# and that the expected tables/indexes/triggers exist after store.Open.
#
# Strategy:
#   1. Bootstrap a fresh project dir; opening the store applies the v4 schema.
#   2. Snapshot the schema (sorted CREATE statements).
#   3. Re-open the store; snapshot again.
#   4. Diff — must be empty.
#   5. Confirm the named tables/indexes/triggers are present.
set -euo pipefail

NAME="test-search-migration"

if ! command -v doey-ctl >/dev/null 2>&1; then
  echo "$NAME: skipped (doey-ctl not on PATH)"
  exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "$NAME: skipped (sqlite3 not installed)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/proj"
mkdir -p "$PROJ/.doey"
DB="$PROJ/.doey/doey.db"

# First open — applies migration.
RT="$TMP/runtime"
mkdir -p "$RT"
doey-ctl migrate --project-dir "$PROJ" --runtime "$RT" >/dev/null 2>&1 || {
  echo "$NAME: FAIL: initial migrate failed"
  exit 1
}

snapshot_schema() {
  sqlite3 "$DB" \
    "SELECT type||':'||name||':'||COALESCE(sql,'') FROM sqlite_master \
     WHERE name NOT LIKE 'sqlite_%' \
     ORDER BY type, name;"
}

snap1="$(snapshot_schema)"

# Second open — must NOT alter the schema.
doey-ctl migrate --project-dir "$PROJ" --runtime "$RT" >/dev/null 2>&1 || {
  echo "$NAME: FAIL: second migrate failed"
  exit 1
}

snap2="$(snapshot_schema)"

if [ "$snap1" != "$snap2" ]; then
  echo "$NAME: FAIL: schema changed across re-open (migration not idempotent)"
  diff <(printf '%s\n' "$snap1") <(printf '%s\n' "$snap2") | head -20
  exit 1
fi

# Confirm the v4 search artifacts exist.
required_tables="task_urls tasks_fts messages_fts"
for t in $required_tables; do
  count=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type IN ('table','view') AND name='$t';")
  if [ "$count" != "1" ]; then
    echo "$NAME: FAIL: missing table $t"
    exit 1
  fi
done

required_indexes="idx_task_urls_host_ts idx_task_urls_task_id idx_task_urls_task_field"
for i in $required_indexes; do
  count=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='$i';")
  if [ "$count" != "1" ]; then
    echo "$NAME: FAIL: missing index $i"
    exit 1
  fi
done

required_triggers="tasks_fts_ai tasks_fts_ad tasks_fts_au messages_fts_ai messages_fts_ad messages_fts_au"
for tr in $required_triggers; do
  count=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='$tr';")
  if [ "$count" != "1" ]; then
    echo "$NAME: FAIL: missing trigger $tr"
    exit 1
  fi
done

# Fresh-install gate: a brand-new project survives backfill + first query
# without error (no rows to extract — should still exit cleanly).
FRESH="$TMP/fresh"
FRESHRT="$TMP/fresh-rt"
mkdir -p "$FRESH/.doey" "$FRESHRT"
doey-ctl migrate --project-dir "$FRESH" --runtime "$FRESHRT" >/dev/null 2>&1 || {
  echo "$NAME: FAIL: fresh migrate"
  exit 1
}
doey-ctl search --project-dir "$FRESH" --backfill-urls >/dev/null 2>&1 || {
  echo "$NAME: FAIL: fresh backfill"
  exit 1
}
# Fresh DB has no tasks → search exits 1 ("no results") which is expected.
doey-ctl search --project-dir "$FRESH" 'anything' >/dev/null 2>&1 || true

echo "PASS: $NAME"
