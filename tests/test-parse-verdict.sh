#!/usr/bin/env bash
# test-parse-verdict.sh — regression sweep for shell/masterplan-review-loop.sh::_parse_verdict
#
# Verifies the parser accepts BOTH canonical verdict forms:
#   **Verdict:** APPROVE | REVISE   (markdown-bold canonical form)
#   VERDICT: APPROVE | REVISE       (legacy one-line form)
# is case-insensitive, whitespace tolerant, and returns the LAST occurrence
# in the file (so multi-round verdict files return the most recent verdict).
#
# Also sweeps any real verdict files at /tmp/doey/doey/masterplan-*/.{architect,critic}.md
# if they exist — asserting the parser returns APPROVE, REVISE, or empty (NEVER an error).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOOP_FILE="${REPO_DIR}/shell/masterplan-review-loop.sh"

if [ ! -f "$LOOP_FILE" ]; then
  printf 'FAIL: cannot find %s\n' "$LOOP_FILE" >&2
  exit 1
fi

# The loop file requires PLAN_DIR/PLAN_FILE at source-time (line 27-28).
# Set sentinel values so sourcing succeeds — we only call _parse_verdict.
PLAN_DIR="$(mktemp -d -t parse-verdict-XXXXXX)"
PLAN_FILE="${PLAN_DIR}/dummy.md"
: > "$PLAN_FILE"
export PLAN_DIR PLAN_FILE

# Source masterplan-consensus.sh dependency may also be required — check.
# masterplan-review-loop.sh sources it via _SELF_DIR; that should resolve.
# shellcheck disable=SC1090
. "$LOOP_FILE"

if ! declare -f _parse_verdict >/dev/null 2>&1; then
  printf 'FAIL: _parse_verdict function not exposed after sourcing %s\n' "$LOOP_FILE" >&2
  exit 1
fi

FIXTURE_DIR="$(mktemp -d -t verdict-fixtures-XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR" "$PLAN_DIR" 2>/dev/null || true' EXIT

PASS=0
FAIL=0
TOTAL=0

_assert_verdict() {
  local label="$1" content="$2" expected="$3"
  local fpath got rc
  TOTAL=$((TOTAL + 1))
  fpath="${FIXTURE_DIR}/case-${TOTAL}.md"
  printf '%s' "$content" > "$fpath"
  set +e
  got="$(_parse_verdict "$fpath" 2>/dev/null)"
  rc=$?
  set -e
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS + 1))
    printf '  PASS [%s] -> %q (rc=%d)\n' "$label" "$got" "$rc"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL [%s] expected=%q got=%q (rc=%d)\n' "$label" "$expected" "$got" "$rc" >&2
  fi
}

_assert_empty() {
  local label="$1" content="$2"
  local fpath got rc
  TOTAL=$((TOTAL + 1))
  fpath="${FIXTURE_DIR}/case-${TOTAL}.md"
  printf '%s' "$content" > "$fpath"
  set +e
  got="$(_parse_verdict "$fpath" 2>/dev/null)"
  rc=$?
  set -e
  if [ -z "$got" ] && [ "$rc" -ne 0 ]; then
    PASS=$((PASS + 1))
    printf '  PASS [%s] -> empty (rc=%d)\n' "$label" "$rc"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL [%s] expected empty+nonzero got=%q rc=%d\n' "$label" "$got" "$rc" >&2
  fi
}

printf '== Fixture sweep ==\n'

_assert_verdict "markdown-bold APPROVE" \
"# Review

Some prose.

**Verdict:** APPROVE

Trailing notes.
" "APPROVE"

_assert_verdict "markdown-bold REVISE" \
"# Review

**Verdict:** REVISE

Required changes:
1. fix this
" "REVISE"

_assert_verdict "legacy VERDICT: APPROVE" \
"Review body.

VERDICT: APPROVE
" "APPROVE"

_assert_verdict "legacy VERDICT: REVISE" \
"Review body.

VERDICT: REVISE
" "REVISE"

_assert_verdict "mixed-case verdict word (Approve)" \
"**Verdict:** Approve
" "APPROVE"

_assert_verdict "mixed-case verdict word (revise)" \
"verdict: revise
" "REVISE"

_assert_verdict "extra whitespace tolerant" \
"   **Verdict:**     APPROVE
" "APPROVE"

_assert_verdict "multi-round file: last verdict wins (REVISE then APPROVE)" \
"## Round 1

**Verdict:** REVISE

required: fix the foo

## Round 2

**Verdict:** APPROVE

Looks good now.
" "APPROVE"

_assert_verdict "multi-round file: legacy then markdown" \
"VERDICT: APPROVE

(round 2 below)

**Verdict:** REVISE
" "REVISE"

_assert_empty "no verdict line" \
"# Review

Some prose without any verdict marker.

The end.
"

_assert_empty "verdict word without keyword" \
"APPROVE this should not match alone

REVISE this either
"

_assert_empty "empty file" ""

printf '\n== Real-file sweep (best-effort) ==\n'
REAL_DIR="/tmp/doey/doey"
REAL_COUNT=0
if [ -d "$REAL_DIR" ]; then
  for rf in "$REAL_DIR"/masterplan-*.architect.md "$REAL_DIR"/masterplan-*.critic.md \
            "$REAL_DIR"/masterplan-*/*.architect.md "$REAL_DIR"/masterplan-*/*.critic.md; do
    [ -f "$rf" ] || continue
    REAL_COUNT=$((REAL_COUNT + 1))
    TOTAL=$((TOTAL + 1))
    set +e
    rgot="$(_parse_verdict "$rf" 2>/dev/null)"
    rc=$?
    set -e
    case "$rgot" in
      APPROVE|REVISE|"")
        PASS=$((PASS + 1))
        printf '  PASS [real:%s] -> %q (rc=%d)\n' "$(basename "$rf")" "$rgot" "$rc"
        ;;
      *)
        FAIL=$((FAIL + 1))
        printf '  FAIL [real:%s] unexpected output %q (rc=%d)\n' "$(basename "$rf")" "$rgot" "$rc" >&2
        ;;
    esac
  done
fi
if [ "$REAL_COUNT" -eq 0 ]; then
  printf '  (no real verdict files found — skipping)\n'
fi

printf '\nPASS: %d/%d\n' "$PASS" "$TOTAL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
