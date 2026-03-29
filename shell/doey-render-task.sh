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

# ── Width detection ────────────────────────────────────────────────────
detect_width() {
  local w=80
  if [ -n "${TMUX:-}" ]; then
    w=$(tmux display-message -p '#{pane_width}' 2>/dev/null) || w=80
  elif command -v tput >/dev/null 2>&1; then
    w=$(tput cols 2>/dev/null) || w=80
  fi
  echo "$w"
}

# ── Confidence bar ─────────────────────────────────────────────────────
render_bar() {
  local pct="$1" width="${2:-10}" filled empty
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  printf '['
  local i=0; while [ $i -lt $filled ]; do printf '%s' "$S_BAR_FILL"; i=$((i+1)); done
  i=0; while [ $i -lt $empty ]; do printf '%s' "$S_BAR_EMPTY"; i=$((i+1)); done
  printf '] %d%%' "$pct"
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
TASK_ID=""; TASK_TITLE=""; TASK_STATUS=""; TASK_CREATED=""
TASK_TYPE=""; TASK_OWNER=""; TASK_PRIORITY=""; TASK_SUMMARY=""
TASK_DESCRIPTION=""; TASK_SCHEMA_VERSION=""

parse_task() {
  local file="$1" line
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
render_header() {
  local sym
  sym=$(status_symbol "$TASK_STATUS")
  printf '%s #%s — %s\n' "$S_SECTION" "$TASK_ID" "$TASK_TITLE"
  printf '  Type: %s | Priority: %s | Owner: %s | Status: %s %s\n' \
    "$TASK_TYPE" "$TASK_PRIORITY" "$TASK_OWNER" "$sym" "$TASK_STATUS"
}

# ── Render: basic (.task only) ─────────────────────────────────────────
render_basic() {
  local density="${DOEY_VISUALIZATION_DENSITY:-normal}"
  [ "$density" = "compact" ] && return 0

  if [ -n "$TASK_DESCRIPTION" ]; then
    printf '\n%s Description\n  %s\n' "$S_SECTION" "$TASK_DESCRIPTION"
  fi
  local age
  age=$(compute_age "$TASK_CREATED")
  if [ -n "$age" ]; then
    printf '  %s Age: %s\n' "$S_ARROW" "$age"
  fi
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
    printf '\n%s Intent\n  %s\n' "$S_SECTION" "$intent"
  fi

  # Hypotheses
  local hyp_line
  local has_hyp=0
  while IFS= read -r hyp_line; do
    [ -z "$hyp_line" ] && continue
    if [ "$has_hyp" -eq 0 ]; then
      printf '\n%s Hypotheses\n' "$S_SECTION"
      has_hyp=1
    fi
    # Try to extract name and confidence from JSON object
    local hname hconf
    hname=$(printf '%s' "$hyp_line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('name',d.get('description','')))" 2>/dev/null) || hname="$hyp_line"
    hconf=$(printf '%s' "$hyp_line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('confidence',50))" 2>/dev/null) || hconf=""
    if [ -n "$hconf" ] && [ "$hconf" != "$hyp_line" ]; then
      printf '  %s %s — ' "$S_BULLET" "$hname"
      render_bar "$hconf" 10
      printf '\n'
    else
      printf '  %s %s\n' "$S_BULLET" "$hyp_line"
    fi
  done <<EOF
$(read_json_array "$json_file" "hypotheses")
EOF

  # Deliverables (normal + verbose)
  local del_line has_del=0
  while IFS= read -r del_line; do
    [ -z "$del_line" ] && continue
    if [ "$has_del" -eq 0 ]; then
      printf '\n%s Deliverables\n' "$S_SECTION"
      has_del=1
    fi
    printf '  %s %s\n' "$S_BULLET" "$del_line"
  done <<EOF
$(read_json_array "$json_file" "deliverables")
EOF

  # Verbose-only sections
  [ "$density" != "verbose" ] && return 0

  # Constraints
  local con_line has_con=0
  while IFS= read -r con_line; do
    [ -z "$con_line" ] && continue
    if [ "$has_con" -eq 0 ]; then
      printf '\n%s Constraints\n' "$S_SECTION"
      has_con=1
    fi
    printf '  %s %s\n' "$S_RISK" "$con_line"
  done <<EOF
$(read_json_array "$json_file" "constraints")
EOF

  # Success criteria
  local crit_line has_crit=0
  while IFS= read -r crit_line; do
    [ -z "$crit_line" ] && continue
    if [ "$has_crit" -eq 0 ]; then
      printf '\n%s Success Criteria\n' "$S_SECTION"
      has_crit=1
    fi
    printf '  %s %s\n' "$S_DONE" "$crit_line"
  done <<EOF
$(read_json_array "$json_file" "success_criteria")
EOF

  # Dispatch plan summary
  local dp
  dp=$(read_json_field "$json_file" "dispatch_plan")
  if [ -n "$dp" ] && [ "$dp" != "{}" ]; then
    printf '\n%s Dispatch Plan\n  %s %s\n' "$S_SECTION" "$S_ARROW" "$dp"
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

  # Resolve from ID if needed
  if [ -n "$task_id" ] && [ -n "$runtime_dir" ]; then
    task_file="${runtime_dir}/tasks/${task_id}.task"
    json_file="${runtime_dir}/tasks/${task_id}.json"
  fi

  [ -z "$task_file" ] && { echo "Usage: $0 <task_file> [json_file] | --id <id> --runtime <dir>"; exit 1; }
  [ ! -f "$task_file" ] && { echo "Error: task file not found: $task_file"; exit 1; }

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
