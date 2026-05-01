#!/usr/bin/env bash
# test-search-fts.sh — FTS5 index integrity for tasks_fts and messages_fts.
# Inserts known rows, runs sanitized queries, and confirms hit counts match.
# Exercises:
#   - exact-token match
#   - prefix / phrase match
#   - special-character query (sanitizer must NOT crash; tokens become phrases)
#   - operator words ("AND", "OR", "NOT") become literal phrases via #664 fix
set -euo pipefail

NAME="test-search-fts"

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
# Empty runtime keeps migrate from importing stale messages/statuses from
# the developer's real /tmp/doey/<project>/ — we only want the schema.
doey-ctl migrate --project-dir "$PROJ" --runtime "$RT" >/dev/null 2>&1

# Insert tasks via SQL so we control the IDs and content. The tasks_fts_ai
# trigger keeps the FTS shadow table in sync.
sqlite3 "$DB" <<'SQL'
INSERT INTO tasks (id, title, description, shortname, status, type, created_by, created_at, updated_at)
  VALUES
  (9001, 'pineapple deployment', 'rollout of the new pineapple service', 'pineapple', 'pending', 'task', 'test', strftime('%s','now'), strftime('%s','now')),
  (9002, 'banana migration',     'shift bananas into cold storage',     'banana',    'pending', 'task', 'test', strftime('%s','now'), strftime('%s','now')),
  (9003, 'pineapple regression', 'the pineapple test suite is flaky',   'pine-fix',  'pending', 'task', 'test', strftime('%s','now'), strftime('%s','now'));

INSERT INTO messages (id, from_pane, to_pane, subject, body, read, created_at)
  VALUES
  (5001, '0.1','0.2','tropical update', 'pineapple shipment arrived',                      0, strftime('%s','now')),
  (5002, '0.1','0.2','operator pun',    'AND OR NOT pineapple please',                     0, strftime('%s','now')),
  (5003, '0.2','0.1','special chars',   'release v1.2.3 (the "stable" tag) -- pineapple!', 0, strftime('%s','now'));
SQL

assert_count() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" != "$expected" ]; then
    echo "$NAME: FAIL: $label — expected $expected hits, got $actual"
    exit 1
  fi
}

# Exact-token match across tasks (2 rows mention pineapple in title/desc/shortname).
n=$(doey-ctl search --project-dir "$PROJ" --json 'pineapple' | grep -c '"task_id"' || true)
assert_count "tasks: pineapple" 2 "$n"

# Single-word match on description-only tokens.
n=$(doey-ctl search --project-dir "$PROJ" --json 'flaky' | grep -c '"task_id"' || true)
assert_count "tasks: flaky" 1 "$n"

# Phrase / multi-token (implicit AND). Both tokens appear in task 9001 only
# ("pineapple deployment"); 9002 has neither, 9003 has only one.
n=$(doey-ctl search --project-dir "$PROJ" --json 'pineapple deployment' | grep -c '"task_id"' || true)
assert_count "tasks: pineapple deployment (AND)" 1 "$n"

# Message FTS — pineapple appears in 3 message bodies.
n=$(doey-ctl search --project-dir "$PROJ" --type message --json 'pineapple' | grep -c '"task_id"' || true)
assert_count "messages: pineapple" 3 "$n"

# Sanitization: operator words must NOT trigger FTS5 syntax errors. Per #664
# they're wrapped as quoted phrases — only msg 5002 contains the literal
# token "AND" in its body.
n=$(doey-ctl search --project-dir "$PROJ" --type message --json 'AND' | grep -c '"task_id"' || true)
assert_count "messages: literal AND" 1 "$n"

# Special characters must not blow up the tokenizer. Just confirm the call
# succeeds (exit 0 if hit, exit 1 if no hit — both are "no error").
out=$(doey-ctl search --project-dir "$PROJ" --type message --json 'v1.2.3' 2>&1) || true
case "$out" in
  *"unrecognized"* | *"syntax error"* | *"fts5: syntax"*)
    echo "$NAME: FAIL: special-char query crashed FTS5: $out"
    exit 1
    ;;
esac

# msg search subcommand happy-path.
n=$(doey-ctl msg search --project-dir "$PROJ" --json 'pineapple' | grep -c '"id"' || true)
if [ "$n" -lt 3 ]; then
  echo "$NAME: FAIL: msg search expected >=3 results for 'pineapple', got $n"
  exit 1
fi

echo "PASS: $NAME"
