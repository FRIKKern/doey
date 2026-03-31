#!/usr/bin/env bash
set -euo pipefail

# doey-render-task.sh — Render .task files into terminal-friendly visual output
# Usage: doey-render-task.sh <task_file> [json_file]
#        doey-render-task.sh --id <id> --runtime <dir>

# ── Symbols (respect DOEY_ASCII_ONLY) ──────────────────────────────────
if [ "${DOEY_ASCII_ONLY:-}" = "1" ] || [ "${DOEY_ASCII_ONLY:-}" = "true" ]; then
  S_SECTION="*"; S_BULLET="-"; S_ARROW="->"; S_NESTED=">"; S_DONE="[v]"
  S_ACTIVE="[~]"; S_READY="[ ]"; S_RISK="[!]"; S_NEW="[*]"
  S_BAR_FILL="#"; S_BAR_EMPTY="."; S_BLOCKED="[X]"
else
  S_SECTION="◆"; S_BULLET="•"; S_ARROW="→"; S_NESTED="↳"; S_DONE="✓"
  S_ACTIVE="◑"; S_READY="○"; S_RISK="⚠"; S_NEW="★"
  S_BAR_FILL="█"; S_BAR_EMPTY="░"; S_BLOCKED="⊘"
fi

# ── Gum detection (Charmbracelet CLI) ─────────────────────────────────
HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

# gum style wrapper — falls back to plain printf when gum is unavailable.
# Usage: _gum_style "text" [gum-style-flags...]
_gum_style() {
  local text="$1"; shift
  if [ "$HAS_GUM" = true ]; then
    gum style "$@" -- "$text" 2>/dev/null || printf '%s' "$text"
  else
    printf '%s' "$text"
  fi
}

# gum style single-line wrapper — outputs text with newline and color
_styled_line() {
  local fg="$1"; shift
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground "$fg" "$*" 2>/dev/null || printf '%s\n' "$*"
  else
    printf '%s\n' "$*"
  fi
}

# Error-exit with styled message
_die() {
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 1 ${2:+--bold} "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
  exit 1
}

# ── Confidence bar ─────────────────────────────────────────────────────
render_bar() {
  local pct="$1" width="${2:-10}" filled empty bar_str=""
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  bar_str="["
  local i=0; while [ $i -lt $filled ]; do bar_str="${bar_str}${S_BAR_FILL}"; i=$((i+1)); done
  i=0; while [ $i -lt $empty ]; do bar_str="${bar_str}${S_BAR_EMPTY}"; i=$((i+1)); done
  bar_str="${bar_str}] ${pct}%"
  if [ "$HAS_GUM" = true ]; then
    local bar_color="2"
    if [ "$pct" -lt 40 ]; then bar_color="1"
    elif [ "$pct" -lt 70 ]; then bar_color="3"
    fi
    gum style --foreground "$bar_color" "$bar_str" 2>/dev/null || printf '%s' "$bar_str"
  else
    printf '%s' "$bar_str"
  fi
}

# ── Status symbol mapping ─────────────────────────────────────────────
status_symbol() {
  case "$1" in
    done)                       printf '%s' "$S_DONE" ;;
    active|in_progress)         printf '%s' "$S_ACTIVE" ;;
    cancelled|failed)           printf '%s' "$S_BLOCKED" ;;
    *)                          printf '%s' "$S_READY" ;;
  esac
}

# ── JSON helpers (python3) ─────────────────────────────────────────────
read_json_field() {
  local file="$1" field="$2"
  python3 -c "import json,sys; d=json.load(open('$file')); v=d.get('$field',''); print(v if isinstance(v,str) else json.dumps(v))" 2>/dev/null || echo ""
}

read_json_array() {
  local file="$1" field="$2"
  python3 -c "
import json,sys
d=json.load(open('$file'))
arr=d.get('$field',[])
for item in arr:
  print(item if isinstance(item,str) else json.dumps(item))
" 2>/dev/null
}

# ── Parse .task file ───────────────────────────────────────────────────
parse_task() {
  local file="$1" line
  [ -s "$file" ] || return 1
  TASK_ID=""; TASK_TITLE=""; TASK_STATUS=""; TASK_CREATED=""
  TASK_TYPE=""; TASK_OWNER=""; TASK_PRIORITY=""; TASK_SUMMARY=""
  TASK_DESCRIPTION=""; TASK_SCHEMA_VERSION=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "${line%%=*}" in
      TASK_ID)             TASK_ID="${line#*=}" ;;
      TASK_TITLE)          TASK_TITLE="${line#*=}" ;;
      TASK_STATUS)         TASK_STATUS="${line#*=}" ;;
      TASK_CREATED)        TASK_CREATED="${line#*=}" ;;
      TASK_TYPE)           TASK_TYPE="${line#*=}" ;;
      TASK_OWNER)          TASK_OWNER="${line#*=}" ;;
      TASK_PRIORITY)       TASK_PRIORITY="${line#*=}" ;;
      TASK_SUMMARY)        TASK_SUMMARY="${line#*=}" ;;
      TASK_DESCRIPTION)    TASK_DESCRIPTION="${line#*=}" ;;
      TASK_SCHEMA_VERSION) TASK_SCHEMA_VERSION="${line#*=}" ;;
    esac
  done < "$file" || true

  # Bail if no TASK_ID was parsed (malformed file)
  [ -n "${TASK_ID:-}" ] || return 1

  # Defaults
  if [ -z "$TASK_TYPE" ]; then TASK_TYPE="feature"; fi
  if [ -z "$TASK_OWNER" ]; then TASK_OWNER="Boss"; fi
  if [ -z "$TASK_PRIORITY" ]; then TASK_PRIORITY="P2"; fi
  if [ -z "$TASK_SUMMARY" ]; then TASK_SUMMARY="$TASK_TITLE"; fi
}

# ── Compute age string ─────────────────────────────────────────────────
compute_age() {
  local created="$1"
  if [ -z "$created" ]; then echo ""; return; fi
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - created))
  if [ "$elapsed" -lt 60 ]; then echo "${elapsed}s"
  elif [ "$elapsed" -lt 3600 ]; then echo "$((elapsed / 60))m"
  elif [ "$elapsed" -lt 86400 ]; then echo "$((elapsed / 3600))h"
  else echo "$((elapsed / 86400))d"; fi
}

# ── Render: header ─────────────────────────────────────────────────────
_status_color() {
  case "$1" in
    done)                       printf '2' ;;   # green
    active|in_progress)         printf '3' ;;   # yellow
    cancelled|failed)           printf '1' ;;   # red
    *)                          printf '8' ;;   # gray
  esac
}

render_header() {
  local sym title_line meta_line
  sym=$(status_symbol "$TASK_STATUS")
  title_line=$(printf '%s #%s — %s' "$S_SECTION" "$TASK_ID" "$TASK_TITLE")
  meta_line=$(printf 'Type: %s | Priority: %s | Owner: %s | Status: %s %s' \
    "$TASK_TYPE" "$TASK_PRIORITY" "$TASK_OWNER" "$sym" "$TASK_STATUS")

  if [ "$HAS_GUM" = true ]; then
    local sc
    sc=$(_status_color "$TASK_STATUS")
    gum style --border rounded --foreground 6 --bold --padding "0 2" \
      --border-foreground "$sc" -- "$title_line" "$meta_line" 2>/dev/null \
      || { printf '%s\n  %s\n' "$title_line" "$meta_line"; }
  else
    printf '%s\n  %s\n' "$title_line" "$meta_line"
  fi
}

# ── Render: basic (.task only) ─────────────────────────────────────────
render_basic() {
  local density="${DOEY_VISUALIZATION_DENSITY:-normal}"
  [ "$density" = "compact" ] && return 0

  if [ -n "$TASK_DESCRIPTION" ]; then
    printf '\n'
    _gum_style "$S_SECTION Description" --bold --foreground 5
    printf '\n'
    _styled_line 7 "  $TASK_DESCRIPTION"
  fi
  local age
  age=$(compute_age "$TASK_CREATED")
  [ -n "$age" ] && _styled_line 8 "  $S_ARROW Age: $age"
}

# ── Render: list section (shared by deliverables, constraints, criteria) ──
_render_list_section() {
  local json_file="$1" field="$2" title="$3" symbol="$4"
  local line has=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$has" -eq 0 ]; then
      printf '\n'
      _gum_style "$S_SECTION $title" --bold --foreground 5
      printf '\n'
      has=1
    fi
    _styled_line 7 "  $symbol $line"
  done <<EOF
$(read_json_array "$json_file" "$field")
EOF
}

# ── Render: structured (.task + .json) ─────────────────────────────────
render_structured() {
  local json_file="$1"
  local density="${DOEY_VISUALIZATION_DENSITY:-normal}"
  [ "$density" = "compact" ] && return 0

  # Intent
  local intent
  intent=$(read_json_field "$json_file" "intent")
  if [ -n "$intent" ]; then
    printf '\n'
    _gum_style "$S_SECTION Intent" --bold --foreground 5
    printf '\n'
    _styled_line 7 "  $intent"
  fi

  # Hypotheses
  local hyp_line
  local has_hyp=0
  while IFS= read -r hyp_line; do
    [ -z "$hyp_line" ] && continue
    if [ "$has_hyp" -eq 0 ]; then
      printf '\n'
      _gum_style "$S_SECTION Hypotheses" --bold --foreground 5
      printf '\n'
      has_hyp=1
    fi
    # Try to extract name and confidence from JSON object
    local hname hconf
    hname=$(printf '%s' "$hyp_line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('name',d.get('description','')))" 2>/dev/null) || hname="$hyp_line"
    hconf=$(printf '%s' "$hyp_line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('confidence',50))" 2>/dev/null) || hconf=""
    if [ -n "$hconf" ] && [ "$hconf" != "$hyp_line" ]; then
      local bar_out
      bar_out=$(render_bar "$hconf" 10)
      _styled_line 6 "  $S_BULLET $hname — $bar_out"
    else
      _styled_line 6 "  $S_BULLET $hyp_line"
    fi
  done <<EOF
$(read_json_array "$json_file" "hypotheses")
EOF

  # Deliverables (normal + verbose)
  _render_list_section "$json_file" "deliverables" "Deliverables" "$S_BULLET"

  # Verbose-only sections
  [ "$density" != "verbose" ] && return 0

  _render_list_section "$json_file" "constraints" "Constraints" "$S_RISK"
  _render_list_section "$json_file" "success_criteria" "Success Criteria" "$S_DONE"

  # Dispatch plan summary
  local dp
  dp=$(read_json_field "$json_file" "dispatch_plan")
  if [ -n "$dp" ] && [ "$dp" != "{}" ]; then
    printf '\n'
    _gum_style "$S_SECTION Dispatch Plan" --bold --foreground 5
    printf '\n'
    _styled_line 8 "  $S_ARROW $dp"
  fi
}

# ── Main ───────────────────────────────────────────────────────────────
main() {
  local task_file="" json_file="" task_id="" runtime_dir=""

  # Parse args
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) task_id="$2"; shift 2 ;;
      --runtime) runtime_dir="$2"; shift 2 ;;
      *) if [ -z "$task_file" ]; then task_file="$1"; else json_file="$1"; fi; shift ;;
    esac
  done

  # Resolve from ID if needed — prefer persistent .doey/tasks/, fall back to runtime
  if [ -n "$task_id" ] && [ -n "$runtime_dir" ]; then
    local _proj_dir=""
    if [ -f "${runtime_dir}/session.env" ]; then
      _proj_dir=$(grep '^PROJECT_DIR=' "${runtime_dir}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
    fi
    if [ -n "$_proj_dir" ] && [ -f "${_proj_dir}/.doey/tasks/${task_id}.task" ]; then
      task_file="${_proj_dir}/.doey/tasks/${task_id}.task"
      json_file="${_proj_dir}/.doey/tasks/${task_id}.json"
    else
      task_file="${runtime_dir}/tasks/${task_id}.task"
      json_file="${runtime_dir}/tasks/${task_id}.json"
    fi
  fi

  [ -z "$task_file" ] && _die "Usage: $0 <task_file> [json_file] | --id <id> --runtime <dir>"
  [ ! -f "$task_file" ] && _die "Error: task file not found: $task_file" bold
  [ ! -s "$task_file" ] && _die "Empty task file: $task_file"

  # Auto-detect json companion
  if [ -z "$json_file" ]; then
    local base="${task_file%.task}"
    if [ -f "${base}.json" ]; then json_file="${base}.json"; fi
  fi

  # Parse task file
  parse_task "$task_file"

  # Render
  render_header

  if [ -n "$json_file" ] && [ -f "$json_file" ]; then
    render_structured "$json_file"
  else
    render_basic
  fi
}

main "$@"
