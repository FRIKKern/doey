#!/usr/bin/env bash
# test-unread-audit.sh — regression guard for task #525 polling-loop bug class
#
# Scans agent templates and team definitions for the bad pattern
# "doey msg read --pane X" without "--unread" and without a nearby
# "read-all"/"mark-read" (the canonical Taskmaster two-step form).
#
# EXPECTED BEHAVIOR (task #539 notes):
#   - On a tree where task #531 has landed (all 7 fixes in place):
#       test exits 0, "PASS: zero offenders."
#   - On `main` before #531 lands (or on any branch that reverts a fix):
#       test exits 1 and lists offenders. This is the INTENDED regression
#       signal — do NOT weaken the whitelist to make the test pass.
#
# Whitelist: agents/doey-taskmaster.md.tmpl contains the intentional
# non-`--unread` form because it is followed by an explicit `read-all`.
# A ±5-line proximity check for `read-all`/`mark-read` also exempts any
# future site that adopts the two-step form.
#
# Bash 3.2 compatible.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Files to scan
TEMPLATE_GLOBS="agents/*.md.tmpl teams/*.team.md"

# Whitelist — files permitted to contain the bad-looking pattern because
# their surrounding prose documents the two-step Taskmaster form.
WHITELIST_FILES="agents/doey-taskmaster.md.tmpl"

# ±N lines of context to search for read-all/mark-read proof
CONTEXT_LINES=5

# Expand the globs safely (bash 3.2: no nullglob in a portable way)
FILES=""
for _g in $TEMPLATE_GLOBS; do
    for _f in $_g; do
        [ -f "$_f" ] || continue
        FILES="${FILES} ${_f}"
    done
done

if [ -z "$FILES" ]; then
    echo "unread-audit: no files matched $TEMPLATE_GLOBS — nothing to scan" >&2
    exit 0
fi

# Count files for the header
_count=0
for _f in $FILES; do
    _count=$((_count + 1))
done

echo "unread-audit scanning ${_count} files..."

_is_whitelisted() {
    local _file="$1"
    local _w
    for _w in $WHITELIST_FILES; do
        [ "$_file" = "$_w" ] && return 0
    done
    return 1
}

# Check whether a ±CONTEXT_LINES window around $lineno in $file contains
# "read-all" or "mark-read".
_has_nearby_read_all() {
    local _file="$1"
    local _lineno="$2"
    local _start _end
    _start=$((_lineno - CONTEXT_LINES))
    _end=$((_lineno + CONTEXT_LINES))
    [ "$_start" -lt 1 ] && _start=1
    # sed range is inclusive; empty is fine
    sed -n "${_start},${_end}p" "$_file" 2>/dev/null \
        | grep -qE 'read-all|mark-read'
}

fail_count=0
offenders=""

# Primary scan: lines with "doey msg read" (word-boundary: followed by
# whitespace so "doey msg read-all" does NOT match) that also contain
# "--pane" but NOT "--unread".
for _file in $FILES; do
    # grep -n prints "LINENO:content"
    _hits=$(grep -nE 'doey msg read[[:space:]].*--pane' "$_file" 2>/dev/null || true)
    [ -n "$_hits" ] || continue

    # Walk each hit via a here-string so the outer shell state persists
    # (bash 3.2 compatible — no subshell, no lost fail_count)
    while IFS= read -r _hit; do
        [ -n "$_hit" ] || continue
        _lineno="${_hit%%:*}"
        _content="${_hit#*:}"

        # Skip if the line itself has --unread (false positive on the grep)
        case "$_content" in
            *--unread*) continue ;;
        esac

        # Whitelist file skip
        if _is_whitelisted "$_file"; then
            continue
        fi

        # Proximity skip: ±5 lines contain read-all/mark-read
        if _has_nearby_read_all "$_file" "$_lineno"; then
            continue
        fi

        # Real offender
        _snippet="${_content# }"
        # Trim overly long lines for output
        if [ "${#_snippet}" -gt 120 ]; then
            _snippet="${_snippet:0:117}..."
        fi
        offenders="${offenders}OFFENDER: ${_file}:${_lineno}: ${_snippet}
"
        fail_count=$((fail_count + 1))
    done <<< "$_hits"
done

if [ "$fail_count" -gt 0 ]; then
    printf '%s' "$offenders"
    echo ""
    echo "=== Unread Audit: ${fail_count} offender(s) found ==="
    echo "FAIL: one or more files run \`doey msg read --pane\` without \`--unread\`"
    echo "      and without a nearby read-all/mark-read. See docs/violations.md"
    echo "      for the canonical fix (append \`--unread\` to the call)."
    exit 1
fi

echo ""
echo "=== Unread Audit: ${_count} files, 0 offenders ==="
echo "PASS"
exit 0
