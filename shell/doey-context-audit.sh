#!/usr/bin/env bash
# doey-context-audit.sh — Multi-pane context bloat auditor for the Doey grid.
# Mechanical engine invoked by /doey-context-audit skill.
# Exit: 0=clean (score>=90), 1=issues, 2=usage error.
set -euo pipefail

# ----------------------------------------------------------------------------
# CLI parsing
# ----------------------------------------------------------------------------
MODE="report"
JSON=false
NO_COLOR=false

usage() {
  cat <<EOF
Usage: doey-context-audit.sh [--json] [--auto-fix] [--diff] [--no-color]

  (no flags)   plain-text report; exit 0 if score>=90, 1 otherwise
  --json       emit JSON report (same exit codes)
  --diff       show unified diff of what --auto-fix would change, exit 0
  --auto-fix   apply safe fixes, exit 0 on success
  --no-color   suppress ANSI colors
EOF
}

for arg in "$@"; do
  case "$arg" in
    --json)     JSON=true ;;
    --auto-fix) MODE="autofix" ;;
    --diff)     MODE="diff" ;;
    --no-color) NO_COLOR=true ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Error: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Colors
# ----------------------------------------------------------------------------
if $NO_COLOR || [ ! -t 1 ]; then
  RED="" YEL="" GRN="" DIM="" BOLD="" RST=""
else
  RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'
  DIM=$'\033[0;90m'; BOLD=$'\033[1m';   RST=$'\033[0m'
fi

# ----------------------------------------------------------------------------
# Runtime resolution (fresh-install safe)
# ----------------------------------------------------------------------------
RD=""
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)
[ -n "${RD:-}" ] || RD="${DOEY_RUNTIME:-}"

HAS_LIVE=false
if [ -n "$RD" ] && [ -d "$RD" ]; then HAS_LIVE=true; fi

PROJECT_DIR="${DOEY_PROJECT_DIR:-}"
SESSION_NAME=""
if $HAS_LIVE && [ -f "$RD/session.env" ]; then
  _sn=$(grep '^SESSION_NAME=' "$RD/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  [ -n "$_sn" ] && SESSION_NAME="$_sn"
  _pd=$(grep '^PROJECT_DIR=' "$RD/session.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  [ -n "$_pd" ] && PROJECT_DIR="$_pd"
fi

if [ -z "$PROJECT_DIR" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# ----------------------------------------------------------------------------
# Issue accumulator (bash 3.2 — no assoc arrays; DELIM-joined records)
# ----------------------------------------------------------------------------
DELIM=$'\x1f'
ISSUES=()
DEDUCTIONS=0
SCORE=100
BAND="CLEAN"

add_issue() {
  # $1=sev, $2=cat, $3=desc, $4=fix, $5=pts
  ISSUES+=("${1}${DELIM}${2}${DELIM}${3}${DELIM}${4}${DELIM}${5}")
  DEDUCTIONS=$((DEDUCTIONS + $5))
}

# ----------------------------------------------------------------------------
# Step 1 — Pane Survey
# ----------------------------------------------------------------------------
PANE_ROWS=()       # pane_safe|role|W.P|status|task|ctx|msgs
TEAM_CTX_SUM=0

audit_panes() {
  if ! $HAS_LIVE; then return 0; fi
  [ -d "$RD/status" ] || return 0

  for rf in "$RD"/status/*.role; do
    [ -f "$rf" ] || continue
    local base pane_p pane_w _tmp
    base=$(basename "$rf" .role)
    pane_p="${base##*_}"
    _tmp="${base%_*}"
    pane_w="${_tmp##*_}"
    case "$pane_w" in ''|*[!0-9]*) continue ;; esac
    case "$pane_p" in ''|*[!0-9]*) continue ;; esac

    local role="unknown"
    if [ -s "$rf" ]; then
      role=$(head -c 30 "$rf" 2>/dev/null | tr -d '\n' || true)
      [ -z "$role" ] && role="unknown"
    fi

    local sfile="$RD/status/${base}.status"
    local status="-" task="-"
    if [ -f "$sfile" ]; then
      local stl tl
      stl=$(grep -E '^STATUS[:=]' "$sfile" 2>/dev/null | head -1 || true)
      if [ -n "$stl" ]; then
        status="${stl#*[:=]}"
        status="${status# }"
        [ -z "$status" ] && status="-"
      fi
      tl=$(grep -E '^TASK[:=]' "$sfile" 2>/dev/null | head -1 || true)
      if [ -n "$tl" ]; then
        task="${tl#*[:=]}"
        task="${task# }"
        [ -z "$task" ] && task="-"
      fi
    fi

    local ctx=0
    local cfile="$RD/status/context_pct_${pane_w}_${pane_p}"
    if [ -f "$cfile" ]; then
      ctx=$(cat "$cfile" 2>/dev/null || echo 0)
      ctx="${ctx%%[!0-9]*}"
      [ -z "$ctx" ] && ctx=0
    fi

    local msgs=0
    if command -v doey >/dev/null 2>&1; then
      msgs=$(doey msg count -to "$base" 2>/dev/null || echo 0)
      msgs="${msgs%%[!0-9]*}"
      [ -z "$msgs" ] && msgs=0
    fi

    PANE_ROWS+=("${base}${DELIM}${role}${DELIM}${pane_w}.${pane_p}${DELIM}${status}${DELIM}${task}${DELIM}${ctx}${DELIM}${msgs}")
    TEAM_CTX_SUM=$((TEAM_CTX_SUM + ctx))

    if [ "$ctx" -ge 90 ]; then
      add_issue CRITICAL pane-context "${role} @ ${pane_w}.${pane_p} at ${ctx}% context" "run /compact or restart worker" 20
    elif [ "$ctx" -ge 75 ]; then
      add_issue HIGH pane-context "${role} @ ${pane_w}.${pane_p} at ${ctx}% context" "schedule /compact soon" 10
    fi

    if [ "$msgs" -gt 1000 ]; then
      add_issue CRITICAL msg-queue "${base} has ${msgs} unread messages (>1000)" "doey msg clean -pane ${base}" 15
    elif [ "$msgs" -gt 100 ]; then
      add_issue MEDIUM msg-queue "${base} has ${msgs} unread messages (>100)" "doey msg clean -pane ${base}" 5
    fi
  done
}

# ----------------------------------------------------------------------------
# Step 2 — Shared Overhead
# ----------------------------------------------------------------------------
AGENT_WEIGHTS=()   # lines|path
SKILL_WEIGHTS=()

audit_shared_overhead() {
  # Agents
  if [ -d "$PROJECT_DIR/agents" ]; then
    for f in "$PROJECT_DIR"/agents/*.md; do
      [ -f "$f" ] || continue
      local lines
      lines=$(wc -l < "$f" | tr -d ' ')
      AGENT_WEIGHTS+=("${lines}${DELIM}${f}")
      if [ "$lines" -gt 600 ]; then
        add_issue HIGH agent-bloat "$(basename "$f" .md) is ${lines} lines (>600)" "split or move rules to memory" 10
      elif [ "$lines" -gt 300 ]; then
        add_issue MEDIUM agent-bloat "$(basename "$f" .md) is ${lines} lines (>300)" "trim or extract shared include" 5
      fi
    done
  fi

  # CLAUDE.md
  for cm in "$PROJECT_DIR/CLAUDE.md" "$PROJECT_DIR/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"; do
    [ -f "$cm" ] || continue
    local lines
    lines=$(wc -l < "$cm" | tr -d ' ')
    if [ "$lines" -gt 500 ]; then
      add_issue HIGH claude-md "${cm/#$HOME/~} is ${lines} lines (>500)" "move stable content to memory" 20
    elif [ "$lines" -gt 200 ]; then
      add_issue MEDIUM claude-md "${cm/#$HOME/~} is ${lines} lines (>200)" "trim or split" 10
    fi
  done

  # Skills
  if [ -d "$PROJECT_DIR/.claude/skills" ]; then
    for f in "$PROJECT_DIR"/.claude/skills/*/SKILL.md; do
      [ -f "$f" ] || continue
      local lines skill_name
      lines=$(wc -l < "$f" | tr -d ' ')
      skill_name=$(basename "$(dirname "$f")")
      SKILL_WEIGHTS+=("${lines}${DELIM}${f}")
      if [ "$lines" -gt 500 ]; then
        add_issue HIGH skill-bloat "${skill_name} SKILL is ${lines} lines (>500)" "compress" 10
      elif [ "$lines" -gt 200 ]; then
        add_issue MEDIUM skill-bloat "${skill_name} SKILL is ${lines} lines (>200)" "compress" 5
      fi
    done
  fi

  # Repo settings.json (never ~/.claude/settings.json)
  local settings="$PROJECT_DIR/.claude/settings.json"
  if [ -f "$settings" ]; then
    if ! grep -q 'autoCompactPercentage\|autocompact_percentage_override' "$settings" 2>/dev/null; then
      add_issue MEDIUM settings "autocompact override absent in .claude/settings.json" "run --auto-fix to add autoCompactPercentage:75" 10
    fi
    if ! grep -q 'BASH_MAX_OUTPUT_LENGTH' "$settings" 2>/dev/null; then
      add_issue LOW settings "BASH_MAX_OUTPUT_LENGTH env override absent" "add env.BASH_MAX_OUTPUT_LENGTH" 5
    fi
    if ! grep -q '"deny"' "$settings" 2>/dev/null; then
      add_issue MEDIUM settings "permissions.deny block missing" "add deny rules for node_modules/vendor/dist/.git" 10
    fi
  fi

  # Hooks — stderr on non-error paths
  if [ -d "$PROJECT_DIR/.claude/hooks" ]; then
    for f in "$PROJECT_DIR"/.claude/hooks/*.sh; do
      [ -f "$f" ] || continue
      local hit
      hit=$(grep -n '>&2' "$f" 2>/dev/null \
            | grep -viE 'fail|error|warn|cooldown|not found|refuse|missing|debug|\|\|' \
            | head -1 || true)
      if [ -n "$hit" ]; then
        add_issue LOW hook-noise "$(basename "$f") writes stderr on a non-error path" "silence or redirect to log" 3
      fi
    done
  fi
}

# ----------------------------------------------------------------------------
# Step 3 — Message Queue Pollution
# ----------------------------------------------------------------------------
MSG_TOTAL=0
MSG_STALE_24=0
MSG_STALE_7D=0
ROUTER_SPAM_COUNT=0

audit_msg_pollution() {
  if ! $HAS_LIVE || [ ! -d "$RD/messages" ]; then return 0; fi
  local now
  now=$(date +%s)
  for f in "$RD"/messages/*.msg; do
    [ -f "$f" ] || continue
    MSG_TOTAL=$((MSG_TOTAL + 1))
    local mt age
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")
    age=$((now - mt))
    if [ "$age" -gt 86400 ];  then MSG_STALE_24=$((MSG_STALE_24 + 1)); fi
    if [ "$age" -gt 604800 ]; then MSG_STALE_7D=$((MSG_STALE_7D + 1)); fi
    if grep -q 'subject=task_complete\|worker_finished' "$f" 2>/dev/null; then
      ROUTER_SPAM_COUNT=$((ROUTER_SPAM_COUNT + 1))
    fi
  done
  if [ "$MSG_TOTAL" -gt 0 ]; then
    local ratio=$((ROUTER_SPAM_COUNT * 100 / MSG_TOTAL))
    if [ "$ratio" -gt 50 ]; then
      add_issue MEDIUM msg-spam "Router spam ratio ${ratio}% (${ROUTER_SPAM_COUNT}/${MSG_TOTAL})" "investigate stale worker_finished senders" 10
    fi
  fi
}

# ----------------------------------------------------------------------------
# Step 4 — Task File Bloat
# ----------------------------------------------------------------------------
TASK_TOTAL=0
TASK_OVER_5=0
TASK_OVER_10=0
TASK_OVER_50=0
TASK_TOP=()        # size|path (top 10)
PUC_COUNT=0
WPROMPT_COUNT=0

audit_task_files() {
  local tdir="$PROJECT_DIR/.doey/tasks"
  if [ -d "$tdir" ]; then
    local tmplist="${TMPDIR:-/tmp}/doey_audit_tasks.$$"
    : > "$tmplist"
    for f in "$tdir"/*.task; do
      [ -f "$f" ] || continue
      TASK_TOTAL=$((TASK_TOTAL + 1))
      local sz
      sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || wc -c < "$f" | tr -d ' ')
      if [ "$sz" -gt 5120 ];  then TASK_OVER_5=$((TASK_OVER_5 + 1)); fi
      if [ "$sz" -gt 10240 ]; then TASK_OVER_10=$((TASK_OVER_10 + 1)); fi
      if [ "$sz" -gt 51200 ]; then
        TASK_OVER_50=$((TASK_OVER_50 + 1))
        add_issue MEDIUM task-bloat "$(basename "$f") is $((sz/1024))KB (>50KB)" "archive if terminal, else trim TASK_LOG_*" 3
      fi
      printf '%s %s\n' "$sz" "$f" >> "$tmplist"
    done
    if [ -s "$tmplist" ]; then
      local line
      while IFS= read -r line; do
        TASK_TOP+=("${line%% *}${DELIM}${line#* }")
      done < <(sort -rn "$tmplist" | head -10)
    fi
    rm -f "$tmplist"
  fi

  # PUC backlog
  if command -v doey >/dev/null 2>&1; then
    PUC_COUNT=$(doey task list -status pending_user_confirmation 2>/dev/null | grep -c '^[0-9]' 2>/dev/null || echo 0)
    PUC_COUNT="${PUC_COUNT%%[!0-9]*}"
    [ -z "$PUC_COUNT" ] && PUC_COUNT=0
    if [ "$PUC_COUNT" -gt 100 ]; then
      add_issue HIGH puc-backlog "${PUC_COUNT} tasks in pending_user_confirmation (>100)" "doey task done <id> / cancel" 15
    elif [ "$PUC_COUNT" -gt 20 ]; then
      add_issue MEDIUM puc-backlog "${PUC_COUNT} tasks in pending_user_confirmation (>20)" "clear backlog" 5
    fi
  fi

  if $HAS_LIVE; then
    local c=0
    for f in "$RD"/worker-system-prompt-*.md; do
      [ -f "$f" ] && c=$((c + 1))
    done
    WPROMPT_COUNT=$c
  fi
}

# ----------------------------------------------------------------------------
# Step 5 — Duplicate Rule Detection
# ----------------------------------------------------------------------------
DUP_CLUSTERS=()    # label|count|est_total_lines

_dup_scan() {
  local sig="$1" est="$2" label="$3"
  [ -d "$PROJECT_DIR/agents" ] || return 0
  local n
  n=$({ grep -l "$sig" "$PROJECT_DIR"/agents/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')
  [ -z "$n" ] && n=0
  if [ "$n" -ge 3 ]; then
    local total=$((n * est))
    DUP_CLUSTERS+=("${label}${DELIM}${n}${DELIM}${total}")
    add_issue MEDIUM dup-rules "[${label}] ${n} agents share ~${est} lines each (~${total} total)" "extract to agents/_shared/${label}.tmpl" 5
  fi
}

audit_duplicate_rules() {
  _dup_scan 'Terse, direct, technically accurate. 75% fewer tokens' 21 'terse-communication'
  _dup_scan 'NEVER.*send-keys' 3 'never-send-keys'
  _dup_scan 'fresh-install invariant' 2 'fresh-install-invariant'
  _dup_scan 'NO FILLER.*drop just/really' 2 'no-filler'
}

# ----------------------------------------------------------------------------
# Scoring
# ----------------------------------------------------------------------------
compute_score() {
  SCORE=$((100 - DEDUCTIONS))
  [ "$SCORE" -lt 0 ] && SCORE=0
  if   [ "$SCORE" -ge 90 ]; then BAND="CLEAN"
  elif [ "$SCORE" -ge 70 ]; then BAND="NEEDS WORK"
  elif [ "$SCORE" -ge 50 ]; then BAND="BLOATED"
  else                           BAND="CRITICAL"
  fi
}

# ----------------------------------------------------------------------------
# Plain-text report
# ----------------------------------------------------------------------------
render_report() {
  printf '%sDoey Context Audit%s — Session: %s\n' "$BOLD" "$RST" "${SESSION_NAME:-<no-live-session>}"
  local color="$GRN"
  [ "$SCORE" -lt 90 ] && color="$YEL"
  [ "$SCORE" -lt 50 ] && color="$RED"
  printf 'Score: %s%d/100%s — %s\n\n' "$color" "$SCORE" "$RST" "$BAND"

  # Team context spend
  printf '%sTeam Context Spend%s\n' "$BOLD" "$RST"
  if [ ${#PANE_ROWS[@]} -gt 0 ]; then
    printf '  %-22s  %-14s  %4s  %4s  %s\n' "PANE" "ROLE" "CTX%" "MSGS" "STATUS"
    local row
    for row in "${PANE_ROWS[@]}"; do
      IFS="$DELIM" read -r psafe prole pwp pstat ptask pctx pmsgs <<< "$row"
      local mark="  "
      [ "$pctx" -ge 75 ] && mark=" !"
      [ "$pctx" -ge 90 ] && mark="!!"
      printf '  %-22s  %-14s  %3s%%  %4s  %s %s\n' \
        "$psafe" "$prole" "$pctx" "$pmsgs" "$pstat" "$mark"
    done
    printf '  %-22s  %-14s  %3s%%\n' "TOTAL" "" "$TEAM_CTX_SUM"
  else
    printf '  %s(no live session — pane survey skipped)%s\n' "$DIM" "$RST"
  fi
  printf '\n'

  # Agent leaderboard
  if [ ${#AGENT_WEIGHTS[@]} -gt 0 ]; then
    printf '%sAgent Weight Leaderboard%s\n' "$BOLD" "$RST"
    local sorted max=0 a
    sorted=$(printf '%s\n' "${AGENT_WEIGHTS[@]}" | sort -rn | head -10)
    while IFS= read -r a; do
      local ln="${a%%"$DELIM"*}"
      [ -n "$ln" ] && [ "$ln" -gt "$max" ] && max="$ln"
    done <<< "$sorted"
    [ "$max" -eq 0 ] && max=1
    while IFS= read -r a; do
      local ln pth nm bar_len bar i
      ln="${a%%"$DELIM"*}"
      pth="${a#*"$DELIM"}"
      nm=$(basename "$pth" .md)
      bar_len=$((ln * 30 / max))
      bar=""
      i=0
      while [ "$i" -lt "$bar_len" ]; do bar="${bar}#"; i=$((i + 1)); done
      printf '  %-28s %5d  %s\n' "$nm" "$ln" "$bar"
    done <<< "$sorted"
    printf '\n'
  fi

  # Msg pollution
  printf '%sMsg Queue Pollution%s\n' "$BOLD" "$RST"
  if $HAS_LIVE; then
    printf '  Total: %d files   >24h: %d   >7d: %d\n' "$MSG_TOTAL" "$MSG_STALE_24" "$MSG_STALE_7D"
    if [ "$MSG_TOTAL" -gt 0 ]; then
      local ratio=$((ROUTER_SPAM_COUNT * 100 / MSG_TOTAL))
      printf '  Router spam: %d/%d (%d%%)\n' "$ROUTER_SPAM_COUNT" "$MSG_TOTAL" "$ratio"
    fi
    # Offenders from PANE_ROWS
    local row
    for row in "${PANE_ROWS[@]+${PANE_ROWS[@]}}"; do
      IFS="$DELIM" read -r psafe _ _ _ _ _ pmsgs <<< "$row"
      [ "$pmsgs" -gt 100 ] && printf '  Offender: %s — %s unread\n' "$psafe" "$pmsgs"
    done
  else
    printf '  %s(no live session)%s\n' "$DIM" "$RST"
  fi
  printf '\n'

  # Task file bloat
  printf '%sTask File Bloat%s\n' "$BOLD" "$RST"
  printf '  .task files: %d  (>5KB: %d  >10KB: %d  >50KB: %d)\n' \
    "$TASK_TOTAL" "$TASK_OVER_5" "$TASK_OVER_10" "$TASK_OVER_50"
  printf '  PUC backlog: %d\n' "$PUC_COUNT"
  $HAS_LIVE && printf '  worker-system-prompt files: %d\n' "$WPROMPT_COUNT"
  if [ ${#TASK_TOP[@]} -gt 0 ]; then
    printf '  Top by size:\n'
    local r
    for r in "${TASK_TOP[@]}"; do
      local sz pth
      sz="${r%%"$DELIM"*}"
      pth="${r#*"$DELIM"}"
      printf '    %8d  %s\n' "$sz" "$(basename "$pth")"
    done
  fi
  printf '\n'

  # Duplicate rule clusters
  if [ ${#DUP_CLUSTERS[@]} -gt 0 ]; then
    printf '%sDuplicate Rule Clusters%s\n' "$BOLD" "$RST"
    local c
    for c in "${DUP_CLUSTERS[@]}"; do
      IFS="$DELIM" read -r label n total <<< "$c"
      printf '  [%s] %d agents, ~%d lines duplicated. Fix: extract to agents/_shared/%s.tmpl\n' \
        "$label" "$n" "$total" "$label"
    done
    printf '\n'
  fi

  # Issues grouped by severity
  if [ ${#ISSUES[@]} -gt 0 ]; then
    printf '%sIssues by Severity%s\n' "$BOLD" "$RST"
    local sev
    for sev in CRITICAL HIGH MEDIUM LOW; do
      local i
      for i in "${ISSUES[@]}"; do
        IFS="$DELIM" read -r s cat desc fix pts <<< "$i"
        [ "$s" = "$sev" ] || continue
        local c="$YEL"
        [ "$s" = "CRITICAL" ] && c="$RED"
        [ "$s" = "LOW" ] && c="$DIM"
        printf '  %s[%-8s]%s %-14s  %s\n' "$c" "$s" "$RST" "$cat" "$desc"
        printf '             %sFix:%s %s (+%d pts)\n' "$DIM" "$RST" "$fix" "$pts"
      done
    done
    printf '\n'
  fi

  # Top 5 fixes by ROI (highest pts first within severity order)
  if [ ${#ISSUES[@]} -gt 0 ]; then
    printf '%sTop 5 Fixes by ROI%s\n' "$BOLD" "$RST"
    local fc=0 sev i
    for sev in CRITICAL HIGH MEDIUM LOW; do
      for i in "${ISSUES[@]}"; do
        IFS="$DELIM" read -r s cat desc fix pts <<< "$i"
        [ "$s" = "$sev" ] || continue
        fc=$((fc + 1))
        [ "$fc" -gt 5 ] && break
        printf '  %d. [%s] %s (%s, +%d pts)\n' "$fc" "$cat" "$fix" "$s" "$pts"
      done
      [ "$fc" -ge 5 ] && break
    done
    printf '\n'
  fi
}

# ----------------------------------------------------------------------------
# JSON report
# ----------------------------------------------------------------------------
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//	/\\t}"
  printf '%s' "$s"
}

render_json() {
  printf '{'
  printf '"session":"%s",'         "$(_json_escape "$SESSION_NAME")"
  printf '"score":%d,'              "$SCORE"
  printf '"band":"%s",'             "$BAND"
  printf '"team_ctx_sum":%d,'       "$TEAM_CTX_SUM"
  printf '"msg_total":%d,'          "$MSG_TOTAL"
  printf '"msg_stale_24h":%d,'      "$MSG_STALE_24"
  printf '"msg_stale_7d":%d,'       "$MSG_STALE_7D"
  printf '"router_spam_count":%d,'  "$ROUTER_SPAM_COUNT"
  printf '"task_total":%d,'         "$TASK_TOTAL"
  printf '"task_over_50k":%d,'      "$TASK_OVER_50"
  printf '"puc_count":%d,'          "$PUC_COUNT"
  printf '"wprompt_count":%d,'      "$WPROMPT_COUNT"
  printf '"issues":['
  local first=true i
  for i in "${ISSUES[@]+${ISSUES[@]}}"; do
    $first || printf ','
    first=false
    IFS="$DELIM" read -r s cat desc fix pts <<< "$i"
    printf '{"severity":"%s","category":"%s","description":"%s","fix":"%s","pts":%d}' \
      "$s" "$cat" "$(_json_escape "$desc")" "$(_json_escape "$fix")" "$pts"
  done
  printf ']}\n'
}

# ----------------------------------------------------------------------------
# Auto-fix
# ----------------------------------------------------------------------------
_settings_jq_filter='
  .
  | (.autoCompactPercentage //= 75)
  | (.env //= {})
  | (.env.BASH_MAX_OUTPUT_LENGTH //= "150000")
  | (.permissions //= {})
  | (.permissions.deny //= [])
  | (.permissions.deny |= (. + ["Read(./node_modules/**)","Read(./vendor/**)","Read(./dist/**)","Read(./.git/objects/**)"] | unique))
'

do_auto_fix() {
  local settings="$PROJECT_DIR/.claude/settings.json"

  if ! command -v jq >/dev/null 2>&1; then
    printf '%sERROR:%s jq required for auto-fix — install jq and retry\n' "$RED" "$RST" >&2
    return 1
  fi

  if [ -f "$settings" ]; then
    if $HAS_LIVE; then
      mkdir -p "$RD/backups"
      local stamp
      stamp=$(date +%s)
      cp "$settings" "$RD/backups/settings_${stamp}.json"
      printf '  Backed up to %s/backups/settings_%s.json\n' "$RD" "$stamp"
    fi
    local tmp="${settings}.tmp.$$"
    if jq "$_settings_jq_filter" "$settings" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$settings"
      printf '  Patched settings.json (autoCompactPercentage, BASH_MAX_OUTPUT_LENGTH, permissions.deny)\n'
    else
      rm -f "$tmp"
      printf '  %sSkipped:%s jq transform failed on %s\n' "$YEL" "$RST" "$settings"
    fi
  fi

  # Stale .msg cleanup
  if $HAS_LIVE && [ -d "$RD/messages" ]; then
    mkdir -p "$RD/trash"
    local now deleted=0
    now=$(date +%s)
    for f in "$RD"/messages/*.msg; do
      [ -f "$f" ] || continue
      local mt
      mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")
      if [ $((now - mt)) -gt 86400 ]; then
        if command -v trash >/dev/null 2>&1; then
          trash "$f" 2>/dev/null && deleted=$((deleted + 1))
        else
          mv "$f" "$RD/trash/$(basename "$f")" 2>/dev/null && deleted=$((deleted + 1))
        fi
      fi
    done
    printf '  Stale .msg files archived: %d\n' "$deleted"
  fi

  # .task archival (>50KB in terminal state)
  local tdir="$PROJECT_DIR/.doey/tasks"
  if [ -d "$tdir" ]; then
    mkdir -p "$tdir/archive"
    local archived=0
    for f in "$tdir"/*.task; do
      [ -f "$f" ] || continue
      local sz
      sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || wc -c < "$f" | tr -d ' ')
      [ "$sz" -gt 51200 ] || continue
      local id sfile st
      id=$(basename "$f" .task)
      sfile="$tdir/${id}.status"
      [ -f "$sfile" ] || continue
      st=$(head -1 "$sfile" 2>/dev/null | tr -d ' \n' || true)
      case "$st" in
        done|cancelled|failed)
          mv "$f" "$tdir/archive/" 2>/dev/null && archived=$((archived + 1))
          ;;
      esac
    done
    printf '  Terminal-state .task files archived: %d\n' "$archived"
  fi

  printf '\nAuto-fix complete. Re-run without --auto-fix to see updated score.\n'
}

# ----------------------------------------------------------------------------
# Diff preview (--diff)
# ----------------------------------------------------------------------------
do_diff() {
  printf '%sDiff preview — no files will be modified%s\n\n' "$BOLD" "$RST"

  local settings="$PROJECT_DIR/.claude/settings.json"
  if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
    local tmp="${TMPDIR:-/tmp}/doey_audit_after.$$"
    jq "$_settings_jq_filter" "$settings" > "$tmp" 2>/dev/null || true
    printf '%ssettings.json proposed changes:%s\n' "$BOLD" "$RST"
    diff -u "$settings" "$tmp" || true
    rm -f "$tmp"
    printf '\n'
  else
    printf '  %s(settings.json or jq missing — skipped)%s\n\n' "$DIM" "$RST"
  fi

  if $HAS_LIVE && [ -d "$RD/messages" ]; then
    printf '%sStale .msg files (>24h) that would be archived:%s\n' "$BOLD" "$RST"
    local now count=0 mt age f
    now=$(date +%s)
    for f in "$RD"/messages/*.msg; do
      [ -f "$f" ] || continue
      mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")
      age=$((now - mt))
      if [ "$age" -gt 86400 ]; then
        count=$((count + 1))
        printf '  %s  (age %dh)\n' "$(basename "$f")" $((age / 3600))
      fi
    done
    printf '  Total: %d\n\n' "$count"
  fi

  local tdir="$PROJECT_DIR/.doey/tasks"
  if [ -d "$tdir" ]; then
    printf '%s.task files >50KB in terminal state that would be archived:%s\n' "$BOLD" "$RST"
    local count=0 f sz id sfile st
    for f in "$tdir"/*.task; do
      [ -f "$f" ] || continue
      sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || wc -c < "$f" | tr -d ' ')
      [ "$sz" -gt 51200 ] || continue
      id=$(basename "$f" .task)
      sfile="$tdir/${id}.status"
      [ -f "$sfile" ] || continue
      st=$(head -1 "$sfile" 2>/dev/null | tr -d ' \n' || true)
      case "$st" in
        done|cancelled|failed)
          count=$((count + 1))
          printf '  %s  (%d KB, status=%s)\n' "$(basename "$f")" $((sz / 1024)) "$st"
          ;;
      esac
    done
    printf '  Total: %d\n' "$count"
  fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
audit_panes
audit_shared_overhead
audit_msg_pollution
audit_task_files
audit_duplicate_rules
compute_score

case "$MODE" in
  diff)
    do_diff
    exit 0
    ;;
  autofix)
    render_report
    printf '\n%s--- AUTO-FIX ---%s\n\n' "$BOLD" "$RST"
    do_auto_fix
    exit 0
    ;;
  report)
    if $JSON; then render_json; else render_report; fi
    if [ "$SCORE" -ge 90 ]; then exit 0; else exit 1; fi
    ;;
esac
