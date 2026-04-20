#!/usr/bin/env bash
# test-discord-boundary.sh — enforce cold-start package-boundary constraint.
# The discord package lives on the cold-start path and must NOT import any
# TUI (bubbletea/lipgloss/bubbles/bubblezone), model, or database package.
# See masterplan line 258. Run in CI and locally. Exits non-zero on violation.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PKG_DIR="${ROOT}/tui/internal/discord"
if [ ! -d "$PKG_DIR" ]; then
  echo "test-discord-boundary: package dir not found: $PKG_DIR" >&2
  exit 1
fi

FAIL=0
FORBIDDEN_PATTERNS=(
  "github.com/doey-cli/doey/tui/internal/model"
  "github.com/charmbracelet/bubbletea"
  "github.com/charmbracelet/lipgloss"
  "github.com/charmbracelet/bubbles"
  "mattn/go-sqlite3"
  "database/sql"
  "modernc.org/sqlite"
  "github.com/lrstanley/bubblezone"
)

# All .go files (including *_test.go — they ship in the same package compile
# unit so their imports count).
while IFS= read -r -d '' f; do
  for pat in "${FORBIDDEN_PATTERNS[@]}"; do
    if grep -Fq "\"$pat" "$f"; then
      echo "BOUNDARY VIOLATION: $f imports $pat" >&2
      FAIL=1
    fi
  done
done < <(find "$PKG_DIR" -name '*.go' -print0)

if [ "$FAIL" -ne 0 ]; then
  echo "" >&2
  echo "Package-boundary violations found. The discord package must stay on" >&2
  echo "the cold-start path — no TUI / database deps. See masterplan line 258." >&2
  exit 1
fi

count=$(find "$PKG_DIR" -name '*.go' | wc -l | tr -d '[:space:]')
echo "test-discord-boundary: OK (scanned ${count} Go files)"
