#!/usr/bin/env bash
# shell/openclaw-redact.sh — redact Authorization headers and tokens from
# stderr / xtrace output so `set -x` traces never leak credentials.
#
# Library only. Source it; it defines functions, sets no globals beyond
# the function names. Bash 3.2 compatible (no BASH_XTRACEFD, no associative
# arrays, no process substitution capture quirks).
#
# Public API:
#   oc_redact_string <s>          — echo s with Authorization/token redacted
#   oc_redact_trace_setup         — wire current shell's stderr through the
#                                   redaction filter (affects subsequent
#                                   `set -x` output too)
#   oc_redact_self_test           — internal smoke test, exits 0 on PASS

# ── Internal sed filter ───────────────────────────────────────────────
# Reads stdin, writes stdout. Three substitutions:
#   1. "Authorization: Bearer XXX"   → "Authorization: Bearer <REDACTED>"
#   2. "token=XXX"                   → "token=<REDACTED>"
#   3. "--header Authorization:XXX"  → "--header Authorization:<REDACTED>"
# Bash 3.2 shells on macOS ship BSD sed; we stick to portable -E syntax.
_oc_redact_filter() {
  sed -E \
    -e 's/Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._~+/=-]+/Authorization: Bearer <REDACTED>/g' \
    -e 's/token=[A-Za-z0-9._~+/=-]+/token=<REDACTED>/g' \
    -e 's/(--header[[:space:]]+Authorization:)[^[:space:]]*/\1<REDACTED>/g'
}

# ── oc_redact_string <s> ──────────────────────────────────────────────
oc_redact_string() {
  printf '%s' "${1:-}" | _oc_redact_filter
}

# ── oc_redact_trace_setup ─────────────────────────────────────────────
# Redirect this shell's stderr through the redaction filter. After this
# call, any `set -x` trace lines (which bash writes to fd 2) pass through
# the filter before reaching the real stderr.
#
# Note: bash 3.2 lacks BASH_XTRACEFD, so we cannot redirect xtrace alone —
# we redirect ALL of fd 2. Callers who need a different policy should run
# the noisy block in a subshell with its own redirection instead.
oc_redact_trace_setup() {
  # Guard: if BASH_XTRACEFD is supported (bash 4+), prefer redirecting
  # only the xtrace fd. Otherwise fall back to fd 2 wholesale.
  if [ -n "${BASH_VERSINFO+x}" ] && [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    # bash 4+: route xtrace through a dedicated fd that flows into the filter.
    exec 9> >(_oc_redact_filter >&2)
    BASH_XTRACEFD=9
  else
    exec 2> >(_oc_redact_filter >&2)
  fi
}

# ── oc_redact_self_test ───────────────────────────────────────────────
# Runs a synthetic `set -x` block containing canary tokens and asserts
# that neither canary survives the redaction filter. Returns 0 on PASS,
# 1 on FAIL.
oc_redact_self_test() {
  local canary_h='ZZZZ-AUTH-CANARY-SELFTEST'
  local canary_t='ZZZZ-TOKEN-CANARY-SELFTEST'
  local captured
  captured=$(
    {
      set -x
      _hdr="Authorization: Bearer $canary_h"
      _body="token=$canary_t&kind=question"
      _flag="--header Authorization:Bearer-$canary_h"
      : "$_hdr" "$_body" "$_flag"
      set +x
    } 2>&1 1>/dev/null | _oc_redact_filter
  )
  if printf '%s' "$captured" | grep -qE "$canary_h|$canary_t"; then
    printf 'FAIL: canary leaked through redaction\n%s\n' "$captured" >&2
    return 1
  fi
  if ! printf '%s' "$captured" | grep -q '<REDACTED>'; then
    printf 'FAIL: no <REDACTED> markers — filter may not have run\n%s\n' "$captured" >&2
    return 1
  fi
  return 0
}
