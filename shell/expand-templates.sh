#!/usr/bin/env bash
# expand-templates.sh — Expand {{DOEY_ROLE_*}} and {{DOEY_CATEGORY_*}} placeholders in .md.tmpl files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=doey-roles.sh
source "$SCRIPT_DIR/doey-roles.sh"
# shellcheck source=doey-categories.sh
source "$SCRIPT_DIR/doey-categories.sh"

# Flags
CHECK=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --check)   CHECK=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) echo "Usage: expand-templates.sh [--check] [--dry-run]"; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# Build sed expression from all DOEY_ROLE_* and DOEY_CATEGORY_* env vars
SED_EXPR=""
while IFS='=' read -r name value; do
  [ -z "$name" ] && continue
  # Escape sed special chars in value
  safe_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
  SED_EXPR="${SED_EXPR}s/{{${name}}}/${safe_value}/g;"
done <<EOF
$(env | grep '^DOEY_ROLE_\|^DOEY_CATEGORY_' | sort)
EOF

if [ -z "$SED_EXPR" ]; then
  echo "ERROR: No DOEY_ROLE_* or DOEY_CATEGORY_* variables found" >&2
  exit 1
fi

# Add DOEY_TASKMASTER_PANE substitution (env var > session.env > default "0.2")
DOEY_TASKMASTER_PANE="${DOEY_TASKMASTER_PANE:-1.0}"
if [ "$DOEY_TASKMASTER_PANE" = "1.0" ] && [ -n "${RUNTIME_DIR:-}" ] && [ -f "${RUNTIME_DIR}/session.env" ]; then
  _val=$(grep '^DOEY_TASKMASTER_PANE=' "${RUNTIME_DIR}/session.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  [ -n "$_val" ] && DOEY_TASKMASTER_PANE="$_val"
fi
safe_value=$(printf '%s' "$DOEY_TASKMASTER_PANE" | sed 's/[&/\]/\\&/g')
SED_EXPR="${SED_EXPR}s/{{DOEY_TASKMASTER_PANE}}/${safe_value}/g;"

# Find all .md.tmpl files
STALE=0
EXPANDED=0
for tmpl in "$PROJECT_DIR"/agents/*.md.tmpl "$PROJECT_DIR"/.claude/skills/*/*.md.tmpl "$PROJECT_DIR"/.claude/skills/*/*/*.md.tmpl; do
  [ -f "$tmpl" ] || continue
  output="${tmpl%.tmpl}"

  if [ "$CHECK" = true ]; then
    if [ ! -f "$output" ]; then
      echo "STALE: $output does not exist (from ${tmpl#"$PROJECT_DIR"/})"
      STALE=$((STALE + 1))
      continue
    fi
    expected=$(sed "$SED_EXPR" < "$tmpl")
    actual=$(cat "$output")
    if [ "$expected" != "$actual" ]; then
      echo "STALE: ${output#"$PROJECT_DIR"/} differs from template"
      STALE=$((STALE + 1))
    fi
    continue
  fi

  rel_tmpl="${tmpl#"$PROJECT_DIR"/}"
  rel_out="${output#"$PROJECT_DIR"/}"

  if [ "$DRY_RUN" = true ]; then
    echo "Would expand: $rel_tmpl -> $rel_out"
    EXPANDED=$((EXPANDED + 1))
    continue
  fi

  echo "Expanding: $rel_tmpl -> $rel_out"
  sed "$SED_EXPR" < "$tmpl" > "$output"
  EXPANDED=$((EXPANDED + 1))
done

if [ "$CHECK" = true ]; then
  if [ "$STALE" -gt 0 ]; then
    echo "$STALE template(s) out of date. Run: shell/expand-templates.sh"
    exit 1
  fi
  echo "All templates up to date."
  exit 0
fi

if [ "$EXPANDED" -eq 0 ]; then
  echo "No .md.tmpl files found."
else
  echo "Expanded $EXPANDED template(s)."
fi
