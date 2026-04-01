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

PASS='\033[0;32m' FAIL='\033[0;31m' WARN='\033[0;33m'
BOLD='\033[1m' RESET='\033[0m' BRAND='\033[1;36m' DIM='\033[0;90m'

HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || { cd "${1:-.}" && pwd; })"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
RUNTIME_DIR="${2:-/tmp/doey/${PROJECT_NAME}}"

CHECK_NAMES="" CHECK_RESULTS="" CHECK_DETAILS=""
LANGUAGE="unknown" GO_MODULE_DIR="." HAS_CRITICAL_FAILURE=0
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

_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

_dotleader() {
  local icon="$1" name="$2" status_text="$3" status_color="$4" detail="${5:-}"
  local dots_needed=$((30 - ${#name} - 2))
  [ "$dots_needed" -lt 2 ] && dots_needed=2
  local dots; dots=$(printf '%*s' "$dots_needed" '' | tr ' ' '.')

  if [ "$HAS_GUM" = true ]; then
    local gum_fg="7"
    case "$status_text" in PASS) gum_fg="2";; FAIL) gum_fg="1";; WARN) gum_fg="3";; SKIP) gum_fg="8";; esac
    local line="  ${name} ${dots} $(gum style --foreground "$gum_fg" --bold "$status_text")"
    [ -n "$detail" ] && line="${line} $(gum style --foreground 8 "(${detail})")"
    printf '%s\n' "$line"
  else
    printf '  %b %s %b%s%b %b%s%b' "$icon" "$name" "$DIM" "$dots" "$RESET" "$status_color" "$status_text" "$RESET"
    [ -n "$detail" ] && printf ' %b(%s)%b' "$DIM" "$detail" "$RESET"
    printf '\n'
  fi
}

_cmd_exists() { command -v "$1" >/dev/null 2>&1; }

_print_banner() {
  printf '\n'
  if [ "$HAS_GUM" = true ]; then
    gum style --foreground 6 --bold --border rounded --border-foreground 6 \
      --padding "0 2" --margin "0 2" \
      "Doey Pre-Push Quality Gate" "Project: ${PROJECT_NAME} (${LANGUAGE})"
  else
    printf '  %b┌─────────────────────────────────────┐\n  │%b  Doey Pre-Push Quality Gate         %b│\n  │%b  Project: %b%-15s%b (%s)  %b│\n  └─────────────────────────────────────┘%b\n' \
      "$BRAND" "$RESET" "$BRAND" "$RESET" "$BOLD" "$PROJECT_NAME" "$RESET" "$LANGUAGE" "$BRAND" "$RESET"
  fi
  printf '\n'
}

_detect_language() {
  cd "$PROJECT_DIR"

  local session_env="${RUNTIME_DIR}/session.env"
  if [ -f "$session_env" ]; then
    local lang_override=""
    lang_override="$(grep '^PROJECT_LANGUAGE=' "$session_env" 2>/dev/null | head -1 | cut -d= -f2-)" || true
    [ -n "$lang_override" ] && { LANGUAGE="$lang_override"; return 0; }
  fi

  local _found_gomod=""
  if [ -f "go.mod" ]; then _found_gomod="."
  else
    _found_gomod="$(ls -d */go.mod 2>/dev/null | head -1)" || true
    [ -n "$_found_gomod" ] && _found_gomod="$(dirname "$_found_gomod")"
  fi

  if   [ -n "$_found_gomod" ];                        then LANGUAGE="go"; GO_MODULE_DIR="$_found_gomod"
  elif [ -f "package.json" ];                          then LANGUAGE="node"
  elif [ -f "Cargo.toml" ];                            then LANGUAGE="rust"
  elif [ -f "pyproject.toml" ] || [ -f "setup.py" ];  then LANGUAGE="python"
  elif [ -f "Gemfile" ];                               then LANGUAGE="ruby"
  elif [ -f "Makefile" ];                              then LANGUAGE="make"
  fi
}

_check_build() {
  cd "$PROJECT_DIR"
  local output="" rc=0

  case "$LANGUAGE" in
    go)
      local godir
      for godir in /snap/go/current/bin /usr/local/go/bin "$HOME/go/bin" "$HOME/.local/go/bin"; do
        [ -x "$godir/go" ] && { export PATH="$godir:$PATH"; break; }
      done
      _cmd_exists go || { _record "Build" "skip" "Go toolchain not found"; return 0; }
      output="$(cd "${PROJECT_DIR}/${GO_MODULE_DIR}" && go build ./... 2>&1)" || rc=$?
      ;;
    node)
      _cmd_exists npm || { _record "Build" "skip" "npm not found"; return 0; }
      output="$(npm run build --if-present 2>&1)" || rc=$?
      ;;
    rust)
      _cmd_exists cargo || { _record "Build" "skip" "cargo not found"; return 0; }
      output="$(cargo build 2>&1)" || rc=$?
      ;;
    python)
      _cmd_exists python3 || _cmd_exists python || { _record "Build" "skip" "python not found"; return 0; }
      local py_cmd="python3"; _cmd_exists python3 || py_cmd="python"
      if _cmd_exists git && git rev-parse --git-dir >/dev/null 2>&1; then
        local changed_py=""
        changed_py="$(git diff --name-only HEAD 2>/dev/null | grep '\.py$')" || true
        if [ -n "$changed_py" ]; then
          local f; while IFS= read -r f; do
            [ -f "$f" ] && $py_cmd -m py_compile "$f" 2>&1 || rc=$?
          done <<EOF
$changed_py
EOF
        fi
      fi
      [ "$rc" -eq 0 ] && output="compiled OK"
      ;;
    *) _record "Build" "skip" "no build command for $LANGUAGE"; return 0 ;;
  esac

  if [ "$rc" -eq 0 ]; then _record "Build" "pass" "compiled OK"
  else printf '%s\n' "$output" >&2; _record "Build" "fail" "build errors"; fi
}

_check_lint() {
  cd "$PROJECT_DIR"
  local output="" rc=0

  case "$LANGUAGE" in
    go)
      _cmd_exists golangci-lint || { _record "Lint" "skip" "golangci-lint not installed"; return 0; }
      output="$(cd "${PROJECT_DIR}/${GO_MODULE_DIR}" && golangci-lint run 2>&1)" || rc=$?
      ;;
    node)
      _cmd_exists npm || { _record "Lint" "skip" "npm not found"; return 0; }
      output="$(npm run lint --if-present 2>&1)" || rc=$?
      ;;
    rust)
      _cmd_exists cargo || { _record "Lint" "skip" "cargo not found"; return 0; }
      cargo clippy --version >/dev/null 2>&1 || { _record "Lint" "skip" "clippy not installed"; return 0; }
      output="$(cargo clippy 2>&1)" || rc=$?
      ;;
    python)
      if _cmd_exists ruff; then output="$(ruff check . 2>&1)" || rc=$?
      elif _cmd_exists flake8; then output="$(flake8 2>&1)" || rc=$?
      else _record "Lint" "skip" "no linter (ruff/flake8) found"; return 0; fi
      ;;
    *) _record "Lint" "skip" "no linter for $LANGUAGE"; return 0 ;;
  esac

  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    local warn_count; warn_count="$(printf '%s\n' "$output" | grep -c '^' || true)"
    _record "Lint" "warn" "${warn_count} warnings"; return 0
  fi
  _record "Lint" "pass" ""
}

_check_tests() {
  cd "$PROJECT_DIR"
  local output="" rc=0

  case "$LANGUAGE" in
    go)
      _cmd_exists go || { _record "Tests" "skip" "Go toolchain not found"; return 0; }
      output="$(cd "${PROJECT_DIR}/${GO_MODULE_DIR}" && go test ./... 2>&1)" || rc=$?
      if [ "$rc" -eq 0 ]; then
        _record "Tests" "pass" "$(printf '%s\n' "$output" | grep -c '^ok' || true) passed"
      else
        printf '%s\n' "$output" >&2
        _record "Tests" "fail" "$(printf '%s\n' "$output" | grep -c '^FAIL' || true) failed"
      fi
      return 0 ;;
    node)
      _cmd_exists npm || { _record "Tests" "skip" "npm not found"; return 0; }
      grep -q '"test"' package.json 2>/dev/null || { _record "Tests" "skip" "no test script"; return 0; }
      output="$(npm test 2>&1)" || rc=$? ;;
    rust)
      _cmd_exists cargo || { _record "Tests" "skip" "cargo not found"; return 0; }
      output="$(cargo test 2>&1)" || rc=$? ;;
    python)
      _cmd_exists pytest || { _record "Tests" "skip" "pytest not installed"; return 0; }
      output="$(pytest 2>&1)" || rc=$? ;;
    *) _record "Tests" "skip" "no test command for $LANGUAGE"; return 0 ;;
  esac

  if [ "$rc" -eq 0 ]; then _record "Tests" "pass" ""
  else printf '%s\n' "$output" >&2; _record "Tests" "fail" "test failures"; fi
}

_check_hygiene() {
  cd "$PROJECT_DIR"
  local warnings=0 details=""

  if ! _cmd_exists git || ! git rev-parse --git-dir >/dev/null 2>&1; then
    _record "Git hygiene" "skip" "not a git repo"; return 0
  fi

  [ -n "$(git status --porcelain 2>/dev/null)" ] && { warnings=$((warnings + 1)); details="uncommitted changes"; }

  local staged_files=""
  staged_files="$(git diff --cached --name-only 2>/dev/null)" || true
  if [ -n "$staged_files" ]; then
    local f; while IFS= read -r f; do
      if [ -f "$f" ]; then
        local size=0
        _cmd_exists stat && size="$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || printf '0')"
        if [ "$size" -gt 5242880 ] 2>/dev/null; then
          warnings=$((warnings + 1))
          [ -n "$details" ] && details="${details}, "
          details="${details}large file: $f"
        fi
      fi
    done <<EOF
$staged_files
EOF
  fi

  local secret_hits=0
  local secret_patterns='PRIVATE_KEY|sk-[a-zA-Z0-9]|password=[^$]|SECRET_KEY|AWS_ACCESS_KEY'
  if [ -n "$staged_files" ]; then
    local hits=""
    hits="$(printf '%s\n' "$staged_files" | xargs grep -l -E "$secret_patterns" 2>/dev/null)" || true
    [ -n "$hits" ] && secret_hits="$(printf '%s\n' "$hits" | grep -c '^' || true)"
  fi
  local env_staged=""
  env_staged="$(git diff --cached --name-only 2>/dev/null | grep '\.env' || true)"
  [ -n "$env_staged" ] && secret_hits=$((secret_hits + 1))

  if [ "$secret_hits" -gt 0 ]; then
    warnings=$((warnings + 1))
    [ -n "$details" ] && details="${details}, "
    details="${details}possible secrets detected"
  fi

  if [ "$warnings" -gt 0 ]; then _record "Git hygiene" "warn" "${details}"
  else _record "Git hygiene" "pass" ""; fi
}

_print_results() {
  # Count pipe-delimited fields
  local total; total="$(printf '%s' "$CHECK_NAMES" | awk -F'|' '{print NF}')"

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
    [ "$result" = "fail" ] && printf '    %b→ fix failures before pushing%b\n' "$FAIL" "$RESET"
    i=$((i + 1))
  done

  printf '\n'
  if [ "$HAS_CRITICAL_FAILURE" -eq 1 ]; then
    printf '  %bResult: BLOCKED — fix failures before pushing%b\n\n' "$FAIL" "$RESET"
  else
    printf '  %bResult: READY TO PUSH ✓%b\n\n' "$PASS" "$RESET"
  fi
}

_write_status() {
  [ -d "$RUNTIME_DIR" ] || return 0
  local gate_status="pass"
  [ "$HAS_CRITICAL_FAILURE" -eq 1 ] && gate_status="fail"

  cat > "${RUNTIME_DIR}/deploy_status" <<EOF
GATE_STATUS=${gate_status}
GATE_TIME=$(date +%s)
GATE_LANGUAGE=${LANGUAGE}
BUILD_STATUS=$(_field "$CHECK_RESULTS" 1)
LINT_STATUS=$(_field "$CHECK_RESULTS" 2)
TEST_STATUS=$(_field "$CHECK_RESULTS" 3)
HYGIENE_STATUS=$(_field "$CHECK_RESULTS" 4)
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
