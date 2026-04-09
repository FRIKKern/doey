#!/usr/bin/env bash
set -euo pipefail

# Source guard
[[ "${__doey_tunnel_detect_sourced:-}" == "1" ]] && return 0 2>/dev/null || true
__doey_tunnel_detect_sourced=1

# doey-tunnel-detect.sh — 3-tier port detection for tunnel auto-configuration.
# Tier 1: Haiku runtime introspection (opt-in via DOEY_TUNNEL_SMART=1)
# Tier 2: Static file parsing (package.json, docker-compose, .env, etc.)
# Tier 3: Framework defaults (next->3000, vite->5173, etc.)

# --- Tier 1: Haiku-analyzed runtime introspection ---

_detect_ports_haiku() {
  local project_dir="${1:-.}"

  # Only run if opt-in AND headless is available
  [ "${DOEY_TUNNEL_SMART:-0}" = "1" ] || return 0

  local script_dir="${BASH_SOURCE[0]%/*}"
  [ -f "${script_dir}/doey-headless.sh" ] || return 0

  # shellcheck disable=SC1091
  source "${script_dir}/doey-headless.sh" 2>/dev/null || return 0
  command -v doey_headless >/dev/null 2>&1 || return 0

  # Collect runtime signals
  local runtime_context=""
  local ss_out="" ps_out="" tmux_out=""

  ss_out="$(ss -tlnp 2>/dev/null || true)"
  ps_out="$(ps -eo pid,args 2>/dev/null | head -100 || true)"

  # Capture tmux pane output if available
  if command -v tmux >/dev/null 2>&1 && [ -n "${SESSION_NAME:-}" ]; then
    local pane_list=""
    pane_list="$(tmux list-panes -s -t "${SESSION_NAME}" -F '#{pane_id}' 2>/dev/null || true)"
    if [ -n "$pane_list" ]; then
      local pane_id=""
      local pane_text=""
      # Read pane list line by line without mapfile
      while IFS= read -r pane_id; do
        [ -n "$pane_id" ] || continue
        pane_text="$(tmux capture-pane -t "$pane_id" -p -S -50 2>/dev/null || true)"
        local url_lines=""
        url_lines="$(echo "$pane_text" | grep -E '(localhost|127\.0\.0\.1|0\.0\.0\.0):[0-9]+|listening on' 2>/dev/null || true)"
        if [ -n "$url_lines" ]; then
          tmux_out="${tmux_out}
${url_lines}"
        fi
      done <<EOF
${pane_list}
EOF
    fi
  fi

  runtime_context="Listening sockets:
${ss_out}

Processes:
${ps_out}

Tmux URL patterns:
${tmux_out}"

  local result=""
  result=$(doey_headless "Given this runtime state and project at ${project_dir}, list ONLY the port numbers used by dev servers. Output ONLY comma-separated numbers, nothing else.

Runtime state:
${runtime_context}" \
    --model haiku \
    --no-tools \
    --timeout 10 \
    2>/dev/null) || return 0

  # Validate: extract only digits and commas
  result="$(echo "$result" | tr -cd '0-9,' | sed 's/^,//;s/,$//')"
  [ -n "$result" ] || return 0

  # Filter to range 1024-65535
  local filtered="" port=""
  local old_IFS="$IFS"
  IFS=','
  for port in $result; do
    IFS="$old_IFS"
    [ -n "$port" ] || continue
    if [ "$port" -ge 1024 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null; then
      if [ -n "$filtered" ]; then
        filtered="${filtered},${port}"
      else
        filtered="$port"
      fi
    fi
  done
  IFS="$old_IFS"

  echo "$filtered"
}

# --- Tier 2: Static file scanning ---

_detect_ports_static() {
  local project_dir="${1:-.}"
  local ports=""

  _add_port() {
    local p="$1"
    [ -n "$p" ] || return 0
    if [ "$p" -ge 1024 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null; then
      if [ -n "$ports" ]; then
        # Deduplicate
        case ",$ports," in
          *",$p,"*) return 0 ;;
        esac
        ports="${ports},${p}"
      else
        ports="$p"
      fi
    fi
  }

  _scan_file() {
    local file="$1"
    shift
    [ -f "$file" ] || return 0
    local match=""
    # Use grep with extended regex, extract port numbers
    while [ $# -gt 0 ]; do
      local pattern="$1"
      shift
      match="$(grep -oE -e "$pattern" "$file" 2>/dev/null || true)"
      if [ -n "$match" ]; then
        local line=""
        while IFS= read -r line; do
          # Extract just the number
          local num=""
          num="$(echo "$line" | grep -oE '[0-9]+' | tail -1)"
          _add_port "$num"
        done <<EOF
${match}
EOF
      fi
    done
  }

  # 1. package.json — port patterns in scripts
  _scan_file "${project_dir}/package.json" \
    '"port"[[:space:]]*:[[:space:]]*[0-9]+' \
    '--port[[:space:]]+[0-9]+' \
    'PORT=[0-9]+'

  # 2. docker-compose.yml / docker-compose.yaml — host ports
  local dc_file=""
  for dc_file in "${project_dir}/docker-compose.yml" "${project_dir}/docker-compose.yaml"; do
    if [ -f "$dc_file" ]; then
      local dc_ports=""
      dc_ports="$(grep -oE '"?[0-9]+:[0-9]+"?' "$dc_file" 2>/dev/null || true)"
      if [ -n "$dc_ports" ]; then
        local dc_line=""
        while IFS= read -r dc_line; do
          # Extract host port (before the colon)
          local host_port=""
          host_port="$(echo "$dc_line" | sed 's/"//g' | cut -d: -f1)"
          _add_port "$host_port"
        done <<EOF
${dc_ports}
EOF
      fi
    fi
  done

  # 3. .env files — PORT=N or *_PORT=N
  local env_file=""
  for env_file in "${project_dir}/.env" "${project_dir}/.env.local" "${project_dir}/.env.development"; do
    _scan_file "$env_file" '[A-Z_]*PORT=[0-9]+'
  done

  # 4. Dockerfile — EXPOSE N
  _scan_file "${project_dir}/Dockerfile" 'EXPOSE[[:space:]]+[0-9]+'

  # 5. vite.config.js / vite.config.ts
  local vite_file=""
  for vite_file in "${project_dir}/vite.config.js" "${project_dir}/vite.config.ts"; do
    _scan_file "$vite_file" 'port:[[:space:]]*[0-9]+'
  done

  # 6. next.config.js / next.config.mjs
  local next_file=""
  for next_file in "${project_dir}/next.config.js" "${project_dir}/next.config.mjs"; do
    _scan_file "$next_file" 'port:[[:space:]]*[0-9]+' '--port[[:space:]]+[0-9]+'
  done

  # 7. angular.json
  _scan_file "${project_dir}/angular.json" '"port":[[:space:]]*[0-9]+'

  echo "$ports"
}

# --- Tier 3: Framework defaults ---

_detect_ports_defaults() {
  local project_dir="${1:-.}"

  # Check package.json for JS frameworks
  if [ -f "${project_dir}/package.json" ]; then
    local pkg_content=""
    pkg_content="$(cat "${project_dir}/package.json" 2>/dev/null || true)"

    # Order matters — first match wins
    if echo "$pkg_content" | grep -qE '"(next|nuxt)"' 2>/dev/null; then
      echo "3000"; return 0
    fi
    if echo "$pkg_content" | grep -qE '"vite"' 2>/dev/null; then
      echo "5173"; return 0
    fi
    if echo "$pkg_content" | grep -qE '"@sveltejs/' 2>/dev/null; then
      echo "5173"; return 0
    fi
    if echo "$pkg_content" | grep -qE '"@angular/' 2>/dev/null; then
      echo "4200"; return 0
    fi
    if echo "$pkg_content" | grep -qE '"gatsby"' 2>/dev/null; then
      echo "8000"; return 0
    fi
    if echo "$pkg_content" | grep -qE '"remix"' 2>/dev/null; then
      echo "3000"; return 0
    fi
    if echo "$pkg_content" | grep -qE '"express"' 2>/dev/null; then
      echo "3000"; return 0
    fi
    if echo "$pkg_content" | grep -qE '"fastify"' 2>/dev/null; then
      echo "3000"; return 0
    fi
  fi

  # Check requirements.txt for Python frameworks
  if [ -f "${project_dir}/requirements.txt" ]; then
    local req_content=""
    req_content="$(cat "${project_dir}/requirements.txt" 2>/dev/null || true)"
    if echo "$req_content" | grep -qi 'django' 2>/dev/null; then
      echo "8000"; return 0
    fi
    if echo "$req_content" | grep -qi 'flask' 2>/dev/null; then
      echo "5000"; return 0
    fi
  fi

  # Check Gemfile for Ruby frameworks
  if [ -f "${project_dir}/Gemfile" ]; then
    if grep -q 'rails' "${project_dir}/Gemfile" 2>/dev/null; then
      echo "3000"; return 0
    fi
  fi

  # Check go.mod for Go frameworks
  if [ -f "${project_dir}/go.mod" ]; then
    echo "8080"; return 0
  fi

  # Check for static site generators
  if [ -f "${project_dir}/config.toml" ] && grep -q 'hugo' "${project_dir}/config.toml" 2>/dev/null; then
    echo "1313"; return 0
  fi
  if [ -f "${project_dir}/_config.yml" ]; then
    echo "4000"; return 0
  fi

  # Ultimate fallback
  echo "3000"
}

# --- Orchestrator ---

_detect_ports_all() {
  local project_dir="${1:-.}"
  local tier1="" tier2="" tier3=""

  # Tier 1 — Haiku runtime (opt-in)
  if [ "${DOEY_TUNNEL_SMART:-0}" = "1" ]; then
    tier1="$(_detect_ports_haiku "$project_dir" 2>/dev/null || true)"
  fi

  # Tier 2 — Static file scanning
  tier2="$(_detect_ports_static "$project_dir" 2>/dev/null || true)"

  # Tier 3 — Framework defaults
  tier3="$(_detect_ports_defaults "$project_dir" 2>/dev/null || true)"

  # Diagnostics to stderr
  echo "[tunnel-detect] Tier 1 (haiku): ${tier1:-<skipped>}" >&2
  echo "[tunnel-detect] Tier 2 (static): ${tier2:-<none>}" >&2
  echo "[tunnel-detect] Tier 3 (defaults): ${tier3:-3000}" >&2

  # Merge: Tier 1 overrides Tier 2 overrides Tier 3
  # Start with tier3, layer tier2 on top, then tier1
  local merged=""

  # Start with tier3
  merged="${tier3}"

  # Layer tier2 — add any ports not already present
  if [ -n "$tier2" ]; then
    local p=""
    local old_IFS="$IFS"
    IFS=','
    # Prepend tier2 ports (they take priority over tier3)
    local new_merged=""
    for p in $tier2; do
      IFS="$old_IFS"
      [ -n "$p" ] || continue
      if [ -n "$new_merged" ]; then
        new_merged="${new_merged},${p}"
      else
        new_merged="$p"
      fi
    done
    IFS="$old_IFS"
    # Add tier3 ports not in tier2
    if [ -n "$merged" ]; then
      local old_IFS2="$IFS"
      IFS=','
      for p in $merged; do
        IFS="$old_IFS2"
        [ -n "$p" ] || continue
        case ",$new_merged," in
          *",$p,"*) ;;  # Already present
          *) new_merged="${new_merged},${p}" ;;
        esac
      done
      IFS="$old_IFS2"
    fi
    merged="$new_merged"
  fi

  # Layer tier1 — prepend (highest priority)
  if [ -n "$tier1" ]; then
    local p=""
    local old_IFS="$IFS"
    IFS=','
    local new_merged=""
    for p in $tier1; do
      IFS="$old_IFS"
      [ -n "$p" ] || continue
      if [ -n "$new_merged" ]; then
        new_merged="${new_merged},${p}"
      else
        new_merged="$p"
      fi
    done
    IFS="$old_IFS"
    # Add remaining merged ports not in tier1
    if [ -n "$merged" ]; then
      local old_IFS2="$IFS"
      IFS=','
      for p in $merged; do
        IFS="$old_IFS2"
        [ -n "$p" ] || continue
        case ",$new_merged," in
          *",$p,"*) ;;
          *) new_merged="${new_merged},${p}" ;;
        esac
      done
      IFS="$old_IFS2"
    fi
    merged="$new_merged"
  fi

  echo "[tunnel-detect] Result: ${merged}" >&2
  echo "$merged"
}

# When executed directly (not sourced), run detection
if [ "${BASH_SOURCE[0]}" = "$0" ] 2>/dev/null; then
  _detect_ports_all "$(pwd)"
fi
