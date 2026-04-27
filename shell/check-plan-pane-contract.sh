#!/usr/bin/env bash
# check-plan-pane-contract.sh — Plan-pane file-contract validator.
#
# Validates the file tree the doey-masterplan-tui Plan pane reads.
# See docs/plan-pane-contract.md for the canonical specification.
#
# Modes:
#   - Fixture sweep (always): validates every scenario under
#     --fixtures-dir. Fails the run on any drift.
#   - Live sweep (skip when no runtime): validates every masterplan-*
#     dir under --runtime-dir. Skipped silently when no live runtime
#     exists (the install-time / fresh-install path).
#
# Exit 0 on pass, non-zero on drift. Diagnostics on stderr in plain
# mode; one JSON object on stdout in --json mode.
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no bash-4.2
# printf time-format. POSIX find/grep/awk/sed only.

set -euo pipefail

# ── argv parsing ─────────────────────────────────────────────────────

FIXTURES_DIR=""
RUNTIME_DIR=""
QUIET=false
JSON=false

usage() {
  cat <<'USAGE'
Usage: check-plan-pane-contract.sh [options]

  --fixtures-dir <dir>  Directory containing fixture scenarios.
                        Default: $DOEY_REPO_DIR/tui/internal/planview/testdata/fixtures
  --runtime-dir <dir>   Runtime base. Default: $DOEY_RUNTIME or /tmp/doey/<basename(pwd)>
  --quiet               Suppress info output, keep only errors.
  --json                Emit a single JSON object describing the run.
  -h, --help            This help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixtures-dir)
      FIXTURES_DIR="${2:-}"
      shift 2
      ;;
    --runtime-dir)
      RUNTIME_DIR="${2:-}"
      shift 2
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    --json)
      JSON=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'check-plan-pane-contract.sh: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ── default paths ────────────────────────────────────────────────────

if [ -z "$FIXTURES_DIR" ]; then
  if [ -n "${DOEY_REPO_DIR:-}" ] && [ -d "$DOEY_REPO_DIR/tui/internal/planview/testdata/fixtures" ]; then
    FIXTURES_DIR="$DOEY_REPO_DIR/tui/internal/planview/testdata/fixtures"
  else
    SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
    REPO_GUESS="$(cd "$SELF_DIR/.." && pwd)"
    FIXTURES_DIR="$REPO_GUESS/tui/internal/planview/testdata/fixtures"
  fi
fi

if [ -z "$RUNTIME_DIR" ]; then
  if [ -n "${DOEY_RUNTIME:-}" ]; then
    RUNTIME_DIR="$DOEY_RUNTIME"
  else
    BASENAME_PWD="$(basename "$(pwd)")"
    RUNTIME_DIR="/tmp/doey/$BASENAME_PWD"
  fi
fi

# ── output helpers ───────────────────────────────────────────────────

_info() {
  if [ "$QUIET" = false ] && [ "$JSON" = false ]; then
    printf '%s\n' "$1" >&2
  fi
}

ERRORS_FILE="$(mktemp -t plan-pane-contract.errors.XXXXXX)"
FIXTURES_RESULT_FILE="$(mktemp -t plan-pane-contract.fixtures.XXXXXX)"
LIVE_RESULT_FILE="$(mktemp -t plan-pane-contract.live.XXXXXX)"
trap 'rm -f "$ERRORS_FILE" "$FIXTURES_RESULT_FILE" "$LIVE_RESULT_FILE"' EXIT

_err() {
  # one diagnostic per invocation; aggregated for --json
  local path="$1" msg="$2"
  printf '%s: %s\n' "$path" "$msg" >> "$ERRORS_FILE"
  if [ "$JSON" = false ]; then
    printf '%s: %s\n' "$path" "$msg" >&2
  fi
}

_record_target() {
  # _record_target <fixtures|live> <name> <path> <ok 0/1>
  local kind="$1" name="$2" path="$3" ok="$4"
  case "$kind" in
    fixtures) printf '%s\t%s\t%s\n' "$name" "$path" "$ok" >> "$FIXTURES_RESULT_FILE" ;;
    live)     printf '%s\t%s\t%s\n' "$name" "$path" "$ok" >> "$LIVE_RESULT_FILE" ;;
  esac
}

# ── shape checks ─────────────────────────────────────────────────────

# valid CONSENSUS_STATE values; APPROVED is accepted as alias of CONSENSUS
_consensus_state_valid() {
  case "$1" in
    DRAFT|UNDER_REVIEW|REVISIONS_NEEDED|CONSENSUS|APPROVED|ESCALATED) return 0 ;;
    *) return 1 ;;
  esac
}

# _read_consensus_state <state-file> → echoes uppercased CONSENSUS_STATE value
_read_consensus_state() {
  local file="$1"
  [ -f "$file" ] || return 1
  local line
  line="$(grep -E '^[[:space:]]*CONSENSUS_STATE[[:space:]]*=' "$file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 1
  local val
  val="${line#*=}"
  # strip surrounding quotes / whitespace
  val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  printf '%s' "$val" | tr '[:lower:]' '[:upper:]'
}

# _verdict_file_has_keyword <file> <APPROVE|REVISE> → 0 if present, 1 otherwise
_verdict_file_has_keyword() {
  local file="$1" keyword="$2"
  [ -f "$file" ] || return 1
  # Accepted forms (case-insensitive on keyword):
  #   **Verdict:** KEYWORD
  #   Verdict: KEYWORD
  #   VERDICT: KEYWORD
  grep -iqE '^[[:space:]]*(\*\*)?[[:space:]]*verdict[[:space:]]*:?[[:space:]]*(\*\*)?[[:space:]]*:?[[:space:]]*'"$keyword"'\b' "$file"
}

# _find_verdict_file <plan-dir> <role> → echoes path if found, returns 1 otherwise
_find_verdict_file() {
  local plan_dir="$1" role="$2"
  # Fixture layout: verdicts/<role>.md
  local candidate="$plan_dir/verdicts/$role.md"
  if [ -f "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  # Live layout: <plan-dir>/<plan-id>.<role>.md
  local match
  # use find rather than glob to stay zsh-safe and avoid nullglob assumptions
  match="$(find "$plan_dir" -maxdepth 1 -type f -name "*.${role}.md" 2>/dev/null | head -1 || true)"
  if [ -n "$match" ]; then
    printf '%s' "$match"
    return 0
  fi
  return 1
}

# _check_plan_md <plan-dir> <name> → 0 ok, 1 fail
_check_plan_md() {
  local plan_dir="$1" name="$2"
  local plan_md="$plan_dir/plan.md"
  if [ ! -f "$plan_md" ]; then
    _err "$name" "plan.md missing at $plan_md"
    return 1
  fi
  if ! grep -qE '^---' "$plan_md"; then
    _err "$plan_md" "missing YAML frontmatter delimiter (^---)"
    return 1
  fi
  if ! grep -qE '^### Phase ' "$plan_md"; then
    _err "$plan_md" "no '### Phase ' heading found"
    return 1
  fi
  return 0
}

# _check_consensus_state <plan-dir> <name> → echoes state (or empty), returns rc
_check_consensus_state() {
  local plan_dir="$1" name="$2"
  local state_file="$plan_dir/consensus.state"
  if [ ! -f "$state_file" ]; then
    _err "$name" "consensus.state missing at $state_file"
    return 1
  fi
  local state
  state="$(_read_consensus_state "$state_file" || true)"
  if [ -z "$state" ]; then
    _err "$state_file" "no CONSENSUS_STATE= line"
    return 1
  fi
  if ! _consensus_state_valid "$state"; then
    _err "$state_file" "invalid CONSENSUS_STATE value: $state"
    return 1
  fi
  printf '%s' "$state"
  return 0
}

# _check_verdicts_for_state <plan-dir> <state> <name> → 0 ok, 1 fail
_check_verdicts_for_state() {
  local plan_dir="$1" state="$2" name="$3"
  local arch_path crit_path
  arch_path="$(_find_verdict_file "$plan_dir" "architect" || true)"
  crit_path="$(_find_verdict_file "$plan_dir" "critic" || true)"
  case "$state" in
    CONSENSUS|APPROVED)
      if [ -z "$arch_path" ]; then
        _err "$name" "state=$state requires architect verdict file (verdicts/architect.md or *.architect.md)"
        return 1
      fi
      if [ -z "$crit_path" ]; then
        _err "$name" "state=$state requires critic verdict file (verdicts/critic.md or *.critic.md)"
        return 1
      fi
      if ! _verdict_file_has_keyword "$arch_path" "approve"; then
        _err "$arch_path" "state=$state but no 'Verdict: APPROVE' line found"
        return 1
      fi
      if ! _verdict_file_has_keyword "$crit_path" "approve"; then
        _err "$crit_path" "state=$state but no 'Verdict: APPROVE' line found"
        return 1
      fi
      ;;
    ESCALATED)
      if [ -z "$arch_path" ] && [ -z "$crit_path" ]; then
        _err "$name" "state=ESCALATED requires at least one verdict file"
        return 1
      fi
      ;;
    *)
      :  # other states impose no verdict-file requirement
      ;;
  esac
  return 0
}

# _check_status_dir <plan-dir> <name> → 0 ok, 1 fail
_check_status_dir() {
  local plan_dir="$1" name="$2"
  local status_dir="$plan_dir/status"
  if [ ! -d "$status_dir" ]; then
    _err "$name" "status/ directory missing at $status_dir"
    return 1
  fi
  local first
  first="$(find "$status_dir" -maxdepth 1 -type f -name '*.status' 2>/dev/null | head -1 || true)"
  if [ -z "$first" ]; then
    _err "$status_dir" "no *.status files in status/"
    return 1
  fi
  # The live parser (planview/live.go parseWorkerStatus) keys off STATUS;
  # PANE/UPDATED/SINCE/LAST_ACTIVITY are recommended for live runtime
  # but only STATUS: is enforced here so minimal fixtures stay legal.
  if ! grep -qE '^[[:space:]]*STATUS[[:space:]]*:' "$first"; then
    _err "$first" "missing required key 'STATUS:'"
    return 1
  fi
  return 0
}

# _validate_target <plan-dir> <name> → 0 ok, 1 fail
_validate_target() {
  local plan_dir="$1" name="$2"
  local rc=0
  _check_plan_md "$plan_dir" "$name" || rc=1
  local state=""
  state="$(_check_consensus_state "$plan_dir" "$name" || true)"
  if [ -z "$state" ]; then
    rc=1
  else
    _check_verdicts_for_state "$plan_dir" "$state" "$name" || rc=1
  fi
  _check_status_dir "$plan_dir" "$name" || rc=1
  return "$rc"
}

# ── fixture sweep ────────────────────────────────────────────────────

REQUIRED_FIXTURES="draft under_review revisions_needed consensus escalated stalled_reviewer"

if [ ! -d "$FIXTURES_DIR" ]; then
  _err "$FIXTURES_DIR" "fixtures directory not found"
fi

_info "fixture sweep: $FIXTURES_DIR"

for scenario in $REQUIRED_FIXTURES; do
  fix_path="$FIXTURES_DIR/$scenario"
  if [ ! -d "$fix_path" ]; then
    _err "$fix_path" "required fixture scenario missing: $scenario"
    _record_target fixtures "$scenario" "$fix_path" 0
    continue
  fi
  if _validate_target "$fix_path" "$scenario"; then
    _record_target fixtures "$scenario" "$fix_path" 1
    _info "  ok  $scenario"
  else
    _record_target fixtures "$scenario" "$fix_path" 0
  fi
done

# ── live sweep ───────────────────────────────────────────────────────

LIVE_FOUND=0
if [ -d "$RUNTIME_DIR" ]; then
  # find all masterplan-* dirs under the runtime base (1-level deep)
  for live_path in "$RUNTIME_DIR"/masterplan-*; do
    [ -d "$live_path" ] || continue
    LIVE_FOUND=$((LIVE_FOUND + 1))
    live_name="$(basename "$live_path")"
    if _validate_target "$live_path" "$live_name"; then
      _record_target live "$live_name" "$live_path" 1
      _info "  ok  live/$live_name"
    else
      _record_target live "$live_name" "$live_path" 0
    fi
  done
fi

if [ "$LIVE_FOUND" -eq 0 ]; then
  _info "no live runtime — skipping live checks"
fi

# ── report / exit ────────────────────────────────────────────────────

ERRCOUNT=0
if [ -s "$ERRORS_FILE" ]; then
  ERRCOUNT="$(wc -l < "$ERRORS_FILE" | tr -d ' ')"
fi

if [ "$JSON" = true ]; then
  # Build JSON manually — no jq dependency required.
  ok="true"
  [ "$ERRCOUNT" -gt 0 ] && ok="false"

  printf '{"ok":%s,"fixtures":[' "$ok"
  first=1
  while IFS=$'\t' read -r n p o; do
    [ -n "$n" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    if [ "$o" = "1" ]; then ostr="true"; else ostr="false"; fi
    printf '{"name":"%s","path":"%s","ok":%s}' "$n" "$p" "$ostr"
  done < "$FIXTURES_RESULT_FILE"
  printf '],"live":['
  first=1
  while IFS=$'\t' read -r n p o; do
    [ -n "$n" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    if [ "$o" = "1" ]; then ostr="true"; else ostr="false"; fi
    printf '{"name":"%s","path":"%s","ok":%s}' "$n" "$p" "$ostr"
  done < "$LIVE_RESULT_FILE"
  printf '],"errors":['
  first=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    # escape for JSON: replace \ then "
    escaped="$(printf '%s' "$line" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '"%s"' "$escaped"
  done < "$ERRORS_FILE"
  printf ']}\n'
fi

if [ "$ERRCOUNT" -gt 0 ]; then
  exit 1
fi
exit 0
