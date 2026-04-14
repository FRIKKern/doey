#!/usr/bin/env bash
# doey-agents.sh — Agent inventory & drift checker
#
# Subcommands:
#   check [--quiet] [--json] [--scope doey|all]
#
# Checks (Phase 1):
#   1. Inventory set-diff across three layers:
#      - agents/*.md.tmpl         (template)
#      - agents/*.md              (generated, not .tmpl)
#      - ~/.claude/agents/*.md    (installed)
#   2. Template→generated drift via `expand-templates.sh --check`.
#   3. Repo→installed byte-compare for agents present in both layers.
#
# Whitelist: `^t[0-9]+-` runtime team clones are never flagged.
# Exit codes: 0 clean · 1 drift · 2 infra error · 3 missing layer
set -euo pipefail

_DOEY_AGENTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DOEY_AGENTS_REPO_DIR="$(cd "$_DOEY_AGENTS_SCRIPT_DIR/.." && pwd)"

# Emit a line iff --quiet mode is off. Respects $_AGENTS_QUIET.
_agents_say() {
  [ "${_AGENTS_QUIET:-false}" = "true" ] && return 0
  printf '%s\n' "$*"
}

# Tests whether a bare basename (no extension) matches the runtime `tN-*`
# team-clone pattern that should NEVER be flagged as drift.
_agents_is_team_clone() {
  case "$1" in
    t[0-9]-*|t[0-9][0-9]-*|t[0-9][0-9][0-9]-*) return 0 ;;
  esac
  return 1
}

# Tests whether a bare basename is in scope. Scope: "doey" matches only
# `doey-*`; "all" matches `doey-*`, `seo-*`, `visual-*`, `settings-editor`,
# `test-driver`.
_agents_in_scope() {
  local name="$1" scope="$2"
  _agents_is_team_clone "$name" && return 1
  case "$name" in
    doey-*) return 0 ;;
  esac
  if [ "$scope" = "all" ]; then
    case "$name" in
      seo-*|visual-*|settings-editor|test-driver) return 0 ;;
    esac
  fi
  return 1
}

# Enumerate bare basenames in a layer. Layer is one of: tmpl|gen|inst.
# Prints one basename per line, filtered by scope, sorted.
_agents_enumerate_layer() {
  local layer="$1" scope="$2"
  local dir pattern ext
  case "$layer" in
    tmpl) dir="$_DOEY_AGENTS_REPO_DIR/agents"; ext=".md.tmpl" ;;
    gen)  dir="$_DOEY_AGENTS_REPO_DIR/agents"; ext=".md" ;;
    inst) dir="$HOME/.claude/agents";          ext=".md" ;;
    *) return 1 ;;
  esac
  [ -d "$dir" ] || return 0
  local f base
  for f in "$dir"/*"$ext"; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    base="${base%$ext}"
    # skip .md.tmpl when listing gen layer
    if [ "$layer" = "gen" ]; then
      case "$f" in *.md.tmpl) continue ;; esac
    fi
    _agents_in_scope "$base" "$scope" || continue
    printf '%s\n' "$base"
  done | LC_ALL=C sort -u
}

# Run expand-templates.sh --check and capture stale agent basenames.
# Writes basenames (one per line) to $1, returns status from expand-templates.
_agents_run_template_check() {
  local out_file="$1"
  : > "$out_file"
  local raw rc
  raw="$(bash "$_DOEY_AGENTS_SCRIPT_DIR/expand-templates.sh" --check 2>&1)" && rc=0 || rc=$?
  # Parse "STALE: agents/doey-foo.md ..." lines only; ignore skills/*.
  printf '%s\n' "$raw" \
    | awk '/^STALE: agents\// { sub(/^STALE: agents\//,""); sub(/ .*/,""); sub(/\.md$/,""); print }' \
    | LC_ALL=C sort -u > "$out_file"
  return $rc
}

# Render human-readable table row. $1 name, $2 tmpl, $3 gen, $4 inst, $5 sync,
# $6 issue text.
_agents_row() {
  printf '%-28s %s    %s    %s    %s    %s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

# JSON-escape a string for inclusion in a "..." value.
_agents_json_escape() {
  printf '%s' "$1" | awk '
    BEGIN { out="" }
    {
      line=$0
      gsub(/\\/,"\\\\",line)
      gsub(/"/,"\\\"",line)
      gsub(/\t/,"\\t",line)
      if (NR > 1) out = out "\\n"
      out = out line
    }
    END { printf "%s", out }
  '
}

doey_agents_check() {
  local scope="doey"
  local mode="table"
  _AGENTS_QUIET="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) _AGENTS_QUIET="true"; mode="quiet"; shift ;;
      --json)  mode="json"; shift ;;
      --scope) shift; scope="${1:-doey}"; shift ;;
      --scope=*) scope="${1#--scope=}"; shift ;;
      -h|--help)
        cat <<'USAGE'
Usage: doey agents check [--quiet] [--json] [--scope doey|all]

Checks agent drift across three layers:
  - agents/*.md.tmpl    (template)
  - agents/*.md         (generated)
  - ~/.claude/agents/   (installed)

Exit: 0 clean · 1 drift · 2 infra error · 3 missing layer
USAGE
        return 0
        ;;
      *) printf 'doey agents check: unknown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  case "$scope" in
    doey|all) ;;
    *) printf 'doey agents check: invalid --scope: %s (want doey|all)\n' "$scope" >&2; return 2 ;;
  esac

  # Layer enumeration --------------------------------------------------
  local tmp_dir tmpl_list gen_list inst_list stale_list
  tmp_dir="$(mktemp -d -t doey-agents.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN
  tmpl_list="$tmp_dir/tmpl" gen_list="$tmp_dir/gen" inst_list="$tmp_dir/inst" stale_list="$tmp_dir/stale"

  _agents_enumerate_layer tmpl "$scope" > "$tmpl_list"
  _agents_enumerate_layer gen  "$scope" > "$gen_list"
  _agents_enumerate_layer inst "$scope" > "$inst_list"

  local tmpl_n gen_n inst_n
  tmpl_n=$(wc -l < "$tmpl_list" | tr -d ' ')
  gen_n=$(wc -l < "$gen_list" | tr -d ' ')
  inst_n=$(wc -l < "$inst_list" | tr -d ' ')

  # Missing-layer detection (exit 3 only if ALL of a layer is missing)
  local layer_missing=0
  [ "$tmpl_n" -eq 0 ] && { printf 'doey agents check: no templates found in %s/agents/\n' "$_DOEY_AGENTS_REPO_DIR" >&2; layer_missing=1; }
  [ "$gen_n"  -eq 0 ] && { printf 'doey agents check: no generated .md found in %s/agents/\n' "$_DOEY_AGENTS_REPO_DIR" >&2; layer_missing=1; }
  [ ! -d "$HOME/.claude/agents" ] && { printf 'doey agents check: ~/.claude/agents/ does not exist — run install.sh\n' >&2; layer_missing=1; }
  [ "$layer_missing" -eq 1 ] && return 3

  # Template check -----------------------------------------------------
  local tcheck_rc=0
  _agents_run_template_check "$stale_list" || tcheck_rc=$?
  # rc 0 = clean, 1 = stale found, other = infra error
  if [ "$tcheck_rc" -ne 0 ] && [ "$tcheck_rc" -ne 1 ]; then
    printf 'doey agents check: expand-templates.sh failed (exit %d)\n' "$tcheck_rc" >&2
    return 2
  fi

  # Union of all agents we'll report on
  local all_list="$tmp_dir/all"
  LC_ALL=C sort -u "$tmpl_list" "$gen_list" "$inst_list" > "$all_list"

  local total_agents issue_count
  total_agents=$(wc -l < "$all_list" | tr -d ' ')
  issue_count=0

  # Per-agent analysis. Collect rows + JSON records.
  local rows_file="$tmp_dir/rows" json_file="$tmp_dir/json"
  : > "$rows_file"
  : > "$json_file"

  local name has_tmpl has_gen has_inst is_stale sync_ok issues glyph_t glyph_g glyph_i glyph_s
  local repo_path inst_path delta hint
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    has_tmpl="no" has_gen="no" has_inst="no" is_stale="no" sync_ok="yes"
    if LC_ALL=C grep -qxF "$name" "$tmpl_list"; then has_tmpl="yes"; fi
    if LC_ALL=C grep -qxF "$name" "$gen_list";  then has_gen="yes"; fi
    if LC_ALL=C grep -qxF "$name" "$inst_list"; then has_inst="yes"; fi
    if LC_ALL=C grep -qxF "$name" "$stale_list"; then is_stale="yes"; fi

    issues=""
    # Inventory issues
    if [ "$has_tmpl" = "no" ]; then issues="${issues}${issues:+; }missing template"; fi
    if [ "$has_gen"  = "no" ]; then issues="${issues}${issues:+; }missing generated"; fi
    if [ "$has_inst" = "no" ]; then issues="${issues}${issues:+; }not installed"; fi

    # Template staleness
    if [ "$is_stale" = "yes" ]; then
      issues="${issues}${issues:+; }template stale (run expand-templates.sh)"
    fi

    # Repo↔installed content diff (only when both sides exist)
    if [ "$has_gen" = "yes" ] && [ "$has_inst" = "yes" ]; then
      repo_path="$_DOEY_AGENTS_REPO_DIR/agents/${name}.md"
      inst_path="$HOME/.claude/agents/${name}.md"
      if ! cmp -s "$repo_path" "$inst_path"; then
        sync_ok="no"
        delta=$(diff -u "$repo_path" "$inst_path" 2>/dev/null | wc -l | tr -d ' ' || true)
        [ -z "$delta" ] && delta=0
        hint="installed differs (~${delta} diff lines) — run: doey update"
        issues="${issues}${issues:+; }${hint}"
      fi
    fi

    # Glyphs
    if [ "$has_tmpl" = "yes" ]; then glyph_t="✓"; else glyph_t="✗"; fi
    if [ "$has_gen"  = "yes" ] && [ "$is_stale" = "no" ]; then glyph_g="✓"; else glyph_g="✗"; fi
    if [ "$has_inst" = "yes" ]; then glyph_i="✓"; else glyph_i="✗"; fi
    if [ "$sync_ok"  = "yes" ] && [ "$has_gen" = "yes" ] && [ "$has_inst" = "yes" ]; then glyph_s="✓"; else glyph_s="✗"; fi

    if [ -n "$issues" ]; then
      issue_count=$((issue_count + 1))
      _agents_row "$name" "$glyph_t" "$glyph_g" "$glyph_i" "$glyph_s" "$issues" >> "$rows_file"
    else
      _agents_row "$name" "$glyph_t" "$glyph_g" "$glyph_i" "$glyph_s" "" >> "$rows_file"
    fi

    # JSON record
    {
      printf '    {'
      printf '"name":"%s",' "$name"
      printf '"tmpl":%s,'   "$([ "$has_tmpl" = yes ] && echo true || echo false)"
      printf '"gen":%s,'    "$([ "$has_gen"  = yes ] && echo true || echo false)"
      printf '"inst":%s,'   "$([ "$has_inst" = yes ] && echo true || echo false)"
      printf '"stale":%s,'  "$([ "$is_stale" = yes ] && echo true || echo false)"
      printf '"sync":%s,'   "$([ "$sync_ok"  = yes ] && echo true || echo false)"
      printf '"issues":"%s"' "$(_agents_json_escape "$issues")"
      printf '}'
    } >> "$json_file"
    echo "," >> "$json_file"
  done < "$all_list"

  # Strip trailing comma from JSON records file
  if [ -s "$json_file" ]; then
    # remove last line (the lone ",") then re-add without trailing comma
    local json_final="$tmp_dir/json_final"
    awk 'NR>1 { print prev } { prev=$0 } END { sub(/,$/,"",prev); print prev }' "$json_file" > "$json_final"
    json_file="$json_final"
  fi

  local exit_code=0
  [ "$issue_count" -gt 0 ] && exit_code=1

  # Output --------------------------------------------------------------
  case "$mode" in
    json)
      printf '{\n'
      printf '  "scope": "%s",\n' "$scope"
      printf '  "totals": {"templates": %s, "generated": %s, "installed": %s, "issues": %s},\n' \
        "$tmpl_n" "$gen_n" "$inst_n" "$issue_count"
      printf '  "exit": %s,\n' "$exit_code"
      printf '  "agents": [\n'
      if [ -s "$json_file" ]; then
        cat "$json_file"
        printf '\n'
      fi
      printf '  ]\n'
      printf '}\n'
      ;;
    quiet)
      printf 'agents: %s templates · %s generated · %s installed · %s issues (scope=%s)\n' \
        "$tmpl_n" "$gen_n" "$inst_n" "$issue_count" "$scope"
      ;;
    table|*)
      _agents_row "AGENT" "TMPL" "GEN" "INST" "SYNC" "ISSUES"
      _agents_row "-----" "----" "---" "----" "----" "------"
      cat "$rows_file"
      printf '\n'
      if [ "$issue_count" -gt 0 ]; then
        printf 'Summary: %s issue(s) / %s agents (scope=%s). Exit: %s\n' \
          "$issue_count" "$total_agents" "$scope" "$exit_code"
      else
        printf 'Summary: all %s agents clean (scope=%s). Exit: 0\n' "$total_agents" "$scope"
      fi
      ;;
  esac

  return "$exit_code"
}

doey_agents_usage() {
  cat <<'USAGE'
Usage: doey agents <subcommand> [options]

Subcommands:
  check        Detect drift across template / generated / installed layers

Run 'doey agents check --help' for flags.
USAGE
}

doey_agents() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift || true
  case "$sub" in
    ""|-h|--help|help) doey_agents_usage; return 0 ;;
    check) doey_agents_check "$@"; return $? ;;
    *)
      printf 'doey agents: unknown subcommand: %s\n' "$sub" >&2
      doey_agents_usage >&2
      return 2
      ;;
  esac
}

# If sourced, export functions. If executed directly, dispatch.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  doey_agents "$@"
  exit $?
fi
