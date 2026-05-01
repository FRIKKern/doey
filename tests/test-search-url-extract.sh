#!/usr/bin/env bash
# test-search-url-extract.sh — URL extraction round-trip.
# Inserts a task description containing 2 URLs, runs --backfill-urls so the
# extractor walks the task, then verifies:
#   - task_urls is populated with both URLs (kind labelled correctly)
#   - `doey-ctl search --url <substring>` returns the row
#
# Note: the live URL extractor processes tasks/subtasks/task_log fields
# (per tui/cmd/doey-ctl/search_cmd.go runBackfillURLs). Messages do NOT have
# their own URL extraction in v1; this test exercises the actual code path.
set -euo pipefail

NAME="test-search-url-extract"

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

RT="$TMP/runtime"
mkdir -p "$RT"
doey-ctl migrate --project-dir "$PROJ" --runtime "$RT" >/dev/null 2>&1

# Insert a task whose description contains 2 URLs (different hosts).
sqlite3 "$DB" <<'SQL'
INSERT INTO tasks (id, title, description, shortname, status, type, created_by, created_at, updated_at)
  VALUES (8001,
          'doc links',
          'see https://github.com/doey-cli/doey/issues/659 and https://figma.com/file/abc123 for context',
          'doc-links',
          'pending', 'task', 'test',
          strftime('%s','now'), strftime('%s','now'));
SQL

# Re-extract URLs (the INSERT trigger doesn't extract; backfill does).
doey-ctl search --project-dir "$PROJ" --backfill-urls >/dev/null 2>&1 || {
  echo "$NAME: FAIL: backfill-urls"
  exit 1
}

# task_urls must have 2 rows for task 8001.
n=$(sqlite3 "$DB" "SELECT count(*) FROM task_urls WHERE task_id=8001 AND field='description';")
if [ "$n" != "2" ]; then
  echo "$NAME: FAIL: expected 2 url rows for task 8001/description, got $n"
  sqlite3 "$DB" "SELECT url, host, kind FROM task_urls WHERE task_id=8001;" >&2
  exit 1
fi

# Hosts must be classified.
gh=$(sqlite3 "$DB" "SELECT kind FROM task_urls WHERE task_id=8001 AND host='github.com';")
if [ "$gh" != "github" ]; then
  echo "$NAME: FAIL: expected kind=github for github.com, got '$gh'"
  exit 1
fi
fg=$(sqlite3 "$DB" "SELECT kind FROM task_urls WHERE task_id=8001 AND host='figma.com';")
if [ "$fg" != "figma" ]; then
  echo "$NAME: FAIL: expected kind=figma for figma.com, got '$fg'"
  exit 1
fi

# URL substring search must return the task.
out=$(doey-ctl search --project-dir "$PROJ" --url 'github' --json 2>&1)
if ! printf '%s' "$out" | grep -qE '"task_id":[[:space:]]*8001'; then
  echo "$NAME: FAIL: --url github did not return task 8001:"
  printf '%s\n' "$out" >&2
  exit 1
fi

out=$(doey-ctl search --project-dir "$PROJ" --url 'figma' --json 2>&1)
if ! printf '%s' "$out" | grep -qE '"task_id":[[:space:]]*8001'; then
  echo "$NAME: FAIL: --url figma did not return task 8001:"
  printf '%s\n' "$out" >&2
  exit 1
fi

# Idempotency: re-running backfill must NOT duplicate rows.
doey-ctl search --project-dir "$PROJ" --backfill-urls >/dev/null 2>&1
n=$(sqlite3 "$DB" "SELECT count(*) FROM task_urls WHERE task_id=8001 AND field='description';")
if [ "$n" != "2" ]; then
  echo "$NAME: FAIL: re-backfill duplicated rows ($n != 2)"
  exit 1
fi

echo "PASS: $NAME"
