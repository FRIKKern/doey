#!/usr/bin/env bash
# shell/openclaw-event-router.sh — Phase 3 outbound event classifier and
# payload builder for the OpenClaw integration.
#
# Library only. No network calls, no file writes. Pure stdin/stdout.
# Bash 3.2 compatible.
#
# Two output shapes:
#   compact — single-line plaintext (≤ 200 chars), for high-volume worker
#             progress noise.
#   embed   — Discord embed JSON, for Boss / error / question / lifecycle
#             (high-signal, low-volume).
#
# Buttons are out of scope for v1.0 (text replies only).
set -euo pipefail

# ── Classification ────────────────────────────────────────────────────
# oc_classify_event <event_kind>
#   Echoes "compact" or "embed". Unknown kinds default to "embed" — safe
#   default since unknowns are likely high-signal.
oc_classify_event() {
  local kind="${1:-}"
  case "$kind" in
    worker_progress|worker_busy|status_change)
      printf 'compact' ;;
    boss_event|error|question|lifecycle|start|finish|crash)
      printf 'embed' ;;
    *)
      printf 'embed' ;;
  esac
}

# ── Compact builder ───────────────────────────────────────────────────
# oc_build_compact <task_id> <role> <summary>
#   Echoes a single line: "[T<task_id>·<role>] <summary>" truncated to
#   200 chars total. Newlines in summary are collapsed to spaces.
oc_build_compact() {
  local task_id="${1:-}"
  local role="${2:-}"
  local summary="${3:-}"
  # Collapse newlines/tabs to single spaces, strip carriage returns.
  summary=$(printf '%s' "$summary" | tr '\n\r\t' '   ')
  local line
  line="[T${task_id}·${role}] ${summary}"
  # Hard cap at 200 chars (POSIX ${#var} counts bytes; OK for ASCII summaries).
  if [ "${#line}" -gt 200 ]; then
    line="${line:0:197}..."
  fi
  printf '%s' "$line"
}

# ── Embed builder ─────────────────────────────────────────────────────
# oc_build_embed <kind> <task_id> <role> <title> <body> [color]
#   Echoes a JSON Discord embed object. Body is truncated to 4096 chars
#   (Discord embed description limit). Default colors per kind:
#     error      -> 15158332 (red)
#     question   -> 3447003  (blue)
#     lifecycle  -> 3066993  (green)
#     boss_event -> 10181046 (purple)
#     other      -> 10070709 (neutral grey-purple)
#
# JSON construction is delegated to python3 to get correct escaping for
# arbitrary unicode and embedded quotes/newlines without reimplementing
# JSON in shell. python3 is already a hard dependency of the OpenClaw
# integration (see tests/openclaw-hmac-shell.sh).
oc_build_embed() {
  local kind="${1:-generic}"
  local task_id="${2:-}"
  local role="${3:-}"
  local title="${4:-}"
  local body="${5:-}"
  local color="${6:-}"

  if [ -z "$color" ]; then
    case "$kind" in
      error)      color=15158332 ;;
      question)   color=3447003 ;;
      lifecycle|start|finish|crash) color=3066993 ;;
      boss_event) color=10181046 ;;
      *)          color=10070709 ;;
    esac
  fi

  OC_KIND="$kind" \
  OC_TASK_ID="$task_id" \
  OC_ROLE="$role" \
  OC_TITLE="$title" \
  OC_BODY="$body" \
  OC_COLOR="$color" \
  python3 -c '
import json, os
body = os.environ.get("OC_BODY", "")
if len(body) > 4096:
    body = body[:4093] + "..."
embed = {
    "title": os.environ.get("OC_TITLE", ""),
    "description": body,
    "color": int(os.environ.get("OC_COLOR", "0") or "0"),
    "fields": [
        {"name": "task_id", "value": os.environ.get("OC_TASK_ID", ""), "inline": True},
        {"name": "role",    "value": os.environ.get("OC_ROLE", ""),    "inline": True},
        {"name": "kind",    "value": os.environ.get("OC_KIND", ""),    "inline": True},
    ],
}
print(json.dumps(embed, indent=2, ensure_ascii=False))
'
}

# ── Self-test ─────────────────────────────────────────────────────────
# oc_event_router_test_self
#   Quick smoke test. Echoes "PASS" or "FAIL: <reason>".
oc_event_router_test_self() {
  local got

  got=$(oc_classify_event worker_progress)
  if [ "$got" != "compact" ]; then
    echo "FAIL: worker_progress should be compact, got $got"; return 1
  fi
  got=$(oc_classify_event question)
  if [ "$got" != "embed" ]; then
    echo "FAIL: question should be embed, got $got"; return 1
  fi
  got=$(oc_classify_event totally_unknown_kind_xyz)
  if [ "$got" != "embed" ]; then
    echo "FAIL: unknown kind should default to embed, got $got"; return 1
  fi

  got=$(oc_build_compact 42 worker "ran tests")
  case "$got" in
    "[T42·worker] ran tests") : ;;
    *) echo "FAIL: compact mismatch: $got"; return 1 ;;
  esac
  if [ "${#got}" -gt 200 ]; then
    echo "FAIL: compact exceeds 200 chars"; return 1
  fi

  got=$(oc_build_embed question 1 boss "T" "B" 2>/dev/null || true)
  case "$got" in
    *'"title": "T"'*) : ;;
    *) echo "FAIL: embed missing title"; return 1 ;;
  esac
  case "$got" in
    *'"color": 3447003'*) : ;;
    *) echo "FAIL: embed missing default question color"; return 1 ;;
  esac

  echo "PASS"
  return 0
}
