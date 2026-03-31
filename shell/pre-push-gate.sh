#!/usr/bin/env bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────────────
# pre-push-gate.sh — Pre-push quality gate for Doey
#
# Usage: bash pre-push-gate.sh [project_dir] [runtime_dir]
# Can be run standalone or called from doey deploy gate.
# Exit 0 = all checks pass, Exit 1 = failures found
#
# Bash 3.2 compatible — no associative arrays, mapfile, etc.
# ──────────────────────────────────────────────────────────────────────

# ── Color palette ─────────────────────────────────────────────────────
PASS='\033[0;32m'     # Green
FAIL='\033[0;31m'     # Red
WARN='\033[0;33m'     # Yellow
BOLD='\033[1m'        # Bold
RESET='\033[0m'       # Reset
BRAND='\033[1;36m'    # Bold cyan
DIM='\033[0;90m'      # Gray

# ── Gum detection (optional luxury styling) ──────────────────────────
HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

# ── Arguments ─────────────────────────────────────────────────────────
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || { cd "${1:-.}" && pwd; })"

PROJECT_NAME="$(basename "$PROJECT_DIR")"
RUNTIME_DIR="${2:-/tmp/doey/${PROJECT_NAME}}"

# ── State tracking (indexed arrays, bash 3.2 safe) ───────────────────
CHECK_NAMES=""
CHECK_RESULTS=""
CHECK_DETAILS=""
LANGUAGE="unknown"
GO_MODULE_DIR="."
HAS_CRITICAL_FAILURE=0

# ── Helpers ───────────────────────────────────────────────────────────
_record() {
  # Usage: _record "Build" "pass" "compiled OK"
  local name="$1" result="$2" detail="${3:-}"
  CHECK_NAMES="${CHECK_NAMES}${CHECK_NAMES:+|}${name}"
  CHECK_RESULTS="${CHECK_RESULTS}${CHECK_RESULTS:+|}${result}"
  CHECK_DETAILS="${CHECK_DETAILS}${CHECK_DETAILS:+|}${detail}"
  if [ "$result" = "fail" ]; then
    HAS_CRITICAL_FAILURE=1
  fi
}

_field() {
  # Extract Nth pipe-delimited field (1-based)
  local str="$1" n="$2"
  printf '%s' "$str" | cut -d'|' -f"$n"
}

_dotleader() {
  # Print "icon name .... STATUS" with fixed width
  local icon="$1" name="$2" status_text="$3" status_color="$4" detail="${5:-}"
  local leader_width=30
  local name_len=${#name}
  local dots_needed=$((leader_width - name_len - 2))
  if [ "$dots_needed" -lt 2 ]; then
    dots_needed=2
  fi
  local dots=""
  local i=0
  while [ "$i" -lt "$dots_needed" ]; do
    dots="${dots}."
    i=$((i + 1))
  done

  if [ "$HAS_GUM" = true ]; then
    # Gum-styled status badge
    local gum_fg="7"
    case "$status_text" in
      PASS) gum_fg="2" ;;
      FAIL) gum_fg="1" ;;
      WARN) gum_fg="3" ;;
      SKIP) gum_fg="8" ;;
    esac
    local badge
    badge="$(gum style --foreground "$gum_fg" --bold "$status_text")"
    local line="  ${name} ${dots} ${badge}"
    if [ -n "$detail" ]; then
      local dim_detail
      dim_detail="$(gum style --foreground 8 "(${detail})")"
      line="${line} ${dim_detail}"
    fi
    printf '%s\n' "$line"
  else
    printf '  %b %s %b%s%b %b%s%b' "$icon" "$name" "$DIM" "$dots" "$RESET" "$status_color" "$status_text" "$RESET"
    if [ -n "$detail" ]; then
      printf ' %b(%s)%b' "$DIM" "$detail" "$RESET"
    fi
    printf '\n'
  fi
}

_cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

# ── Banner ────────────────────────────────────────────────────────────
_print_banner() {
  printf '\n'
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 6 --bold --border rounded --border-foreground 6 \
      --padding "0 2" --margin "0 2" \
      "Doey Pre-Push Quality Gate" \
      "Project: ${PROJECT_NAME} (${LANGUAGE})"
  else
    printf '  %b┌─────────────────────────────────────┐%b\n' "$BRAND" "$RESET"
    printf '  %b│%b  Doey Pre-Push Quality Gate         %b│%b\n' "$BRAND" "$RESET" "$BRAND" "$RESET"
    printf '  %b│%b  Project: %b%-15s%b (%s)  %b│%b\n' "$BRAND" "$RESET" "$BOLD" "$PROJECT_NAME" "$RESET" "$LANGUAGE" "$BRAND" "$RESET"
    printf '  %b└─────────────────────────────────────┘%b\n' "$BRAND" "$RESET"
  fi
  printf '\n'
}

# ── Step 1: Detect language ───────────────────────────────────────────
_detect_language() {
  cd "$PROJECT_DIR"

  # Check session.env for override
  local session_env="${RUNTIME_DIR}/session.env"
  if [ -f "$session_env" ]; then
    local lang_override=""
    lang_override="$(grep '^PROJECT_LANGUAGE=' "$session_env" 2>/dev/null | head -1 | cut -d= -f2-)" || true
    if [ -n "$lang_override" ]; then
      LANGUAGE="$lang_override"
      return 0
    fi
  fi

  # Detect from marker files (check root, then one level of subdirs)
  local _found_gomod=""
  if [ -f "go.mod" ]; then
    _found_gomod="."
  else
    _found_gomod="$(ls -d */go.mod 2>/dev/null | head -1)" || true
    if [ -n "$_found_gomod" ]; then
      _found_gomod="$(dirname "$_found_gomod")"
    fi
  fi

  if [ -n "$_found_gomod" ]; then
    LANGUAGE="go"
    GO_MODULE_DIR="$_found_gomod"
  elif [ -f "package.json" ]; then
    LANGUAGE="node"
  elif [ -f "Cargo.toml" ]; then
    LANGUAGE="rust"
  elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
    LANGUAGE="python"
  elif [ -f "Gemfile" ]; then
    LANGUAGE="ruby"
  elif [ -f "Makefile" ]; then
    LANGUAGE="make"
  else
    LANGUAGE="unknown"
  fi
}

# ── Step 2: Build check ──────────────────────────────────────────────
_check_build() {
  cd "$PROJECT_DIR"
  local output=""
  local rc=0

  case "$LANGUAGE" in
    go)
      # Discover Go
      local godir
      for godir in /snap/go/current/bin /usr/local/go/bin "$HOME/go/bin" "$HOME/.local/go/bin"; do
        if [ -x "$godir/go" ]; then
          export PATH="$godir:$PATH"
          break
        fi
      done
      if ! _cmd_exists go; then
        _record "Build" "skip" "Go toolchain not found"
        return 0
      fi
      output="$(cd "${PROJECT_DIR}/${GO_MODULE_DIR}" && go build ./... 2>&1)" || rc=$?
      ;;
    node)
      if ! _cmd_exists npm; then
        _record "Build" "skip" "npm not found"
        return 0
      fi
      output="$(npm run build --if-present 2>&1)" || rc=$?
      ;;
    rust)
      if ! _cmd_exists cargo; then
        _record "Build" "skip" "cargo not found"
        return 0
      fi
      output="$(cargo build 2>&1)" || rc=$?
      ;;
    python)
      if ! _cmd_exists python && ! _cmd_exists python3; then
        _record "Build" "skip" "python not found"
        return 0
      fi
      local py_cmd="python3"
      _cmd_exists python3 || py_cmd="python"
      # Compile changed .py files if in a git repo
      if _cmd_exists git && git rev-parse --git-dir >/dev/null 2>&1; then
        local changed_py=""
        changed_py="$(git diff --name-only HEAD 2>/dev/null | grep '\.py$')" || true
        if [ -n "$changed_py" ]; then
          local f
          while IFS= read -r f; do
            if [ -f "$f" ]; then
              $py_cmd -m py_compile "$f" 2>&1 || rc=$?
            fi
          done <<EOF
$changed_py
EOF
        fi
      fi
      if [ "$rc" -eq 0 ]; then
        output="compiled OK"
      fi
      ;;
    *)
      _record "Build" "skip" "no build command for $LANGUAGE"
      return 0
      ;;
  esac

  if [ "$rc" -eq 0 ]; then
    _record "Build" "pass" "compiled OK"
  else
    printf '%s\n' "$output" >&2
    _record "Build" "fail" "build errors"
  fi
}

# ── Step 3: Lint check (non-fatal) ───────────────────────────────────
_check_lint() {
  cd "$PROJECT_DIR"
  local output=""
  local rc=0
  local warn_count=""

  case "$LANGUAGE" in
    go)
      if ! _cmd_exists golangci-lint; then
        _record "Lint" "skip" "golangci-lint not installed"
        return 0
      fi
      output="$(cd "${PROJECT_DIR}/${GO_MODULE_DIR}" && golangci-lint run 2>&1)" || rc=$?
      if [ "$rc" -ne 0 ]; then
        warn_count="$(printf '%s\n' "$output" | grep -c '^' || true)"
        printf '%s\n' "$output" >&2
        _record "Lint" "warn" "${warn_count} warnings"
        return 0
      fi
      ;;
    node)
      if ! _cmd_exists npm; then
        _record "Lint" "skip" "npm not found"
        return 0
      fi
      output="$(npm run lint --if-present 2>&1)" || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$output" >&2
        _record "Lint" "warn" "lint issues"
        return 0
      fi
      ;;
    rust)
      if ! _cmd_exists cargo; then
        _record "Lint" "skip" "cargo not found"
        return 0
      fi
      # Check if clippy is available
      if ! cargo clippy --version >/dev/null 2>&1; then
        _record "Lint" "skip" "clippy not installed"
        return 0
      fi
      output="$(cargo clippy 2>&1)" || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$output" >&2
        _record "Lint" "warn" "clippy warnings"
        return 0
      fi
      ;;
    python)
      if _cmd_exists ruff; then
        output="$(ruff check . 2>&1)" || rc=$?
      elif _cmd_exists flake8; then
        output="$(flake8 2>&1)" || rc=$?
      else
        _record "Lint" "skip" "no linter (ruff/flake8) found"
        return 0
      fi
      if [ "$rc" -ne 0 ]; then
        warn_count="$(printf '%s\n' "$output" | grep -c '^' || true)"
        printf '%s\n' "$output" >&2
        _record "Lint" "warn" "${warn_count} warnings"
        return 0
      fi
      ;;
    *)
      _record "Lint" "skip" "no linter for $LANGUAGE"
      return 0
      ;;
  esac

  _record "Lint" "pass" ""
}

# ── Step 4: Test check (fatal) ───────────────────────────────────────
_check_tests() {
  cd "$PROJECT_DIR"
  local output=""
  local rc=0
  local passed=""

  case "$LANGUAGE" in
    go)
      if ! _cmd_exists go; then
        _record "Tests" "skip" "Go toolchain not found"
        return 0
      fi
      output="$(cd "${PROJECT_DIR}/${GO_MODULE_DIR}" && go test ./... 2>&1)" || rc=$?
      if [ "$rc" -eq 0 ]; then
        passed="$(printf '%s\n' "$output" | grep -c '^ok' || true)"
        _record "Tests" "pass" "${passed} passed"
      else
        local failed=""
        failed="$(printf '%s\n' "$output" | grep -c '^FAIL' || true)"
        printf '%s\n' "$output" >&2
        _record "Tests" "fail" "${failed} failed"
      fi
      return 0
      ;;
    node)
      if ! _cmd_exists npm; then
        _record "Tests" "skip" "npm not found"
        return 0
      fi
      # Check if test script exists
      if ! grep -q '"test"' package.json 2>/dev/null; then
        _record "Tests" "skip" "no test script"
        return 0
      fi
      output="$(npm test 2>&1)" || rc=$?
      ;;
    rust)
      if ! _cmd_exists cargo; then
        _record "Tests" "skip" "cargo not found"
        return 0
      fi
      output="$(cargo test 2>&1)" || rc=$?
      ;;
    python)
      if ! _cmd_exists pytest; then
        _record "Tests" "skip" "pytest not installed"
        return 0
      fi
      output="$(pytest 2>&1)" || rc=$?
      ;;
    *)
      _record "Tests" "skip" "no test command for $LANGUAGE"
      return 0
      ;;
  esac

  if [ "$rc" -eq 0 ]; then
    _record "Tests" "pass" ""
  else
    printf '%s\n' "$output" >&2
    _record "Tests" "fail" "test failures"
  fi
}

# ── Step 5: Git hygiene (non-fatal) ──────────────────────────────────
_check_hygiene() {
  cd "$PROJECT_DIR"
  local warnings=0
  local details=""

  # Must be a git repo
  if ! _cmd_exists git || ! git rev-parse --git-dir >/dev/null 2>&1; then
    _record "Git hygiene" "skip" "not a git repo"
    return 0
  fi

  # Uncommitted changes
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    warnings=$((warnings + 1))
    details="uncommitted changes"
  fi

  # Large files staged (>5MB)
  local staged_files=""
  staged_files="$(git diff --cached --name-only 2>/dev/null)" || true
  if [ -n "$staged_files" ]; then
    local f
    while IFS= read -r f; do
      if [ -f "$f" ]; then
        local size=0
        # Portable file size (works on macOS/Linux)
        if _cmd_exists stat; then
          size="$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || printf '0')"
        fi
        if [ "$size" -gt 5242880 ] 2>/dev/null; then
          warnings=$((warnings + 1))
          if [ -n "$details" ]; then
            details="${details}, "
          fi
          details="${details}large file: $f"
        fi
      fi
    done <<EOF
$staged_files
EOF
  fi

  # Secrets scan on tracked files
  local secret_hits=0
  local secret_patterns='PRIVATE_KEY|sk-[a-zA-Z0-9]|password=[^$]|SECRET_KEY|AWS_ACCESS_KEY'
  # Check staged files for secrets
  if [ -n "$staged_files" ]; then
    local hits=""
    hits="$(printf '%s\n' "$staged_files" | xargs grep -l -E "$secret_patterns" 2>/dev/null)" || true
    if [ -n "$hits" ]; then
      secret_hits="$(printf '%s\n' "$hits" | grep -c '^' || true)"
    fi
  fi
  # Check for .env files staged
  local env_staged=""
  env_staged="$(git diff --cached --name-only 2>/dev/null | grep '\.env' || true)"
  if [ -n "$env_staged" ]; then
    secret_hits=$((secret_hits + 1))
  fi

  if [ "$secret_hits" -gt 0 ]; then
    warnings=$((warnings + 1))
    if [ -n "$details" ]; then
      details="${details}, "
    fi
    details="${details}possible secrets detected"
  fi

  if [ "$warnings" -gt 0 ]; then
    _record "Git hygiene" "warn" "${details}"
  else
    _record "Git hygiene" "pass" ""
  fi
}

# ── Results output ────────────────────────────────────────────────────
_print_results() {
  local total=0
  local remaining="$CHECK_NAMES"
  while [ -n "$remaining" ]; do
    total=$((total + 1))
    case "$remaining" in
      *"|"*) remaining="${remaining#*|}" ;;
      *)     remaining="" ;;
    esac
  done

  local i=1
  while [ "$i" -le "$total" ]; do
    local name result detail icon status_color status_text
    name="$(_field "$CHECK_NAMES" "$i")"
    result="$(_field "$CHECK_RESULTS" "$i")"
    detail="$(_field "$CHECK_DETAILS" "$i")"

    case "$result" in
      pass) icon="${PASS}✓${RESET}"; status_color="$PASS"; status_text="PASS" ;;
      fail) icon="${FAIL}✗${RESET}"; status_color="$FAIL"; status_text="FAIL" ;;
      warn) icon="${WARN}⚠${RESET}"; status_color="$WARN"; status_text="WARN" ;;
      skip) icon="${DIM}–${RESET}"; status_color="$DIM"; status_text="SKIP" ;;
      *)    icon="${DIM}?${RESET}"; status_color="$DIM"; status_text="$result" ;;
    esac

    _dotleader "$icon" "$name" "$status_text" "$status_color" "$detail"

    # Show failure hint
    if [ "$result" = "fail" ]; then
      if [ "$HAS_GUM" = true ]; then
        gum style --foreground 1 --italic "    → fix failures before pushing" 2>/dev/null \
          || printf '    %b→ fix failures before pushing%b\n' "$FAIL" "$RESET"
      else
        printf '    %b→ fix failures before pushing%b\n' "$FAIL" "$RESET"
      fi
    fi

    i=$((i + 1))
  done

  printf '\n'
  if [ "$HAS_GUM" = true ]; then
    if [ "$HAS_CRITICAL_FAILURE" -eq 1 ]; then
      gum style --foreground 1 --bold --border rounded --border-foreground 1 \
        --padding "0 2" --margin "0 2" \
        "BLOCKED — fix failures before pushing"
    else
      gum style --foreground 2 --bold --border rounded --border-foreground 2 \
        --padding "0 2" --margin "0 2" \
        "READY TO PUSH ✓"
    fi
    printf '\n'
  else
    if [ "$HAS_CRITICAL_FAILURE" -eq 1 ]; then
      printf '  %bResult: BLOCKED — fix failures before pushing%b\n\n' "$FAIL" "$RESET"
    else
      printf '  %bResult: READY TO PUSH ✓%b\n\n' "$PASS" "$RESET"
    fi
  fi
}

# ── Write deploy status ──────────────────────────────────────────────
_write_status() {
  if [ ! -d "$RUNTIME_DIR" ]; then
    return 0
  fi

  local gate_status="pass"
  if [ "$HAS_CRITICAL_FAILURE" -eq 1 ]; then
    gate_status="fail"
  fi

  local epoch
  epoch="$(date +%s)"

  # Extract individual statuses
  local build_s lint_s test_s hygiene_s
  build_s="$(_field "$CHECK_RESULTS" 1)"
  lint_s="$(_field "$CHECK_RESULTS" 2)"
  test_s="$(_field "$CHECK_RESULTS" 3)"
  hygiene_s="$(_field "$CHECK_RESULTS" 4)"

  cat > "${RUNTIME_DIR}/deploy_status" <<EOF
GATE_STATUS=${gate_status}
GATE_TIME=${epoch}
GATE_LANGUAGE=${LANGUAGE}
BUILD_STATUS=${build_s}
LINT_STATUS=${lint_s}
TEST_STATUS=${test_s}
HYGIENE_STATUS=${hygiene_s}
EOF
}

# ── Main ──────────────────────────────────────────────────────────────
_detect_language
_print_banner
_check_build
_check_lint
_check_tests
_check_hygiene
_print_results
_write_status

exit "$HAS_CRITICAL_FAILURE"
