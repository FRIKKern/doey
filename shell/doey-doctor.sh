#!/usr/bin/env bash
# doey-doctor.sh — Installation health check and diagnostics.
# Sourceable library, not standalone.
set -euo pipefail

[ "${__doey_doctor_sourced:-}" = "1" ] && return 0
__doey_doctor_sourced=1

# Doctor counters — reset before each run, read after
_DOC_OK=0 _DOC_WARN=0 _DOC_FAIL=0 _DOC_SKIP=0

# Print a doctor-style check line.
# Usage: _doc_check ok|warn|fail|skip "label" ["detail"]
_doc_check() {
  local level="$1" label="$2" detail="${3:-}"
  case "$level" in
    ok)   _DOC_OK=$((_DOC_OK + 1)) ;;
    warn) _DOC_WARN=$((_DOC_WARN + 1)) ;;
    fail) _DOC_FAIL=$((_DOC_FAIL + 1)) ;;
    skip) _DOC_SKIP=$((_DOC_SKIP + 1)) ;;
  esac
  if [ "$HAS_GUM" = true ]; then
    local icon color
    case "$level" in
      ok)   icon="✓"; color="2" ;;
      warn) icon="⚠"; color="3" ;;
      fail) icon="✗"; color="1" ;;
      skip) icon="–"; color="8" ;;
    esac
    printf '  %s %-22s %s\n' \
      "$(gum style --foreground "$color" "$icon")" \
      "$label" \
      "$([ -n "$detail" ] && gum style --foreground 240 "$detail")"
  else
    case "$level" in
      ok)   printf "  ${SUCCESS}✓${RESET} %-22s" "$label" ;;
      warn) printf "  ${WARN}⚠${RESET} %-22s" "$label" ;;
      fail) printf "  ${ERROR}✗${RESET} %-22s" "$label" ;;
      skip) printf "  ${DIM}–${RESET} %-22s" "$label" ;;
    esac
    [ -n "$detail" ] && printf " ${DIM}%s${RESET}" "$detail"
    printf '\n'
  fi
}

# ── Doctor — check installation health ────────────────────────────────
check_doctor() {
  PROJECT_DIR="$(pwd)"
  _DOC_OK=0 _DOC_WARN=0 _DOC_FAIL=0 _DOC_SKIP=0
  doey_header "Doey — System Check"
  printf '\n'

  # Required commands — offer install if missing
  if command -v tmux >/dev/null 2>&1; then
    _doc_check ok "tmux" "$(tmux -V)"
  else
    _doc_check fail "tmux not installed"
    case "$(uname -s)" in
      Darwin) printf "\n         ${DIM}Fix: ${RESET}${BRAND}brew install tmux${RESET}\n" ;;
      Linux)  printf "\n         ${DIM}Fix: ${RESET}${BRAND}sudo apt-get install -y tmux${RESET}\n" ;;
    esac
  fi
  if command -v claude >/dev/null 2>&1; then
    local _claude_ver _claude_raw _claude_latest
    _claude_raw=$(claude --version 2>/dev/null || echo "unknown")
    _claude_ver=$(_claude_semver)
    _claude_ver="${_claude_ver:-$_claude_raw}"
    _claude_latest=$(_claude_latest_ver)
    if [ -n "$_claude_latest" ] && [ "$_claude_ver" != "$_claude_latest" ]; then
      _doc_check warn "claude CLI" "$_claude_ver → $_claude_latest available"
      printf "\n         "
      _claude_update_hint "$(_claude_install_method)" "Update"
    else
      _doc_check ok "claude CLI" "$_claude_ver${_claude_latest:+ (latest)}"
    fi
  else
    _doc_check fail "claude CLI not found"
    if command -v node >/dev/null 2>&1; then
      printf "\n         ${DIM}Fix: ${RESET}${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n"
    else
      printf "\n         ${DIM}Fix: Install Node.js 18+ first, then: ${RESET}${BRAND}npm install -g @anthropic-ai/claude-code${RESET}\n"
    fi
  fi

  # Auth check
  local _auth_result
  if _auth_result=$(_parse_auth_status); then
    local _auth_method _auth_email _auth_sub
    local _old_ifs="$IFS"; IFS='|'
    set -- $_auth_result; IFS="$_old_ifs"
    _auth_method="${2:-}" _auth_email="${3:-}" _auth_sub="${4:-}"
    _doc_check ok "Claude auth" "${_auth_method} · ${_auth_email} · ${_auth_sub}"
  else
    _doc_check fail "Claude auth" "Not logged in — run 'claude' to authenticate"
  fi

  # PATH check
  if echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then _doc_check ok "~/.local/bin in PATH"
  else _doc_check warn "~/.local/bin not in PATH"; fi

  # Installed files
  local _f _label _doey_repo
  _doey_repo="$(resolve_repo_dir)"
  for _f in "$HOME/.claude/agents/doey-subtaskmaster.md:Agents" \
            "$_doey_repo/.claude/skills/doey-dispatch/SKILL.md:Skills" \
            "$HOME/.local/bin/doey:CLI"; do
    _label="${_f##*:}"; _f="${_f%:*}"
    if [[ -f "$_f" ]]; then _doc_check ok "$_label installed" "${_f/#$HOME/~}"
    else _doc_check fail "$_label missing" "${_f/#$HOME/~}"; fi
  done

  # Masterplan spawn helper — wired by install.sh but missing on systems that
  # haven't reinstalled since it was added. Required for /doey-masterplan.
  local _mp_spawn="$HOME/.local/bin/doey-masterplan-spawn.sh"
  if [[ -x "$_mp_spawn" ]]; then
    _doc_check ok "Masterplan spawn" "${_mp_spawn/#$HOME/~}"
  elif [[ -f "$_mp_spawn" ]]; then
    _doc_check fail "Masterplan spawn" "exists but not executable — run: cd ${_doey_repo} && ./install.sh"
  else
    _doc_check fail "Masterplan spawn missing" "run: cd ${_doey_repo} && ./install.sh"
  fi

  # Masterplan ambiguity helper — sourced by the /doey-masterplan skill.
  local _mp_amb="$HOME/.local/bin/doey-masterplan-ambiguity.sh"
  if [[ -f "$_mp_amb" ]]; then
    _doc_check ok "Masterplan ambiguity" "${_mp_amb/#$HOME/~}"
  else
    _doc_check fail "Masterplan ambiguity missing" "run: cd ${_doey_repo} && ./install.sh"
  fi

  # Repo path
  local repo_dir=""
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"
  if [[ -n "$repo_dir" ]]; then
    if [[ -d "$repo_dir" ]]; then _doc_check ok "Repo registered" "$repo_dir"
    else _doc_check fail "Repo dir missing" "$repo_dir"; fi
  else
    _doc_check fail "Repo not registered" "~/.claude/doey/repo-path missing"
  fi

  # Optional: jq
  if command -v jq >/dev/null 2>&1; then _doc_check ok "jq" "$(jq --version 2>/dev/null || echo 'unknown')"
  else _doc_check warn "jq not found — auto-trust skipped"; fi

  # gum (optional luxury CLI)
  if command -v gum >/dev/null 2>&1; then
    _doc_check ok "gum" "$(gum --version 2>/dev/null || echo 'unknown')"
  else
    _doc_check fail "Gum missing" "run: go install github.com/charmbracelet/gum@latest"
  fi

  # Version
  local version_file="$HOME/.claude/doey/version"
  if [[ -f "$version_file" ]]; then
    _doc_check ok "Version" "$(_env_val "$version_file" version) ($(_env_val "$version_file" date))"
  else
    _doc_check warn "No version file" "Run 'doey update'"
  fi

  # TUI dashboard
  if command -v doey-tui >/dev/null 2>&1; then
    _doc_check ok "doey-tui" "$(doey-tui --version 2>/dev/null || echo 'installed')"
  else
    if command -v go >/dev/null 2>&1 || [ -x /usr/local/go/bin/go ] || [ -x /opt/homebrew/bin/go ]; then
      _doc_check warn "doey-tui not installed" "Go available — run: doey build"
    else
      _doc_check skip "doey-tui not installed" "using info-panel.sh fallback"
    fi
  fi

  # Remote setup wizard
  if command -v doey-remote-setup >/dev/null 2>&1; then
    _doc_check ok "doey-remote-setup" "installed"
  else
    _doc_check skip "doey-remote-setup not installed" "optional — run: doey build"
  fi

  # Orchestration CLI (internal doey-ctl binary powers 'doey' subcommands)
  if command -v doey-ctl >/dev/null 2>&1; then
    _doc_check ok "doey CLI tools" "found at $(command -v doey-ctl)"
  else
    _doc_check warn "doey CLI tools not installed" "shell fallbacks will be used — run: doey build"
  fi

  # Scaffy template engine
  if command -v doey-scaffy >/dev/null 2>&1; then
    _doc_check ok "doey-scaffy" "$(doey-scaffy --version 2>/dev/null || echo 'installed')"
  else
    _doc_check skip "doey-scaffy not installed" "optional — run: doey build"
  fi

  # Go binary freshness
  if [[ -n "$repo_dir" ]] && type _go_binary_stale >/dev/null 2>&1; then
    local _stale_bins=""
    if _go_binary_stale "$HOME/.local/bin/doey-tui" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="doey-tui"
    fi
    if _go_binary_stale "$HOME/.local/bin/doey-remote-setup" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="${_stale_bins:+${_stale_bins}, }doey-remote-setup"
    fi
    if _go_binary_stale "$HOME/.local/bin/doey-ctl" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="${_stale_bins:+${_stale_bins}, }doey-ctl"
    fi
    if _go_binary_stale "$HOME/.local/bin/doey-scaffy" "$repo_dir/tui" 2>/dev/null; then
      _stale_bins="${_stale_bins:+${_stale_bins}, }doey-scaffy"
    fi
    if [[ -n "$_stale_bins" ]]; then
      _doc_check warn "Go binaries may be stale: ${_stale_bins}" "run: doey build"
    else
      _doc_check ok "Go binaries fresh"
    fi
  fi

  # Context audit
  if [[ -n "$repo_dir" ]] && [[ -f "$repo_dir/shell/context-audit.sh" ]]; then
    local audit_output
    if audit_output=$(bash "$repo_dir/shell/context-audit.sh" --installed --no-color 2>&1); then
      _doc_check ok "Context audit clean"
    else
      _doc_check warn "Context audit issues:"
      printf '%s\n' "$audit_output"
    fi
  else
    _doc_check skip "Context audit" "(script not found)"
  fi

  # Task helpers — verify doey-task-helpers.sh is reachable
  local _task_helpers=""
  if [[ -n "$repo_dir" ]] && [[ -f "$repo_dir/shell/doey-task-helpers.sh" ]]; then
    _task_helpers="$repo_dir/shell/doey-task-helpers.sh"
  else
    # Fall back to location relative to the installed doey script
    local _doey_bin=""
    _doey_bin="$(command -v doey 2>/dev/null || true)"
    if [[ -n "$_doey_bin" ]] && [[ -f "$(dirname "$_doey_bin")/doey-task-helpers.sh" ]]; then
      _task_helpers="$(dirname "$_doey_bin")/doey-task-helpers.sh"
    fi
  fi
  if [[ -n "$_task_helpers" ]]; then
    _doc_check ok "Task helpers" "${_task_helpers/#$HOME/~}"
  else
    _doc_check warn "Task helpers not found" "doey-task-helpers.sh missing from repo and PATH"
  fi

  # Respawn subsystem — skill + hook + syntax
  if [[ -n "$repo_dir" ]]; then
    local _respawn_skill="$repo_dir/.claude/skills/doey-respawn-me/SKILL.md"
    local _respawn_hook="$repo_dir/.claude/hooks/stop-respawn.sh"
    local _respawn_ok=true
    if [[ -f "$_respawn_skill" ]]; then
      _doc_check ok "Respawn skill" "${_respawn_skill/#$HOME/~}"
    else
      _doc_check fail "Respawn skill missing" "${_respawn_skill/#$HOME/~}"
      _respawn_ok=false
    fi
    if [[ -f "$_respawn_hook" ]]; then
      if [[ -x "$_respawn_hook" ]]; then
        if bash -n "$_respawn_hook" 2>/dev/null; then
          _doc_check ok "Respawn hook" "executable, syntax OK"
        else
          _doc_check fail "Respawn hook" "bash -n failed"
          _respawn_ok=false
        fi
      else
        _doc_check fail "Respawn hook" "not executable"
        _respawn_ok=false
      fi
    else
      _doc_check fail "Respawn hook missing" "${_respawn_hook/#$HOME/~}"
      _respawn_ok=false
    fi
  fi

  # Task counter — validate .next_id if .doey/tasks/ exists
  local _tasks_dir="${PROJECT_DIR}/.doey/tasks"
  if [[ -d "$_tasks_dir" ]] && [[ -f "${_tasks_dir}/.next_id" ]]; then
    local _nid; _nid="$(cat "${_tasks_dir}/.next_id" 2>/dev/null || true)"
    case "$_nid" in
      ''|*[!0-9]*) _doc_check warn "Task counter" ".next_id is not a positive integer: ${_nid:-empty}" ;;
      0)           _doc_check warn "Task counter" ".next_id=0 — may collide with existing tasks" ;;
      *)           _doc_check ok "Task counter" ".next_id=${_nid}" ;;
    esac
  elif [[ -d "$_tasks_dir" ]]; then
    _doc_check skip "Task counter" ".doey/tasks/ exists but no .next_id yet"
  fi

  # Taskmaster responsiveness — only when a session is running
  local _doc_name _doc_session
  _doc_name="$(find_project "$PROJECT_DIR" 2>/dev/null || true)"
  _doc_session="doey-${_doc_name}"
  if [[ -n "$_doc_name" ]] && session_exists "$_doc_session" 2>/dev/null; then
    local _doc_rt
    _doc_rt="$(tmux show-environment -t "$_doc_session" DOEY_RUNTIME 2>/dev/null | cut -d= -f2- || true)"
    if [[ -z "$_doc_rt" ]]; then _doc_rt="${TMPDIR:-/tmp}/doey/${_doc_name}"; fi
    local _doc_tm_safe
    _doc_tm_safe="$(printf '%s' "${_doc_session}:1.0" | tr ':.-' '___')"
    local _doc_tm_status="${_doc_rt}/status/${_doc_tm_safe}.status"
    if [[ -f "$_doc_tm_status" ]]; then
      local _doc_tm_state
      _doc_tm_state="$(grep '^STATUS' "$_doc_tm_status" 2>/dev/null | head -1 | sed 's/^STATUS[=: ]*//; s/^ *//' || true)"
      case "$_doc_tm_state" in
        BUSY|READY|WORKING)
          # Also check staleness via doey-ctl if available
          if command -v doey-ctl >/dev/null 2>&1; then
            if doey-ctl health check --runtime "$_doc_rt" "$_doc_tm_safe" >/dev/null 2>&1; then
              _doc_check ok "Taskmaster alive" "${_doc_tm_state} (responsive)"
            else
              _doc_check warn "Taskmaster stale" "${_doc_tm_state} but not updated recently"
            fi
          else
            _doc_check ok "Taskmaster alive" "$_doc_tm_state"
          fi
          ;;
        FINISHED|RESERVED)
          _doc_check warn "Taskmaster idle" "$_doc_tm_state"
          ;;
        *)
          _doc_check warn "Taskmaster status" "${_doc_tm_state:-unknown}"
          ;;
      esac
    else
      _doc_check warn "Taskmaster status" "no status file (session running but Taskmaster not reporting)"
    fi
  else
    _doc_check skip "Taskmaster alive" "no running session for $(pwd)"
  fi

  # ── Summary footer ──
  printf '\n'
  local _doc_total=$((_DOC_OK + _DOC_WARN + _DOC_FAIL))
  if [ "$HAS_GUM" = true ]; then
    local _doc_summary=""
    _doc_summary="$(gum style --foreground 2 "${_DOC_OK} passed")"
    [ "$_DOC_WARN" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 3 "${_DOC_WARN} warnings")"
    [ "$_DOC_FAIL" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 1 --bold "${_DOC_FAIL} failed")"
    [ "$_DOC_SKIP" -gt 0 ] && _doc_summary="${_doc_summary}  $(gum style --foreground 240 "${_DOC_SKIP} skipped")"
    gum style --padding "0 1" "$_doc_summary"
  else
    printf "  ${SUCCESS}%d passed${RESET}" "$_DOC_OK"
    [ "$_DOC_WARN" -gt 0 ] && printf "  ${WARN}%d warnings${RESET}" "$_DOC_WARN"
    [ "$_DOC_FAIL" -gt 0 ] && printf "  ${ERROR}%d failed${RESET}" "$_DOC_FAIL"
    [ "$_DOC_SKIP" -gt 0 ] && printf "  ${DIM}%d skipped${RESET}" "$_DOC_SKIP"
    printf '\n'
  fi
  printf '\n'
}
