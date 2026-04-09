#!/usr/bin/env bash
# doey-tunnel-detect.sh — Pure-shell framework & dev-server port detection.
#
# Consumed by shell/doey-tunnel-cli.sh to proactively print likely localhost
# URLs when `doey tunnel up` starts. The running port watcher remains the
# source of truth — this helper is ADVISORY ONLY.
#
# Public API:
#   doey_tunnel_detect_pwd [dir]   — prints TSV: PORT<TAB>FRAMEWORK<TAB>SOURCE
#   doey_tunnel_detect_main <cmd>  — subcommands: detect_pwd | detect_dir <path>
#
# Fresh-install safety: uses only bash, grep, awk, sed, cat. jq/yq are
# optional upgrades guarded by `command -v`. Bash 3.2 compatible.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_tunnel_detect_sourced:-}" = "1" ] && return 0
__doey_tunnel_detect_sourced=1

# ── Internal state ───────────────────────────────────────────────────
# Tracks which ports and frameworks have already been emitted in the
# current detection run so we can honor first-hit-wins priority.
_DOEY_TUNNEL_DETECT_SEEN_PORTS=""
_DOEY_TUNNEL_DETECT_SEEN_FW="|"
_DOEY_TUNNEL_DETECT_PREFIX=""

_doey_tunnel_detect_reset() {
  _DOEY_TUNNEL_DETECT_SEEN_PORTS=""
  _DOEY_TUNNEL_DETECT_SEEN_FW="|"
  _DOEY_TUNNEL_DETECT_PREFIX=""
}

# Emit a detection line. Dedups by port (first hit wins).
_doey_tunnel_detect_emit() {
  local port="$1" framework="$2" source="$3"
  # Validate port is numeric and within TCP range
  case "$port" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    return 0
  fi
  # Port dedup
  case " $_DOEY_TUNNEL_DETECT_SEEN_PORTS " in
    *" $port "*) return 0 ;;
  esac
  _DOEY_TUNNEL_DETECT_SEEN_PORTS="$_DOEY_TUNNEL_DETECT_SEEN_PORTS $port"
  # Record framework (for priority-4 skip logic)
  case "$_DOEY_TUNNEL_DETECT_SEEN_FW" in
    *"|$framework|"*) : ;;
    *) _DOEY_TUNNEL_DETECT_SEEN_FW="${_DOEY_TUNNEL_DETECT_SEEN_FW}${framework}|" ;;
  esac
  printf '%s\t%s\t%s\n' "$port" "$framework" "${_DOEY_TUNNEL_DETECT_PREFIX}${source}"
}

_doey_tunnel_detect_fw_seen() {
  case "$_DOEY_TUNNEL_DETECT_SEEN_FW" in
    *"|$1|"*) return 0 ;;
  esac
  return 1
}

# Extract first `port: N` occurrence from a file. Echoes integer or empty.
_doey_tunnel_detect_extract_port_field() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -E 'port[[:space:]]*:[[:space:]]*[0-9]+' "$file" 2>/dev/null \
    | head -1 \
    | sed -nE 's/.*port[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' \
    | head -1
}

# ── PRIORITY 1 — Explicit config files ───────────────────────────────

_doey_tunnel_detect_vite_config() {
  local dir="$1" f port
  for f in vite.config.js vite.config.ts vite.config.mjs vite.config.cjs; do
    [ -f "$dir/$f" ] || continue
    port=$(_doey_tunnel_detect_extract_port_field "$dir/$f")
    if [ -n "$port" ]; then
      _doey_tunnel_detect_emit "$port" "Vite" "$f:server.port"
    fi
  done
}

_doey_tunnel_detect_next_config() {
  local dir="$1" f port
  for f in next.config.js next.config.ts next.config.mjs; do
    [ -f "$dir/$f" ] || continue
    port=$(_doey_tunnel_detect_extract_port_field "$dir/$f")
    if [ -n "$port" ]; then
      _doey_tunnel_detect_emit "$port" "Next.js" "$f:port"
    fi
  done
}

_doey_tunnel_detect_nuxt_config() {
  local dir="$1" f port
  for f in nuxt.config.js nuxt.config.ts; do
    [ -f "$dir/$f" ] || continue
    port=$(_doey_tunnel_detect_extract_port_field "$dir/$f")
    if [ -n "$port" ]; then
      _doey_tunnel_detect_emit "$port" "Nuxt" "$f:devServer.port"
    fi
  done
}

_doey_tunnel_detect_astro_config() {
  local dir="$1" f port
  for f in astro.config.js astro.config.ts astro.config.mjs; do
    [ -f "$dir/$f" ] || continue
    port=$(_doey_tunnel_detect_extract_port_field "$dir/$f")
    if [ -n "$port" ]; then
      _doey_tunnel_detect_emit "$port" "Astro" "$f:server.port"
    fi
  done
}

_doey_tunnel_detect_svelte_config() {
  local dir="$1" f port
  for f in svelte.config.js; do
    [ -f "$dir/$f" ] || continue
    port=$(_doey_tunnel_detect_extract_port_field "$dir/$f")
    if [ -n "$port" ]; then
      _doey_tunnel_detect_emit "$port" "SvelteKit" "$f:port"
    fi
  done
}

_doey_tunnel_detect_remix_config() {
  local dir="$1" f port
  for f in remix.config.js remix.config.mjs; do
    [ -f "$dir/$f" ] || continue
    port=$(_doey_tunnel_detect_extract_port_field "$dir/$f")
    if [ -n "$port" ]; then
      _doey_tunnel_detect_emit "$port" "Remix" "$f:devServerPort"
    fi
  done
}

# ── PRIORITY 2 — Env files ───────────────────────────────────────────

_doey_tunnel_detect_env_files() {
  local dir="$1" envfile line var port
  for envfile in .env .env.local .env.development; do
    [ -f "$dir/$envfile" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      # Strip leading whitespace and optional `export `
      line="${line# }"
      line="${line#export }"
      case "$line" in
        PORT=*|VITE_PORT=*|NEXT_PUBLIC_PORT=*|SERVER_PORT=*)
          var="${line%%=*}"
          port="${line#*=}"
          # Strip surrounding quotes
          port="${port%\"}"; port="${port#\"}"
          port="${port%\'}"; port="${port#\'}"
          # Strip inline comment
          port="${port%% *}"
          port="${port%%#*}"
          case "$port" in
            ''|*[!0-9]*) continue ;;
          esac
          _doey_tunnel_detect_emit "$port" "Env var" "$envfile:$var"
          ;;
      esac
    done < "$dir/$envfile"
  done
}

# ── PRIORITY 3 — package.json scripts ────────────────────────────────

_doey_tunnel_detect_package_scripts() {
  local dir="$1" pkg="$dir/package.json"
  [ -f "$pkg" ] || return 0

  local script_lines line script_name port fw
  script_lines=$(grep -E '"(dev|start|serve)"[[:space:]]*:' "$pkg" 2>/dev/null || true)
  [ -n "$script_lines" ] || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    script_name=$(echo "$line" | sed -nE 's/.*"(dev|start|serve)"[[:space:]]*:.*/\1/p' | head -1)
    [ -n "$script_name" ] || script_name="dev"

    # Try `--port N` or `--port=N`
    port=$(echo "$line" | sed -nE 's/.*--port[[:space:]=]+([0-9]+).*/\1/p' | head -1)
    if [ -z "$port" ]; then
      # Try `-p N` or `-p=N` — require leading space/quote to avoid matching -pN in flags
      port=$(echo "$line" | sed -nE 's/.*[[:space:]"]-p[[:space:]=]+([0-9]+).*/\1/p' | head -1)
    fi

    if [ -n "$port" ]; then
      fw="package.json script"
      case "$line" in
        *next*)   fw="Next.js" ;;
        *vite*)   fw="Vite" ;;
        *nuxt*)   fw="Nuxt" ;;
        *astro*)  fw="Astro" ;;
        *svelte*) fw="SvelteKit" ;;
        *remix*)  fw="Remix" ;;
      esac
      _doey_tunnel_detect_emit "$port" "$fw" "package.json:scripts.$script_name"
    fi
  done <<EOF
$script_lines
EOF
}

# ── PRIORITY 4 — package.json dependencies (framework defaults) ──────

_doey_tunnel_detect_package_deps() {
  local dir="$1" pkg="$dir/package.json" deps
  [ -f "$pkg" ] || return 0

  # Flatten to a single line for simple substring matching.
  deps=$(tr '\n' ' ' < "$pkg" 2>/dev/null || true)
  [ -n "$deps" ] || return 0

  # Next.js
  if ! _doey_tunnel_detect_fw_seen "Next.js"; then
    case "$deps" in
      *'"next"'*) _doey_tunnel_detect_emit 3000 "Next.js" "package.json:dependencies" ;;
    esac
  fi
  # Nuxt
  if ! _doey_tunnel_detect_fw_seen "Nuxt"; then
    case "$deps" in
      *'"nuxt"'*|*'"nuxt3"'*) _doey_tunnel_detect_emit 3000 "Nuxt" "package.json:dependencies" ;;
    esac
  fi
  # SvelteKit
  if ! _doey_tunnel_detect_fw_seen "SvelteKit"; then
    case "$deps" in
      *'"@sveltejs/kit"'*) _doey_tunnel_detect_emit 5173 "SvelteKit" "package.json:dependencies" ;;
    esac
  fi
  # Vite (core or @vitejs/*)
  if ! _doey_tunnel_detect_fw_seen "Vite"; then
    case "$deps" in
      *'"vite"'*|*'"@vitejs/'*) _doey_tunnel_detect_emit 5173 "Vite" "package.json:dependencies" ;;
    esac
  fi
  # Astro
  if ! _doey_tunnel_detect_fw_seen "Astro"; then
    case "$deps" in
      *'"astro"'*) _doey_tunnel_detect_emit 4321 "Astro" "package.json:dependencies" ;;
    esac
  fi
  # Create React App
  if ! _doey_tunnel_detect_fw_seen "Create React App"; then
    case "$deps" in
      *'"react-scripts"'*) _doey_tunnel_detect_emit 3000 "Create React App" "package.json:dependencies" ;;
    esac
  fi
  # Remix
  if ! _doey_tunnel_detect_fw_seen "Remix"; then
    case "$deps" in
      *'"@remix-run/'*) _doey_tunnel_detect_emit 3000 "Remix" "package.json:dependencies" ;;
    esac
  fi
  # Gatsby
  if ! _doey_tunnel_detect_fw_seen "Gatsby"; then
    case "$deps" in
      *'"gatsby"'*) _doey_tunnel_detect_emit 8000 "Gatsby" "package.json:dependencies" ;;
    esac
  fi
  # Storybook
  if ! _doey_tunnel_detect_fw_seen "Storybook"; then
    case "$deps" in
      *'"storybook"'*|*'"@storybook/'*) _doey_tunnel_detect_emit 6006 "Storybook" "package.json:dependencies" ;;
    esac
  fi
}

# ── PRIORITY 5 — Other languages ─────────────────────────────────────

_doey_tunnel_detect_docker_compose() {
  local dir="$1" f line host_port
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [ -f "$dir/$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      # Match `- "HOST:CONTAINER"` or `- HOST:CONTAINER` style port mappings.
      host_port=$(echo "$line" | sed -nE 's/^[[:space:]]*-[[:space:]]*"?([0-9]+):[0-9]+.*/\1/p')
      if [ -n "$host_port" ]; then
        _doey_tunnel_detect_emit "$host_port" "Docker Compose" "$f:ports"
      fi
    done < "$dir/$f"
  done
}

_doey_tunnel_detect_rust() {
  local dir="$1" port
  [ -f "$dir/Cargo.toml" ] || return 0
  if [ -f "$dir/src/main.rs" ]; then
    # Look for .bind("host:PORT") or similar patterns
    port=$(grep -E '\.bind\(' "$dir/src/main.rs" 2>/dev/null \
      | head -1 \
      | sed -nE 's/.*:([0-9]+).*/\1/p' \
      | head -1)
    if [ -n "$port" ]; then
      _doey_tunnel_detect_emit "$port" "Rust" "src/main.rs:bind"
    fi
  fi
}

_doey_tunnel_detect_go() {
  local dir="$1" port f
  [ -f "$dir/go.mod" ] || return 0
  for f in main.go cmd/main.go cmd/server/main.go; do
    [ -f "$dir/$f" ] || continue
    port=$(grep -E 'ListenAndServe' "$dir/$f" 2>/dev/null \
      | head -1 \
      | sed -nE 's/.*":([0-9]+).*/\1/p' \
      | head -1)
    if [ -n "$port" ]; then
      _doey_tunnel_detect_emit "$port" "Go" "$f:ListenAndServe"
      return 0
    fi
  done
}

_doey_tunnel_detect_python() {
  local dir="$1" req_file content
  # Django (strongest signal)
  if [ -f "$dir/manage.py" ]; then
    _doey_tunnel_detect_emit 8000 "Django" "manage.py"
  fi
  # FastAPI / uvicorn / flask — scan dependency manifests
  for req_file in pyproject.toml requirements.txt setup.py Pipfile; do
    [ -f "$dir/$req_file" ] || continue
    content=$(cat "$dir/$req_file" 2>/dev/null || true)
    case "$content" in
      *fastapi*|*uvicorn*)
        if ! _doey_tunnel_detect_fw_seen "FastAPI/uvicorn"; then
          _doey_tunnel_detect_emit 8000 "FastAPI/uvicorn" "$req_file"
        fi
        ;;
    esac
    case "$content" in
      *flask*|*Flask*)
        if ! _doey_tunnel_detect_fw_seen "Flask"; then
          _doey_tunnel_detect_emit 5000 "Flask" "$req_file"
        fi
        ;;
    esac
  done
}

# ── Single-directory detection runner ────────────────────────────────

_doey_tunnel_detect_run_dir() {
  local dir="$1"
  # Priority 1 — config files
  _doey_tunnel_detect_vite_config   "$dir"
  _doey_tunnel_detect_next_config   "$dir"
  _doey_tunnel_detect_nuxt_config   "$dir"
  _doey_tunnel_detect_astro_config  "$dir"
  _doey_tunnel_detect_svelte_config "$dir"
  _doey_tunnel_detect_remix_config  "$dir"
  # Priority 2 — env files
  _doey_tunnel_detect_env_files     "$dir"
  # Priority 3 — package.json scripts
  _doey_tunnel_detect_package_scripts "$dir"
  # Priority 4 — package.json dependency defaults
  _doey_tunnel_detect_package_deps  "$dir"
  # Priority 5 — other languages
  _doey_tunnel_detect_docker_compose "$dir"
  _doey_tunnel_detect_rust          "$dir"
  _doey_tunnel_detect_go            "$dir"
  _doey_tunnel_detect_python        "$dir"
}

# ── Public: detect for a directory (default $PWD) ────────────────────

doey_tunnel_detect_pwd() {
  local target="${1:-$PWD}"
  [ -d "$target" ] || return 0

  _doey_tunnel_detect_reset
  _doey_tunnel_detect_run_dir "$target"

  # Priority 6 — Monorepo recursion (apps/ and packages/ subdirs)
  local base subdir name
  for base in apps packages; do
    [ -d "$target/$base" ] || continue
    for subdir in "$target/$base"/*/; do
      [ -d "${subdir}" ] || continue
      [ -f "${subdir}package.json" ] || continue
      name="${subdir%/}"
      name="${name##*/}"
      _DOEY_TUNNEL_DETECT_PREFIX="$base/$name/"
      _doey_tunnel_detect_run_dir "${subdir%/}"
    done
  done
  _DOEY_TUNNEL_DETECT_PREFIX=""
  return 0
}

# ── Main wrapper ─────────────────────────────────────────────────────

doey_tunnel_detect_main() {
  local cmd="${1:-detect_pwd}" target output
  case "$cmd" in
    detect_pwd)
      target="$PWD"
      ;;
    detect_dir)
      target="${2:-}"
      if [ -z "$target" ]; then
        echo "Usage: doey-tunnel-detect.sh detect_dir <path>" >&2
        return 1
      fi
      if [ ! -d "$target" ]; then
        echo "Error: '$target' is not a directory" >&2
        return 1
      fi
      ;;
    -h|--help|help)
      cat <<'USAGE'
Usage: doey-tunnel-detect.sh <command>

Commands:
  detect_pwd           Detect frameworks & ports in the current directory
  detect_dir <path>    Detect frameworks & ports in <path>

Output: one TSV line per detection: PORT<TAB>FRAMEWORK<TAB>SOURCE
USAGE
      return 0
      ;;
    *)
      echo "Usage: doey-tunnel-detect.sh {detect_pwd|detect_dir <path>}" >&2
      return 1
      ;;
  esac

  echo "# doey tunnel port detection — $target"
  output=$(doey_tunnel_detect_pwd "$target")
  if [ -z "$output" ]; then
    echo "No framework detected"
    return 0
  fi
  echo "$output"
}

# Execute main when run as a script (not when sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  doey_tunnel_detect_main "$@"
fi
