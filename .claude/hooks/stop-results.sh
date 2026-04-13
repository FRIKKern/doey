#!/usr/bin/env bash
# Stop hook: capture worker results and write completion event (async)
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "stop-results"

mkdir -p "${RUNTIME_DIR}/errors" 2>/dev/null || true
trap '_err=$?; printf "[%s] ERR in stop-results at line %s (exit %s)\n" "$(date +%H:%M:%S)" "$LINENO" "$_err" >> "${RUNTIME_DIR}/errors/errors.log" 2>/dev/null; exit 0' ERR

# Scrub common secret patterns from text. Reads stdin, writes scrubbed text to stdout.
# Bash 3.2 safe — pure sed pipeline. Worker 2 (summary) and Worker 4
# (last_output structure) must pipe any text field through this function before writing.
doey_scrub_secrets() {
  sed -E \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED:openai]/g' \
    -e 's/ghp_[A-Za-z0-9]{20,}/[REDACTED:github]/g' \
    -e 's/gho_[A-Za-z0-9]{20,}/[REDACTED:github]/g' \
    -e 's/ghu_[A-Za-z0-9]{20,}/[REDACTED:github]/g' \
    -e 's/ghs_[A-Za-z0-9]{20,}/[REDACTED:github]/g' \
    -e 's/ghr_[A-Za-z0-9]{20,}/[REDACTED:github]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED:slack]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED:aws-key]/g' \
    -e 's/Bearer [A-Za-z0-9._-]{20,}/Bearer [REDACTED:bearer]/g' \
    -e 's#[Aa][Ww][Ss][^=]{0,40}=[[:space:]]*["'"'"']?[A-Za-z0-9/+=]{40}#[REDACTED:aws-secret]#g' \
    -e 's/(API_KEY|SECRET|TOKEN|PASSWORD)[[:space:]]*=[[:space:]]*[^[:space:]]+/\1=[REDACTED:envvar]/g'
}

is_worker || exit 0

mkdir -p "$RUNTIME_DIR/tasks" 2>/dev/null || true

RESULT_FILE="$RUNTIME_DIR/results/pane_${WINDOW_INDEX}_${PANE_INDEX}.json"
TMPFILE=""
trap '[ -n "${TMPFILE:-}" ] && rm -f "$TMPFILE" 2>/dev/null' EXIT

_append_attachment() {
  local task_file="$1" att_path="$2"
  [ -f "$task_file" ] || return 0
  local current; current=$(grep '^TASK_ATTACHMENTS=' "$task_file" 2>/dev/null | head -1 | cut -d= -f2-) || current=""
  case "|${current}|" in *"|${att_path}|"*) return 0 ;; esac
  local new_val="${att_path}"; [ -n "$current" ] && new_val="${current}|${att_path}"
  local tmp_att="${task_file}.tmp.$$"
  if grep -q '^TASK_ATTACHMENTS=' "$task_file" 2>/dev/null; then
    sed "s|^TASK_ATTACHMENTS=.*|TASK_ATTACHMENTS=${new_val}|" "$task_file" > "$tmp_att" && mv "$tmp_att" "$task_file"
  else
    cp "$task_file" "$tmp_att" && echo "TASK_ATTACHMENTS=${new_val}" >> "$tmp_att" && mv "$tmp_att" "$task_file"
  fi
}

# capture-pane required: output archive, completion attachments, VERIFICATION_STEP lines,
# and heuristic tool counting have no structured alternative for full session output
OUTPUT=$(tmux capture-pane -t "$PANE" -p -S -80 2>/dev/null) || OUTPUT=""
[ -z "$OUTPUT" ] && _log_error "HOOK_ERROR" "tmux capture-pane returned empty" "pane=$PANE"

PROJECT_DIR=$(_resolve_project_dir)
FILES_LIST=""
if [ -n "$PROJECT_DIR" ]; then
  _to=""; command -v timeout >/dev/null 2>&1 && _to="timeout 2"; command -v gtimeout >/dev/null 2>&1 && _to="gtimeout 2"
  FILES_LIST=$(cd "$PROJECT_DIR" 2>/dev/null && $_to git diff --name-only HEAD 2>/dev/null | head -20) || FILES_LIST=""
  [ -z "$FILES_LIST" ] && _log "stop-results: git diff empty"
fi
FILES_JSON="[]"
if [ -n "$FILES_LIST" ]; then
  FILES_JSON=$(echo "$FILES_LIST" | jq -R '.' | jq -s '.' 2>/dev/null) || FILES_JSON="[]"
fi

FILTERED=""
STATUS="done"
TOOL_COUNT=0
_TOOL_NAMES_RAW=""   # newline list of tool names (one per call, for aggregation)
_FILE_EDITS_RAW=""   # newline list of files touched by Edit/Write
_error_line=""       # populated in Pass 2 when an error signature matches
# Pass 1: build FILTERED output, count tools, record tool/file-edit details
# No structured tool count exists — on-pre-tool-use.sh only tracks last tool name, not a count
while IFS= read -r line; do
  _tool_name=""
  case "$line" in
    *"Read("*)  _tool_name="Read" ;;
    *"Edit("*)  _tool_name="Edit" ;;
    *"Write("*) _tool_name="Write" ;;
    *"Bash("*)  _tool_name="Bash" ;;
    *"Grep("*)  _tool_name="Grep" ;;
    *"Glob("*)  _tool_name="Glob" ;;
    *"Agent("*) _tool_name="Agent" ;;
  esac
  if [ -n "$_tool_name" ]; then
    TOOL_COUNT=$((TOOL_COUNT + 1))
    _TOOL_NAMES_RAW="${_TOOL_NAMES_RAW}${_tool_name}${NL}"
    case "$_tool_name" in
      Edit|Write)
        _f=$(printf '%s' "$line" | sed -n "s/.*${_tool_name}(\\([^)]*\\)).*/\\1/p" | head -1)
        [ -n "$_f" ] && _FILE_EDITS_RAW="${_FILE_EDITS_RAW}${_f}${NL}"
        ;;
    esac
  fi
  case "$line" in
    *"❯"*|*"───"*|*"Ctx █"*|*"bypass permissions"*|*"shift+tab"*|*"MCP server"*|*/doctor*) continue ;;
  esac
  FILTERED="${FILTERED}${line}${NL}"
done <<HEREDOC_EOF
$OUTPUT
HEREDOC_EOF

# Scrub secrets from FILTERED before any downstream consumer sees it.
# All paths that read FILTERED (last_output JSON, completion attachment,
# verification step extraction) now get the redacted version.
FILTERED=$(printf '%s' "$FILTERED" | doey_scrub_secrets)

# Structured error check: read status file written by synchronous stop-status.sh
_status_from_file=$(_read_pane_status "$PANE_SAFE") || _status_from_file=""
if [ "$_status_from_file" = "ERROR" ]; then
  STATUS="error"
fi

# Pass 2: heuristic fallback — check last 8 lines for errors not caught by structured status
# (captures cases where worker "finished" but output contains error signals)
_tail_lines=$(printf '%s' "$FILTERED" | tail -8)
_found_error=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Skip known false-positive patterns
  case "$line" in
    *"startup hook"*|*"SessionStart"*|*"hook error"*) continue ;;
    *"_log_error"*|*"log_error"*) continue ;;
    *"ErrorBoundary"*|*"error.go"*|*"errors.ts"*|*"error.ts"*) continue ;;
    *"0 "*[Ff]ailed*|*"no "[Ee]rror*) continue ;;
    *"stop hooks"*) continue ;;
  esac
  case "$line" in
    *[Ee]rror*|*ERROR*|*[Ff]ailed*|*FAILED*|*[Ee]xception*|*EXCEPTION*) _found_error="true"; _error_line="$line"; break ;;
  esac
done <<HEREDOC_TAIL
$_tail_lines
HEREDOC_TAIL

# Positive completion signals override incidental error mentions
if [ "$_found_error" = "true" ]; then
  case "$_tail_lines" in
    *"completed"*|*"successfully"*|*"All tests passed"*|*"Done"*|*"Finished"*) _found_error=""; _error_line="" ;;
  esac
fi
[ "$_found_error" = "true" ] && STATUS="error"

# Read proof from structured proof file (workers write to $RUNTIME_DIR/proof/)
PROOF_TYPE=""
PROOF_CONTENT=""
_proof_file="${RUNTIME_DIR}/proof/${PANE_SAFE}.proof"
if [ -f "$_proof_file" ]; then
  _proof_line=$(grep '^PROOF_TYPE:' "$_proof_file" | tail -1) || true
  [ -n "$_proof_line" ] && PROOF_TYPE=$(printf '%s' "$_proof_line" | sed 's/^PROOF_TYPE:[[:space:]]*//')
  _proof_body=$(grep '^PROOF:' "$_proof_file" | tail -1) || true
  [ -n "$_proof_body" ] && PROOF_CONTENT=$(printf '%s' "$_proof_body" | sed 's/^PROOF:[[:space:]]*//')
fi

# ── Structured proof-of-success (v2) ──────────────────────────────
# Resolve task ID early for criteria lookup
_early_task_id="${DOEY_TASK_ID:-}"
[ -z "$_early_task_id" ] && _early_task_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.task_id" 2>/dev/null) || true

# Read success criteria from .task file if available
_CRITERIA=""
_verification_status=""
if [ -n "$_early_task_id" ] && [ -n "$PROJECT_DIR" ]; then
  _task_file="${PROJECT_DIR}/.doey/tasks/${_early_task_id}.task"
  if [ -f "$_task_file" ]; then
    _CRITERIA=$(grep '^TASK_SUCCESS_CRITERIA=' "$_task_file" 2>/dev/null | head -1 | cut -d= -f2-) || _CRITERIA=""
  fi
fi

# Build structured proof_of_success with per-criterion results
_criteria_json_arr=""
_auto_count=0
_human_count=0
_fail_count=0
_human_guides=""
_auto_output=""

# Timeout helper
_tmo=""
command -v timeout >/dev/null 2>&1 && _tmo="timeout 10"
command -v gtimeout >/dev/null 2>&1 && _tmo="gtimeout 10"

_add_criterion() {
  local crit="$1" stat="$2" evidence="$3" guide="${4:-}"
  local crit_esc; crit_esc=$(printf '%s' "$crit" | sed 's/\\/\\\\/g; s/"/\\"/g')
  local ev_esc; ev_esc=$(printf '%s' "$evidence" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | head -c 500)
  local guide_esc; guide_esc=$(printf '%s' "$guide" | sed 's/\\/\\\\/g; s/"/\\"/g')
  local entry="{\"criterion\":\"${crit_esc}\",\"status\":\"${stat}\",\"evidence\":\"${ev_esc}\""
  [ -n "$guide_esc" ] && entry="${entry},\"guide\":\"${guide_esc}\""
  entry="${entry}}"
  if [ -n "$_criteria_json_arr" ]; then
    _criteria_json_arr="${_criteria_json_arr},${entry}"
  else
    _criteria_json_arr="${entry}"
  fi
  case "$stat" in
    pass) _auto_count=$((_auto_count + 1)) ;;
    fail) _fail_count=$((_fail_count + 1)) ;;
    needs_human) _human_count=$((_human_count + 1))
      [ -n "$guide" ] && _human_guides="${_human_guides}${guide}${NL}" ;;
  esac
}

# Auto-verify built-in criteria from changed files
if [ -n "$PROJECT_DIR" ] && [ -n "$FILES_LIST" ]; then
  _has_go=""
  case "$FILES_LIST" in *.go*) _has_go="true" ;; esac
  [ -z "$_has_go" ] && [ -f "${PROJECT_DIR}/go.mod" ] && _has_go="true"

  if [ "$_has_go" = "true" ] && command -v go >/dev/null 2>&1; then
    _go_build_out=$(cd "$PROJECT_DIR" && ${_tmo} go build ./... 2>&1) && _go_build_rc=0 || _go_build_rc=$?
    _auto_output="${_auto_output}[go build] exit ${_go_build_rc}${NL}${_go_build_out}${NL}"
    if [ "$_go_build_rc" = "0" ]; then
      _add_criterion "go build passes" "pass" "exit 0"
    else
      _add_criterion "go build passes" "fail" "exit ${_go_build_rc}: ${_go_build_out}"
    fi

    _go_vet_out=$(cd "$PROJECT_DIR" && ${_tmo} go vet ./... 2>&1) && _go_vet_rc=0 || _go_vet_rc=$?
    _auto_output="${_auto_output}[go vet] exit ${_go_vet_rc}${NL}${_go_vet_out}${NL}"
    if [ "$_go_vet_rc" = "0" ]; then
      _add_criterion "go vet passes" "pass" "exit 0"
    else
      _add_criterion "go vet passes" "fail" "exit ${_go_vet_rc}: ${_go_vet_out}"
    fi
  fi

  _has_sh=""
  case "$FILES_LIST" in *.sh*) _has_sh="true" ;; esac

  if [ "$_has_sh" = "true" ]; then
    while IFS= read -r _shfile; do
      case "$_shfile" in *.sh) ;; *) continue ;; esac
      [ -f "${PROJECT_DIR}/${_shfile}" ] || continue
      _sh_out=$(bash -n "${PROJECT_DIR}/${_shfile}" 2>&1) && _sh_rc=0 || _sh_rc=$?
      _auto_output="${_auto_output}[bash -n ${_shfile}] exit ${_sh_rc}${NL}${_sh_out}${NL}"
      if [ "$_sh_rc" = "0" ]; then
        _add_criterion "bash -n ${_shfile}" "pass" "exit 0"
      else
        _add_criterion "bash -n ${_shfile}" "fail" "exit ${_sh_rc}: ${_sh_out}"
      fi
    done <<SHFILES_EOF
$FILES_LIST
SHFILES_EOF
  fi
fi

# Process task-defined success criteria (pipe-separated: "criterion1|criterion2|...")
if [ -n "$_CRITERIA" ]; then
  _remaining="$_CRITERIA"
  while [ -n "$_remaining" ]; do
    case "$_remaining" in
      *\|*)
        _crit="${_remaining%%|*}"
        _remaining="${_remaining#*|}"
        ;;
      *)
        _crit="$_remaining"
        _remaining=""
        ;;
    esac
    [ -z "$_crit" ] && continue

    # Try to auto-verify known patterns
    _matched=""
    case "$_crit" in
      *"go build"*|*"go vet"*)
        # Already handled above — skip duplicates
        _matched="true"
        ;;
      *"bash -n"*)
        _matched="true"
        ;;
      *"test"*|*"Test"*)
        if [ -n "$PROJECT_DIR" ]; then
          _test_out=$(cd "$PROJECT_DIR" && ${_tmo} go test ./... 2>&1) && _test_rc=0 || _test_rc=$?
          if [ "$_test_rc" = "0" ]; then
            _add_criterion "$_crit" "pass" "go test exit 0"
          else
            _add_criterion "$_crit" "fail" "go test exit ${_test_rc}"
          fi
          _matched="true"
        fi
        ;;
    esac

    if [ "$_matched" != "true" ]; then
      _add_criterion "$_crit" "needs_human" "" "Verify manually: ${_crit}"
    fi
  done
fi

# Diff stat as evidence (not a criterion)
_diff_stat=$(cd "$PROJECT_DIR" 2>/dev/null && git diff --stat HEAD 2>&1) || _diff_stat=""
if [ -n "$_diff_stat" ]; then
  _auto_output="${_auto_output}[git diff --stat]${NL}${_diff_stat}${NL}"
fi

# Build the structured proof_of_success JSON
_human_guide_esc=$(printf '%s' "$_human_guides" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
PROOF_OF_SUCCESS_JSON=$(printf '{"criteria_results":[%s],"human_verification_guide":"%s","auto_verified_count":%d,"needs_human_count":%d,"failed_count":%d}' \
  "$_criteria_json_arr" "$_human_guide_esc" "$_auto_count" "$_human_count" "$_fail_count")

# Set legacy fields for backward compat
if [ -z "$PROOF_TYPE" ]; then
  if [ "$_auto_count" -gt 0 ] || [ "$_fail_count" -gt 0 ]; then
    PROOF_TYPE="auto_build"
    PROOF_CONTENT="$_auto_output"
    if [ "$_fail_count" = "0" ]; then
      _verification_status="passed"
    else
      _verification_status="failed"
    fi
  else
    PROOF_TYPE="unverified"
    _fallback_summary="${DOEY_SUMMARY:-}"
    if [ -n "$_fallback_summary" ]; then
      PROOF_CONTENT="Task completed — $_fallback_summary"
    else
      PROOF_CONTENT="Task completed — no summary available"
    fi
  fi
fi

# Build verification_steps JSON from auto output
VERIFICATION_STEPS_JSON="[]"
if [ -n "$_auto_output" ]; then
  VERIFICATION_STEPS_JSON=$(printf '%s' "$_auto_output" | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null) || VERIFICATION_STEPS_JSON="[]"
fi

PANE_TITLE=$(tmux display-message -t "$PANE" -p '#{pane_title}' 2>/dev/null) || PANE_TITLE="worker-$PANE_INDEX"
# FILTERED is already scrubbed (doey_scrub_secrets applied in Pass 1 post-processing).
LAST_TEXT_JSON=$(printf '%s' "$FILTERED" | jq -Rs '.' 2>/dev/null) || \
  LAST_TEXT_JSON=$(printf '%s' "$FILTERED" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
  LAST_TEXT_JSON='""'

# Aggregate tool calls into [{name,count}, ...]
_TOOL_CALLS_JSON="[]"
if [ -n "$_TOOL_NAMES_RAW" ]; then
  _TOOL_CALLS_JSON=$(printf '%s' "$_TOOL_NAMES_RAW" \
    | awk 'NF' \
    | sort \
    | uniq -c \
    | awk '{printf "%s\t%d\n", $2, $1}' \
    | jq -Rsc 'split("\n") | map(select(length>0) | split("\t") | {name: .[0], count: (.[1]|tonumber)})' 2>/dev/null) || _TOOL_CALLS_JSON="[]"
  [ -z "$_TOOL_CALLS_JSON" ] && _TOOL_CALLS_JSON="[]"
fi

# Dedup file-edit list
_FILE_EDITS_JSON="[]"
if [ -n "$_FILE_EDITS_RAW" ]; then
  _FILE_EDITS_JSON=$(printf '%s' "$_FILE_EDITS_RAW" \
    | awk 'NF' \
    | sort -u \
    | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null) || _FILE_EDITS_JSON="[]"
  [ -z "$_FILE_EDITS_JSON" ] && _FILE_EDITS_JSON="[]"
fi

# Error field — null when no error line captured
_LAST_ERROR_JSON="null"
if [ -n "$_error_line" ]; then
  _scrubbed_err=$(printf '%s' "$_error_line" | doey_scrub_secrets)
  _LAST_ERROR_JSON=$(printf '%s' "$_scrubbed_err" | jq -Rs '.' 2>/dev/null) || _LAST_ERROR_JSON="null"
fi

# Compose structured last_output object (schema v2)
LAST_OUTPUT_JSON=$(printf '{"text":%s,"tool_calls":%s,"file_edits":%s,"error":%s}' \
  "$LAST_TEXT_JSON" "$_TOOL_CALLS_JSON" "$_FILE_EDITS_JSON" "$_LAST_ERROR_JSON")

TITLE_JSON=$(printf '%s' "$PANE_TITLE" | jq -Rs '.' 2>/dev/null) || TITLE_JSON='"worker-'"$PANE_INDEX"'"'
PROOF_TYPE_JSON=$(printf '%s' "$PROOF_TYPE" | jq -Rs '.' 2>/dev/null) || PROOF_TYPE_JSON='""'
PROOF_CONTENT_JSON=$(printf '%s' "$PROOF_CONTENT" | jq -Rs '.' 2>/dev/null) || PROOF_CONTENT_JSON='""'

# Extract verification steps from VERIFICATION_STEP: lines into JSON array
# Only reset if auto-verification didn't already populate it
_vsteps=$(printf '%s' "$FILTERED" | grep '^VERIFICATION_STEP:' | sed 's/^VERIFICATION_STEP:[[:space:]]*//' ) || true
if [ -n "$_vsteps" ]; then
  VERIFICATION_STEPS_JSON=$(printf '%s\n' "$_vsteps" | jq -Rsc '[.]' 2>/dev/null) || true
  # jq -Rsc with single input gives ["all\nlines"] — split properly
  VERIFICATION_STEPS_JSON=$(printf '%s\n' "$_vsteps" | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null) || VERIFICATION_STEPS_JSON="[]"
elif [ "$_verification_status" = "" ]; then
  VERIFICATION_STEPS_JSON="[]"
fi

TMPFILE=$(mktemp "${RUNTIME_DIR}/results/.tmp_XXXXXX" 2>/dev/null)
if [ -z "$TMPFILE" ] || [ ! -f "$TMPFILE" ]; then
  echo "[WARN] mktemp failed in $(basename "$0") — writing non-atomically" >> "${RUNTIME_DIR}/doey-warnings.log" 2>/dev/null
  _log_error "HOOK_ERROR" "mktemp failed, using non-atomic write" "result_file=$RESULT_FILE"
  TMPFILE="$RESULT_FILE"
fi

local_task_id="${DOEY_TASK_ID:-}"
# Fallback: read task ID persisted by on-prompt-submit
if [ -z "$local_task_id" ]; then
  local_task_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.task_id" 2>/dev/null) || local_task_id=""
fi
local_subtask_id=$(cat "${RUNTIME_DIR}/status/${PANE_SAFE}.subtask_id" 2>/dev/null) || local_subtask_id=""
# Note: task_id/subtask_id files preserved for parallel async hooks

# ── Mandatory DOEY_SUMMARY (task 575 / subtask 261761) ────────────
# Priority: (a) DOEY_SUMMARY env, (b) first line of last assistant
# message in pane tail, (c) "[no summary provided]" placeholder.
# Placeholder triggers an issue file under ${RUNTIME_DIR}/issues/.
local_summary="${DOEY_SUMMARY:-}"
_summary_source="env"
if [ -z "$local_summary" ]; then
  local_summary=$(printf '%s\n' "$FILTERED" | tail -20 | awk 'NF>0 && !/^[[:space:]]*[>$#]/ {sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit}')
  [ -n "$local_summary" ] && _summary_source="last_message"
fi
if [ -z "$local_summary" ]; then
  local_summary="[no summary provided]"
  _summary_source="placeholder"
  mkdir -p "${RUNTIME_DIR}/issues" 2>/dev/null || true
  _issue_ts=$(date +%s)
  _issue_file="${RUNTIME_DIR}/issues/${_issue_ts}_pane_${WINDOW_INDEX}_${PANE_INDEX}_no_summary.txt"
  {
    printf 'pane=%s.%s\n' "$WINDOW_INDEX" "$PANE_INDEX"
    printf 'task_id=%s\n' "${local_task_id:-}"
    printf 'subtask_id=%s\n' "${local_subtask_id:-}"
    printf 'timestamp=%s\n' "$_issue_ts"
    printf 'reason=%s\n' "worker stopped with no DOEY_SUMMARY env and no usable tail line"
  } > "$_issue_file" 2>/dev/null || true
  _log "stop-results: summary placeholder used, issue logged to $_issue_file"
fi
local_summary_escaped=$(printf '%s' "$local_summary" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' -e 's/	/\\t/g')

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
  "last_output": $LAST_OUTPUT_JSON,
  "task_id": "$local_task_id",
  "subtask_id": "$local_subtask_id",
  "hypothesis_updates": ${DOEY_HYPOTHESIS_UPDATES:-[]},
  "evidence": ${DOEY_EVIDENCE:-[]},
  "needs_follow_up": ${DOEY_NEEDS_FOLLOW_UP:-false},
  "summary": "$local_summary_escaped",
  "proof_type": $PROOF_TYPE_JSON,
  "proof_content": $PROOF_CONTENT_JSON,
  "verification_steps": $VERIFICATION_STEPS_JSON,
  "verification_status": "$_verification_status",
  "proof_of_success": $PROOF_OF_SUCCESS_JSON
}
EOF
[ "$TMPFILE" != "$RESULT_FILE" ] && mv "$TMPFILE" "$RESULT_FILE"
TMPFILE=""
_log "stop-results: wrote result to $RESULT_FILE (status=$STATUS, tools=$TOOL_COUNT)"

# Compute files changed count (used outside the task block below)
_FILES_COUNT=0
[ -n "$FILES_LIST" ] && _FILES_COUNT=$(printf '%s\n' "$FILES_LIST" | wc -l | tr -d ' ')

if [ -n "$local_task_id" ] && [ -n "$PROJECT_DIR" ] && [ -d "${PROJECT_DIR}/.doey/tasks" ]; then
  # "Latest" pointer — readers (Go TUI, reviewer) expect this exact path.
  cp "$RESULT_FILE" "${PROJECT_DIR}/.doey/tasks/${local_task_id}.result.json" 2>/dev/null || true
  # History copy — append-only, one file per invocation. Preserves prior runs.
  _HIST_TS=$(date +%s)
  _HIST_PANE="${WINDOW_INDEX}_${PANE_INDEX}"
  _RESULT_HIST_DIR="${PROJECT_DIR}/.doey/tasks/${local_task_id}/results"
  mkdir -p "$_RESULT_HIST_DIR" 2>/dev/null || true
  cp "$RESULT_FILE" "${_RESULT_HIST_DIR}/${_HIST_TS}_${_HIST_PANE}.json" 2>/dev/null || true
  _local_task_file="${PROJECT_DIR}/.doey/tasks/${local_task_id}.task"
  _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}.result.json" 2>/dev/null || true
  _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}/results/${_HIST_TS}_${_HIST_PANE}.json" 2>/dev/null || true

  _local_report="${RUNTIME_DIR}/reports/pane_${WINDOW_INDEX}_${PANE_INDEX}.report"
  if [ -f "$_local_report" ]; then
    # "Latest" report pointer (preserved for readers)
    cp "$_local_report" "${PROJECT_DIR}/.doey/tasks/${local_task_id}.report" 2>/dev/null || true
    # History copy — one per invocation
    _REPORT_HIST_DIR="${PROJECT_DIR}/.doey/tasks/${local_task_id}/reports"
    mkdir -p "$_REPORT_HIST_DIR" 2>/dev/null || true
    cp "$_local_report" "${_REPORT_HIST_DIR}/${_HIST_TS}_${_HIST_PANE}.report" 2>/dev/null || true
    _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}.report" 2>/dev/null || true
    _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}/reports/${_HIST_TS}_${_HIST_PANE}.report" 2>/dev/null || true
  fi

  if [ -n "$FILTERED" ]; then
    _PANE_SAFE="${WINDOW_INDEX}_${PANE_INDEX}"
    _ATTACH_TS=$(date +%s)
    _ATTACH_DIR="${PROJECT_DIR}/.doey/tasks/${local_task_id}/attachments"
    mkdir -p "$_ATTACH_DIR" 2>/dev/null || true
    cat > "${_ATTACH_DIR}/${_ATTACH_TS}_completion_${_PANE_SAFE}.md" 2>/dev/null <<ATTACH_EOF
---
type: completion
title: ${DOEY_ROLE_WORKER} ${WINDOW_INDEX}.${PANE_INDEX} output
author: ${DOEY_ROLE_WORKER}_${_PANE_SAFE}
timestamp: ${_ATTACH_TS}
task_id: ${local_task_id}
---

${FILTERED}
ATTACH_EOF
    _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}/attachments/${_ATTACH_TS}_completion_${_PANE_SAFE}.md" 2>/dev/null || true
  fi

  # Copy research reports to persistent task attachments
  _RES_DIR="${RUNTIME_DIR}/research"
  if [ -d "$_RES_DIR" ]; then
    _RES_PANE="${WINDOW_INDEX}_${PANE_INDEX}"
    _RES_ATTACH_DIR="${PROJECT_DIR}/.doey/tasks/${local_task_id}/attachments"
    mkdir -p "$_RES_ATTACH_DIR" 2>/dev/null || true
    _RES_TS=$(date +%s)
    for _rfile in "${_RES_DIR}/task_${local_task_id}"*.md "${_RES_DIR}/${_RES_PANE}"*.md "${_RES_DIR}/pane_${_RES_PANE}"*.md; do
      [ -f "$_rfile" ] || continue
      _rbase=$(basename "$_rfile")
      _rdest_name="${_RES_TS}_research_${_rbase}"
      _rdest="${_RES_ATTACH_DIR}/${_rdest_name}"
      [ -f "$_rdest" ] && continue
      {
        printf '%s\n' "---"
        printf '%s\n' "type: research"
        printf 'title: Research report from %s %s.%s\n' "${DOEY_ROLE_WORKER:-Worker}" "$WINDOW_INDEX" "$PANE_INDEX"
        printf 'author: %s_%s\n' "${DOEY_ROLE_WORKER:-Worker}" "$_RES_PANE"
        printf 'timestamp: %s\n' "$_RES_TS"
        printf 'task_id: %s\n' "$local_task_id"
        printf 'source: %s\n' "$_rbase"
        printf '%s\n' "---"
        printf '\n'
        cat "$_rfile"
      } > "$_rdest" 2>/dev/null || true
      _append_attachment "$_local_task_file" ".doey/tasks/${local_task_id}/attachments/${_rdest_name}" 2>/dev/null || true
    done
  fi

  # Add completion report to task (Task Accountability)
  if [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then
    (
      source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
      _rpt_body="${local_summary:-Worker ${WINDOW_INDEX}.${PANE_INDEX} completed with ${TOOL_COUNT} tool calls, ${_FILES_COUNT:-0} files changed}"
      doey_task_add_report "$PROJECT_DIR" "$local_task_id" "completion" \
        "Worker ${WINDOW_INDEX}.${PANE_INDEX} ${STATUS}" "$_rpt_body" \
        "worker_${WINDOW_INDEX}_${PANE_INDEX}"
    ) 2>/dev/null || true
  fi

  # Import proof fields into SQLite (task #275)
  if command -v doey-ctl >/dev/null 2>&1; then
    (
      [ -n "$PROOF_TYPE" ] && doey-ctl task update --id "$local_task_id" --field proof_type --value "$PROOF_TYPE" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      [ -n "$PROOF_CONTENT" ] && doey-ctl task update --id "$local_task_id" --field proof_content --value "$PROOF_CONTENT" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      [ "$VERIFICATION_STEPS_JSON" != "[]" ] && doey-ctl task update --id "$local_task_id" --field verification_steps --value "$VERIFICATION_STEPS_JSON" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      [ -n "$PROOF_OF_SUCCESS_JSON" ] && doey-ctl task update --id "$local_task_id" --field proof_of_success --value "$PROOF_OF_SUCCESS_JSON" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      if [ -n "$FILES_LIST" ]; then
        _files_csv=$(printf '%s' "$FILES_LIST" | tr '\n' ',' | sed 's/,$//')
        doey-ctl task update --id "$local_task_id" --field files --value "$_files_csv" --project-dir "$PROJECT_DIR" 2>/dev/null || true
      fi
    ) &
  fi
fi

type _debug_log >/dev/null 2>&1 && _debug_log lifecycle "result_captured" "files_changed=${_FILES_COUNT}" "tool_calls=${TOOL_COUNT}"
write_activity "task_completed" "{\"status\":\"${STATUS}\",\"tools\":${TOOL_COUNT},\"files\":${_FILES_COUNT}}"

# Emit result_captured event to TUI event log (fire-and-forget)
if command -v doey >/dev/null 2>&1; then
  (doey event log --type result_captured --source "$PANE" --message "Result: ${_FILES_COUNT} files, ${TOOL_COUNT} tools" &) 2>/dev/null
fi

# Stats emit (task #521 Phase 2) — additive, silent-fail
if command -v doey-stats-emit.sh >/dev/null 2>&1; then
  (doey-stats-emit.sh task result_captured "task_id=${DOEY_TASK_ID:-}" "files_changed=${_FILES_COUNT:-0}" "tool_count=${TOOL_COUNT:-0}" &) 2>/dev/null || true
fi

COMPLETION="${RUNTIME_DIR}/status/completion_pane_${WINDOW_INDEX}_${PANE_INDEX}"
cat > "${COMPLETION}.tmp" <<COMPLETE
PANE_INDEX="$PANE_INDEX"
PANE_TITLE="$PANE_TITLE"
STATUS="$STATUS"
TIMESTAMP=$(date +%s)
COMPLETE
mv "${COMPLETION}.tmp" "$COMPLETION"
[ ! -f "$COMPLETION" ] && _log_error "HOOK_ERROR" "Completion event file not written" "path=$COMPLETION"

# Update .task file to error if errors detected (stop-status.sh already set "done")
if [ "$STATUS" = "error" ] && [ -n "$local_task_id" ] && [ -n "$PROJECT_DIR" ]; then
  if [ -f "${PROJECT_DIR}/shell/doey-task-helpers.sh" ]; then
    (
      source "${PROJECT_DIR}/shell/doey-task-helpers.sh"
      _task_file="${PROJECT_DIR}/.doey/tasks/${local_task_id}.task"
      [ -f "$_task_file" ] && task_update_field "$_task_file" "TASK_STATUS" "error"
      if [ -n "$local_subtask_id" ]; then
        doey_task_update_subtask "$PROJECT_DIR" "$local_task_id" "$local_subtask_id" "failed"
      fi
    ) 2>/dev/null || true
  fi
fi

# Auto-rebuild doey CLI tools if Go sources changed
case "$FILES_LIST" in
  *tui/cmd/doey-ctl/*.go*|*tui/internal/store/*.go*)
    if [ -x /usr/local/go/bin/go ] && [ -d "${PROJECT_DIR}/tui" ]; then
      mkdir -p "$HOME/.local/bin"
      (cd "${PROJECT_DIR}/tui" && /usr/local/go/bin/go build -o "$HOME/.local/bin/doey-ctl" ./cmd/doey-ctl/) 2>/dev/null \
        || echo "doey CLI tools auto-build failed" >&2
    fi
    ;;
esac

# Taskmaster wake trigger removed — stop-notify.sh is the sole wake source
