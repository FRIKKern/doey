#!/usr/bin/env bash
# Stop hook: capture worker results and write completion event (async)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_hook
_DOEY_HOOK_NAME="stop-results"
type _debug_hook_entry >/dev/null 2>&1 && _debug_hook_entry

is_worker || exit 0

# Ensure tasks directory exists for crash-recovery prompt storage
mkdir -p "$RUNTIME_DIR/tasks" 2>/dev/null || true

RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
TMPFILE=""
trap '[ -n "${TMPFILE:-}" ] && rm -f "$TMPFILE" 2>/dev/null' EXIT

OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -80 2>/dev/null) || OUTPUT=""
[ -z "$OUTPUT" ] && _log_error "HOOK_ERROR" "tmux capture-pane returned empty" "pane=$PANE"

# Get files changed by this worker via git
PROJECT_DIR="${DOEY_TEAM_DIR:-}"
FILES_LIST=""
if [ -n "$PROJECT_DIR" ]; then
  if command -v timeout >/dev/null 2>&1; then
    FILES_LIST=$(cd "$PROJECT_DIR" 2>/dev/null && timeout 2 git diff --name-only HEAD 2>/dev/null | head -20) || FILES_LIST=""
  else
    _tmpfile=$(mktemp)
    ( cd "$PROJECT_DIR" 2>/dev/null && git diff --name-only HEAD > "$_tmpfile" 2>/dev/null ) &
    _git_pid=$!
    ( sleep 2; kill "$_git_pid" 2>/dev/null ) &
    _killer=$!
    wait "$_git_pid" 2>/dev/null || true
    kill "$_killer" 2>/dev/null; wait "$_killer" 2>/dev/null || true
    FILES_LIST=$(head -20 "$_tmpfile" 2>/dev/null) || FILES_LIST=""
    rm -f "$_tmpfile"
  fi
fi
[ -n "$PROJECT_DIR" ] && [ -z "$FILES_LIST" ] && _log "stop-results: git diff empty (no file changes)" || true
FILES_JSON="[]"
if [ -n "$FILES_LIST" ]; then
  FILES_JSON=$(echo "$FILES_LIST" | jq -R '.' | jq -s '.' 2>/dev/null) || FILES_JSON="[]"
fi

FILTERED=""
STATUS="done"
TOOL_COUNT=0
while IFS= read -r line; do
  # Count tool calls
  case "$line" in
    *"Read("*|*"Edit("*|*"Write("*|*"Bash("*|*"Grep("*|*"Glob("*|*"Agent("*) TOOL_COUNT=$((TOOL_COUNT + 1)) ;;
  esac
  # UI chrome filters — update if Claude Code output format changes
  case "$line" in
    *"❯"*|*"───"*|*"Ctx █"*|*"bypass permissions"*|*"shift+tab"*|*"MCP server"*|*/doctor*) continue ;;
  esac
  FILTERED="${FILTERED}${line}${NL}"
  if [ "$STATUS" = "done" ]; then
    case "$line" in
      *[Ee]rror*|*ERROR*|*[Ff]ailed*|*FAILED*|*[Ee]xception*|*EXCEPTION*) STATUS="error" ;;
    esac
  fi
done <<HEREDOC_EOF
$OUTPUT
HEREDOC_EOF

PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"
LAST_JSON=$(printf '%s' "$FILTERED" | jq -Rs '.' 2>/dev/null) || \
  LAST_JSON=$(printf '%s' "$FILTERED" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
  LAST_JSON='""'
TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'

TMPFILE=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null)
if [ -z "$TMPFILE" ] || [ ! -f "$TMPFILE" ]; then
  echo "[WARN] mktemp failed in $(basename "$0") — writing non-atomically" >> "${RUNTIME_DIR}/doey-warnings.log" 2>/dev/null
  _log_error "HOOK_ERROR" "mktemp failed, using non-atomic write" "result_file=$RESULT_FILE"
  TMPFILE="$RESULT_FILE"
fi
cat > "$TMPFILE" <<EOF
{
  "pane": "$WINDOW_INDEX.$PANE_INDEX",
  "pane_id": "${DOEY_PANE_ID:-unknown}",
  "full_pane_id": "${DOEY_FULL_PANE_ID:-unknown}",
  "title": $TITLE_JSON,
  "status": "$STATUS",
  "timestamp": $(date +%s),
  "files_changed": $FILES_JSON,
  "tool_calls": $TOOL_COUNT,
  "last_output": $LAST_JSON
}
EOF
[ "$TMPFILE" != "$RESULT_FILE" ] && mv "$TMPFILE" "$RESULT_FILE"
TMPFILE=""
_log "stop-results: wrote result to $RESULT_FILE (status=$STATUS, tools=$TOOL_COUNT)"

_FILES_COUNT=0
[ -n "$FILES_LIST" ] && _FILES_COUNT=$(printf '%s\n' "$FILES_LIST" | wc -l | tr -d ' ')
type _debug_log >/dev/null 2>&1 && _debug_log lifecycle "result_captured" "files_changed=${_FILES_COUNT}" "tool_calls=${TOOL_COUNT}"

# Completion event for Session Manager
COMPLETION="${RUNTIME_DIR}/status/completion_pane_${WINDOW_INDEX}_${PANE_INDEX}"
cat > "${COMPLETION}.tmp" <<COMPLETE
PANE_INDEX="$PANE_INDEX"
PANE_TITLE="$PANE_TITLE"
STATUS="$STATUS"
TIMESTAMP=$(date +%s)
COMPLETE
mv "${COMPLETION}.tmp" "$COMPLETION"
[ ! -f "$COMPLETION" ] && _log_error "HOOK_ERROR" "Completion event file not written" "path=$COMPLETION"

# Wake Session Manager
touch "${RUNTIME_DIR}/status/sm_trigger" 2>/dev/null || true

exit 0
