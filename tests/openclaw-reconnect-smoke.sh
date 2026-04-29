#!/usr/bin/env bash
# tests/openclaw-reconnect-smoke.sh — Phase 4 subtask 4 dedup contract.
#
# Verifies that consecutive calls to `oc_reconnect_status_task` produce
# exactly ONE status task (shortname=openclaw-reconnect-status) with N
# log entries — never N tasks. Runs in file-only mode by default
# (no .doey/doey.db) so it doesn't touch the live project DB.
#
# Skips with exit 77 if the doey CLI or python3 are unavailable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"

if ! command -v doey >/dev/null 2>&1; then
  echo "SKIP: doey CLI not on PATH"
  exit 77
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available"
  exit 77
fi

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

PROJ="${TMPROOT}/proj"
mkdir -p "${PROJ}/.doey/tasks"
echo "1" > "${PROJ}/.doey/tasks/.next_id"

# Source the helper module. _oc_project_dir respects DOEY_PROJECT_DIR.
export DOEY_PROJECT_DIR="$PROJ"
# shellcheck disable=SC1091
source "${REPO_ROOT}/shell/doey-openclaw.sh"

# First reconnect — should CREATE.
id1=$(oc_reconnect_status_task "0.1.0" "0.1.0" "first reconnect body")
if [ -z "$id1" ]; then
  echo "FAIL: oc_reconnect_status_task returned empty id on first call"
  exit 1
fi

# Second reconnect — must REUSE.
id2=$(oc_reconnect_status_task "0.1.0" "0.1.0" "second reconnect body")
if [ -z "$id2" ]; then
  echo "FAIL: oc_reconnect_status_task returned empty id on second call"
  exit 1
fi
if [ "$id1" != "$id2" ]; then
  echo "FAIL: dedup broken — id1=$id1 id2=$id2 (expected equal)"
  exit 1
fi

# Third reconnect with version mismatch — still REUSE same task.
id3=$(oc_reconnect_status_task "0.1.0" "0.2.0" "third reconnect body — mismatch")
if [ "$id3" != "$id1" ]; then
  echo "FAIL: mismatch reconnect created new task — id1=$id1 id3=$id3"
  exit 1
fi

# Count open tasks with the dedup shortname.
match_count=$(doey task list --json --project-dir "$PROJ" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
sn = "openclaw-reconnect-status"
closed = {"done", "cancelled", "failed", "deferred", "skipped"}
def pick(t, *keys):
    for k in keys:
        if k in t and t[k] not in (None, ""):
            return t[k]
    return ""
count = 0
for t in d if isinstance(d, list) else []:
    if not isinstance(t, dict):
        continue
    if pick(t, "shortname", "Shortname") == sn and \
       str(pick(t, "status", "Status")).lower() not in closed:
        count += 1
print(count)
')
if [ "$match_count" != "1" ]; then
  echo "FAIL: expected exactly 1 open task with shortname openclaw-reconnect-status; got $match_count"
  exit 1
fi

# Verify three log entries exist on that task.
log_count=$(doey task log list --task-id "$id1" --json --project-dir "$PROJ" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
# Two shapes possible: list of entries (DB mode) or {decision_log: "..."} (file mode).
if isinstance(d, list):
    print(len(d))
elif isinstance(d, dict) and "decision_log" in d:
    raw = d["decision_log"] or ""
    parts = [p for p in raw.split("\\n") if p.strip()]
    print(len(parts))
else:
    print(0)
')
# In file mode the create stamp counts as 1 entry plus 3 progress = 4; in DB
# mode the bare log entries are exactly 3.
if [ "$log_count" -lt 3 ]; then
  echo "FAIL: expected at least 3 log entries on task $id1; got $log_count"
  exit 1
fi

echo "PASS: dedup contract holds (1 task, ${log_count} log entries) id=$id1"
exit 0
