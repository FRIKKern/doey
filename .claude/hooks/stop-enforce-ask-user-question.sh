#!/usr/bin/env bash
# stop-enforce-ask-user-question.sh — enforces AskUserQuestion for Boss + Planner
# Modes (DOEY_ENFORCE_QUESTIONS): shadow (default, log only), block (exit 2 + reason), off (no-op)
# Retry cap infrastructure is DORMANT in shadow — exercised only by tests via env override.
# Interviewer role is out-of-scope (has its own allow-clause in on-pre-tool-use.sh).
# Stop-hook position: LAST in the Stop array, after stop-plan-tracking.sh.
# Fail-open: any error → exit 0 via ERR trap.
set -euo pipefail
source "$(dirname "$0")/common.sh"
init_named_hook "enforce-askuserquestion"

mkdir -p "${RUNTIME_DIR}/errors" 2>/dev/null || true
trap '_err=$?; printf "[%s] ERR in enforce-askuserquestion line %s exit %s\n" "$(date +%H:%M:%S)" "$LINENO" "$_err" >> "${RUNTIME_DIR}/errors/errors.log" 2>/dev/null; exit 0' ERR

# --- Early-exit ladder ---

# 1. Re-entry guard — never recurse into ourselves
stop_hook_active=$(parse_field stop_hook_active)
[ "$stop_hook_active" = "true" ] && exit 0

# 2. Mode gate (common.sh normalizes; defensive here)
case "$DOEY_ENFORCE_QUESTIONS" in
  off) exit 0 ;;
  shadow|block) ;;
  *) exit 0 ;;
esac

# 3. Role gate — only Boss and Planner are in scope
is_boss_or_planner || exit 0

# 4. Transcript must exist and be readable
TRANSCRIPT=$(parse_field transcript_path)
[ -z "$TRANSCRIPT" ] && exit 0
[ ! -r "$TRANSCRIPT" ] && exit 0

# --- Extract last assistant message (macOS-safe — NO tac, NO break in pipeline) ---
LAST_ASSISTANT=$(tail -n 50 "$TRANSCRIPT" 2>/dev/null | jq -c 'select(.type=="assistant")' 2>/dev/null | tail -1 || true)
[ -z "$LAST_ASSISTANT" ] && exit 0

# Counter counts CONSECUTIVE USER TURNS with violations (not Claude Code retries within a turn).
# Incremented only on non-re-entry + role-gate-pass + violation-detected + block-mode path.
# Cleared on any non-re-entry + role-gate-pass + NOT-violation path (tool_use short-circuit OR clean text scan).
# Re-entry path (stop_hook_active=true) never touches the counter.
COUNTER_FILE="${RUNTIME_DIR}/status/enforce-retry-${PANE_SAFE}.count"

# --- Compliant short-circuit: last assistant message already called AskUserQuestion ---
HAS_AUQ=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.content[]? | select(.type=="tool_use" and .name=="AskUserQuestion") | .name' 2>/dev/null | head -1 || true)
if [ -n "$HAS_AUQ" ]; then
  rm -f "$COUNTER_FILE" 2>/dev/null || true
  exit 0
fi

# --- Text extraction: last non-empty line of final text block ---
LAST_TEXT=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null | tail -n 1 || true)
LAST_LINE=$(printf '%s' "$LAST_TEXT" | awk 'NF{line=$0} END{print line}')
[ -z "$LAST_LINE" ] && { rm -f "$COUNTER_FILE" 2>/dev/null || true; exit 0; }

# --- Normalize + detect ---

# Condition A: trimmed line ends with ? or fullwidth ？ (LC_ALL=C for byte-safe fullwidth match)
COND_A=false
if LC_ALL=C printf '%s' "$LAST_LINE" | grep -Eq '[?？][[:space:]]*$'; then
  COND_A=true
fi

# Normalize: lowercase, strip trailing [?？] and whitespace
NORMALIZED=$(printf '%s' "$LAST_LINE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[?？]+[[:space:]]*$//; s/[[:space:]]+$//')

# Condition B: long-form prefix OR short-form exact match
COND_B=false
case "$NORMALIZED" in
  'should i '*|'should i'|'do you '*|'do you'|'would you '*|'would you'|'which '*|'which'|'can you '*|'can you'|'can i '*|'can i'|'want me to '*|'want me to'|'or '*) COND_B=true ;;
  ready|proceed|confirm|'sound good'|ok|'yes or no') COND_B=true ;;
esac

VIOLATION=false
if [ "$COND_A" = true ] && [ "$COND_B" = true ]; then
  VIOLATION=true
fi

# --- Action branches ---

if [ "$VIOLATION" != true ]; then
  rm -f "$COUNTER_FILE" 2>/dev/null || true
  exit 0
fi

EXCERPT=$(printf '%s' "$LAST_LINE" | _strip_excerpt)
if is_boss; then ROLE=boss; else ROLE=planner; fi
TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
SESSION_ID=$(parse_field session_id)

# Shadow branch: log-only, never blocks
if [ "$DOEY_ENFORCE_QUESTIONS" = shadow ]; then
  VD=$(_violations_dir) || exit 0
  mkdir -p "$VD" 2>/dev/null || true
  printf '{"ts":"%s","role":"%s","session":"%s","pane":"%s","excerpt":"%s","tier":1,"mode":"shadow"}\n' \
    "$TS" "$ROLE" "$SESSION_ID" "$PANE_SAFE" "$EXCERPT" >> "$VD/ask-user-question.jsonl"
  exit 0
fi

# Block branch (dormant until tests flip DOEY_ENFORCE_QUESTIONS=block)
if [ "$DOEY_ENFORCE_QUESTIONS" = block ]; then
  CURRENT=0
  [ -f "$COUNTER_FILE" ] && CURRENT=$(cat "$COUNTER_FILE" 2>/dev/null || printf 0)
  CURRENT=$((CURRENT + 1))
  if [ "$CURRENT" -ge 3 ]; then
    # 3rd consecutive — downgrade to warn, clear counter, pass through
    VD=$(_violations_dir) || exit 0
    mkdir -p "$VD" 2>/dev/null || true
    printf '{"ts":"%s","role":"%s","session":"%s","pane":"%s","excerpt":"%s","tier":1,"mode":"warn"}\n' \
      "$TS" "$ROLE" "$SESSION_ID" "$PANE_SAFE" "$EXCERPT" >> "$VD/ask-user-question.jsonl"
    rm -f "$COUNTER_FILE" 2>/dev/null || true
    exit 0
  fi
  printf '%s' "$CURRENT" > "$COUNTER_FILE"
  VD=$(_violations_dir) || VD=""
  if [ -n "$VD" ]; then
    mkdir -p "$VD" 2>/dev/null || true
    printf '{"ts":"%s","role":"%s","session":"%s","pane":"%s","excerpt":"%s","tier":1,"mode":"block"}\n' \
      "$TS" "$ROLE" "$SESSION_ID" "$PANE_SAFE" "$EXCERPT" >> "$VD/ask-user-question.jsonl"
  fi
  REASON="BLOCKED: response ends with question, didnt call AskUserQuestion. Detected: $EXCERPT. Retry with AskUserQuestion (up to 4 questions, 2-4 options each)."
  printf '%s\n' "$REASON" >&2
  printf '{"decision":"block","reason":"%s"}\n' "$REASON"
  exit 2
fi

exit 0
