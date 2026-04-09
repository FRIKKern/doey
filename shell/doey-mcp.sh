#!/usr/bin/env bash
set -euo pipefail
# doey-mcp.sh — MCP server lifecycle management for Doey
# Sourced by doey-team-mgmt.sh and stop hooks
[ "${_DOEY_MCP_LOADED:-}" = "1" ] && return 0
_DOEY_MCP_LOADED=1

# ── Logging ─────────────────────────────────────────────────────────

# Log MCP lifecycle events.
# Usage: doey_mcp_log <level> <message>
doey_mcp_log() {
  local level="$1" message="$2"
  local runtime="${DOEY_RUNTIME:-/tmp/doey/doey}"
  local logdir="${runtime}/mcp"
  mkdir -p "$logdir"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$message" >> "${logdir}/mcp.log"
}

# ── JSON Helpers ────────────────────────────────────────────────────

# Escape a string for JSON value (handles \, ", newlines, tabs).
_mcp_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Expand ${VAR} references in a value using the current environment.
# Only expands ${NAME} forms, not $NAME.
_mcp_expand_env() {
  local val="$1" var_name var_val
  while true; do
    case "$val" in
      *'${'*'}'*)
        # Extract variable name between ${ and }
        local prefix="${val%%\$\{*}"
        local rest="${val#*\$\{}"
        var_name="${rest%%\}*}"
        local suffix="${rest#*\}}"
        # Look up in environment
        eval "var_val=\"\${${var_name}:-}\""
        val="${prefix}${var_val}${suffix}"
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$val"
}

# ── Skill Frontmatter Parsing ──────────────────────────────────────

# Parse mcp_servers from a SKILL.md YAML frontmatter block.
# Output: lines of name|command|args|env_KEY=val,env_KEY2=val2
# Usage: doey_mcp_parse_skill_frontmatter <skill_dir>
doey_mcp_parse_skill_frontmatter() {
  local skill_dir="$1"
  local skill_file="${skill_dir}/SKILL.md"
  if [ ! -f "$skill_file" ]; then
    doey_mcp_log "WARN" "No SKILL.md found in ${skill_dir}"
    return 0
  fi

  local in_frontmatter=0 in_mcp=0 in_server=0 in_env=0
  local name="" command="" args="" env_pairs=""
  local line indent

  while IFS= read -r line || [ -n "$line" ]; do
    # Frontmatter boundaries
    if [ "$line" = "---" ]; then
      if [ "$in_frontmatter" -eq 0 ]; then
        in_frontmatter=1
        continue
      else
        # End of frontmatter — emit final server if pending
        if [ "$in_server" -eq 1 ] && [ -n "$name" ]; then
          printf '%s|%s|%s|%s\n' "$name" "$command" "$args" "$env_pairs"
        fi
        break
      fi
    fi
    [ "$in_frontmatter" -eq 0 ] && continue

    # Strip trailing CR
    line="${line%$'\r'}"

    # Detect mcp_servers: key
    case "$line" in
      "mcp_servers:"*)
        in_mcp=1
        in_server=0
        in_env=0
        continue
        ;;
    esac
    [ "$in_mcp" -eq 0 ] && continue

    # Check indentation level — if line is not indented, mcp_servers block ended
    case "$line" in
      "  "* | "	"*) ;; # indented, still in mcp block
      "")            continue ;; # blank line
      *)             # non-indented, non-empty = new top-level key
        if [ "$in_server" -eq 1 ] && [ -n "$name" ]; then
          printf '%s|%s|%s|%s\n' "$name" "$command" "$args" "$env_pairs"
        fi
        break
        ;;
    esac

    # Trim leading whitespace for parsing
    indent="$line"
    line="${line#"${line%%[! ]*}"}" # strip leading spaces
    line="${line#"${line%%[!	]*}"}" # strip leading tabs

    # New server entry (- name: value)
    case "$line" in
      "- name: "*)
        # Emit previous server if pending
        if [ "$in_server" -eq 1 ] && [ -n "$name" ]; then
          printf '%s|%s|%s|%s\n' "$name" "$command" "$args" "$env_pairs"
        fi
        name="${line#- name: }"
        command=""
        args=""
        env_pairs=""
        in_server=1
        in_env=0
        continue
        ;;
    esac

    [ "$in_server" -eq 0 ] && continue

    # Parse server fields
    case "$line" in
      "command: "*)
        command="${line#command: }"
        in_env=0
        ;;
      "args: "*)
        args="${line#args: }"
        in_env=0
        ;;
      "env:"*)
        in_env=1
        ;;
      *)
        if [ "$in_env" -eq 1 ]; then
          # Parse KEY: value pairs within env block
          local key val
          key="${line%%:*}"
          key="${key#"${key%%[! ]*}"}" # trim leading spaces
          val="${line#*: }"
          if [ -n "$key" ] && [ -n "$val" ]; then
            if [ -n "$env_pairs" ]; then
              env_pairs="${env_pairs},${key}=${val}"
            else
              env_pairs="${key}=${val}"
            fi
          fi
        fi
        ;;
    esac
  done < "$skill_file"
}

# ── Config Generation ───────────────────────────────────────────────

# Generate a merged MCP config JSON from multiple skill directories.
# Usage: doey_mcp_generate_config <output_file> <skill_dir1> [skill_dir2...]
doey_mcp_generate_config() {
  local output_file="$1"
  shift

  mkdir -p "$(dirname "$output_file")"

  # Collect all server entries: indexed arrays for server data
  local server_count=0
  local server_names=""     # newline-separated
  local server_commands=""
  local server_args_list=""
  local server_envs=""

  local skill_dir entry
  for skill_dir in "$@"; do
    while IFS= read -r entry || [ -n "$entry" ]; do
      [ -z "$entry" ] && continue
      local s_name s_cmd s_args s_env
      # Split on |
      s_name="${entry%%|*}"; entry="${entry#*|}"
      s_cmd="${entry%%|*}"; entry="${entry#*|}"
      s_args="${entry%%|*}"
      s_env="${entry#*|}"

      # Expand env vars in values
      s_cmd="$(_mcp_expand_env "$s_cmd")"
      s_args="$(_mcp_expand_env "$s_args")"

      # Store in newline-delimited strings (Bash 3.2 compatible)
      if [ "$server_count" -eq 0 ]; then
        server_names="$s_name"
        server_commands="$s_cmd"
        server_args_list="$s_args"
        server_envs="$s_env"
      else
        server_names="${server_names}"$'\n'"${s_name}"
        server_commands="${server_commands}"$'\n'"${s_cmd}"
        server_args_list="${server_args_list}"$'\n'"${s_args}"
        server_envs="${server_envs}"$'\n'"${s_env}"
      fi
      server_count=$((server_count + 1))
    done <<EOF
$(doey_mcp_parse_skill_frontmatter "$skill_dir")
EOF
  done

  if [ "$server_count" -eq 0 ]; then
    printf '{"mcpServers": {}}\n' > "$output_file"
    doey_mcp_log "INFO" "Generated empty MCP config: ${output_file}"
    return 0
  fi

  # Build JSON
  _mcp_build_json "$output_file" "$server_count" "$server_names" \
    "$server_commands" "$server_args_list" "$server_envs"
  doey_mcp_log "INFO" "Generated MCP config with ${server_count} server(s): ${output_file}"
}

# Internal: build JSON from collected server data.
_mcp_build_json() {
  local output_file="$1"
  local count="$2"
  local names="$3" commands="$4" args_list="$5" envs="$6"

  local json='{"mcpServers": {'
  local i=0 first=1
  local name cmd args env_str

  while [ "$i" -lt "$count" ]; do
    # Extract i-th line from each newline-separated list
    name="$(printf '%s\n' "$names" | sed -n "$((i + 1))p")"
    cmd="$(printf '%s\n' "$commands" | sed -n "$((i + 1))p")"
    args="$(printf '%s\n' "$args_list" | sed -n "$((i + 1))p")"
    env_str="$(printf '%s\n' "$envs" | sed -n "$((i + 1))p")"

    if [ "$first" -eq 1 ]; then
      first=0
    else
      json="${json},"
    fi

    local escaped_name escaped_cmd
    escaped_name="$(_mcp_json_escape "$name")"
    escaped_cmd="$(_mcp_json_escape "$cmd")"

    # Build args array from space-separated string
    local args_json="["
    local arg_first=1 arg
    for arg in $args; do
      arg="$(_mcp_expand_env "$arg")"
      local escaped_arg
      escaped_arg="$(_mcp_json_escape "$arg")"
      if [ "$arg_first" -eq 1 ]; then
        arg_first=0
        args_json="${args_json}\"${escaped_arg}\""
      else
        args_json="${args_json}, \"${escaped_arg}\""
      fi
    done
    args_json="${args_json}]"

    # Build env object from KEY=val,KEY2=val2
    local env_json="{"
    if [ -n "$env_str" ]; then
      local env_first=1 pair key val
      local remaining="$env_str"
      while [ -n "$remaining" ]; do
        case "$remaining" in
          *","*)
            pair="${remaining%%,*}"
            remaining="${remaining#*,}"
            ;;
          *)
            pair="$remaining"
            remaining=""
            ;;
        esac
        key="${pair%%=*}"
        val="${pair#*=}"
        val="$(_mcp_expand_env "$val")"
        local escaped_val
        escaped_val="$(_mcp_json_escape "$val")"
        if [ "$env_first" -eq 1 ]; then
          env_first=0
          env_json="${env_json}\"${key}\": \"${escaped_val}\""
        else
          env_json="${env_json}, \"${key}\": \"${escaped_val}\""
        fi
      done
    fi
    env_json="${env_json}}"

    json="${json} \"${escaped_name}\": {\"command\": \"${escaped_cmd}\", \"args\": ${args_json}, \"env\": ${env_json}}"
    i=$((i + 1))
  done

  json="${json}}}"
  printf '%s\n' "$json" > "$output_file"
}

# ── Team Config ─────────────────────────────────────────────────────

# Parse mcps: section from a .team.md and generate team-level MCP config.
# Usage: doey_mcp_generate_team_config <runtime_dir> <window_index> <team_env_file>
doey_mcp_generate_team_config() {
  local runtime_dir="$1" window_index="$2" team_env_file="$3"
  local output_file="${runtime_dir}/mcp/team_${window_index}.mcp.json"
  mkdir -p "${runtime_dir}/mcp"

  # Read TEAM_DEF from the env file
  local team_def=""
  if [ -f "$team_env_file" ]; then
    local _line
    while IFS= read -r _line || [ -n "$_line" ]; do
      case "$_line" in
        TEAM_DEF=*) team_def="${_line#TEAM_DEF=}"; team_def="${team_def#\"}"; team_def="${team_def%\"}" ;;
      esac
    done < "$team_env_file"
  fi

  if [ -z "$team_def" ] || [ ! -f "$team_def" ]; then
    printf '{"mcpServers": {}}\n' > "$output_file"
    doey_mcp_log "INFO" "No team def found for window ${window_index}, empty MCP config"
    return 0
  fi

  # Parse mcps: section from the .team.md
  local in_mcps=0 in_server=0 in_env=0
  local server_count=0
  local server_names="" server_commands="" server_args_list="" server_envs=""
  local name="" command="" args="" env_pairs=""

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"

    case "$line" in
      "mcps:"*)
        in_mcps=1
        continue
        ;;
    esac
    [ "$in_mcps" -eq 0 ] && continue

    # End of mcps block: non-indented, non-empty line
    case "$line" in
      "  "* | "	"*) ;; # still indented
      "")            continue ;;
      *)
        if [ "$in_server" -eq 1 ] && [ -n "$name" ]; then
          if [ "$server_count" -eq 0 ]; then
            server_names="$name"; server_commands="$command"
            server_args_list="$args"; server_envs="$env_pairs"
          else
            server_names="${server_names}"$'\n'"${name}"
            server_commands="${server_commands}"$'\n'"${command}"
            server_args_list="${server_args_list}"$'\n'"${args}"
            server_envs="${server_envs}"$'\n'"${env_pairs}"
          fi
          server_count=$((server_count + 1))
        fi
        in_mcps=0
        break
        ;;
    esac

    # Trim leading whitespace
    line="${line#"${line%%[! ]*}"}"
    line="${line#"${line%%[!	]*}"}"

    case "$line" in
      "- name: "*)
        if [ "$in_server" -eq 1 ] && [ -n "$name" ]; then
          if [ "$server_count" -eq 0 ]; then
            server_names="$name"; server_commands="$command"
            server_args_list="$args"; server_envs="$env_pairs"
          else
            server_names="${server_names}"$'\n'"${name}"
            server_commands="${server_commands}"$'\n'"${command}"
            server_args_list="${server_args_list}"$'\n'"${args}"
            server_envs="${server_envs}"$'\n'"${env_pairs}"
          fi
          server_count=$((server_count + 1))
        fi
        name="${line#- name: }"
        command=""; args=""; env_pairs=""
        in_server=1; in_env=0
        ;;
      "command: "*) command="${line#command: }"; in_env=0 ;;
      "args: "*) args="${line#args: }"; in_env=0 ;;
      "env:"*) in_env=1 ;;
      *)
        if [ "$in_env" -eq 1 ]; then
          local key val
          key="${line%%:*}"; key="${key#"${key%%[! ]*}"}"
          val="${line#*: }"
          if [ -n "$key" ] && [ -n "$val" ]; then
            if [ -n "$env_pairs" ]; then
              env_pairs="${env_pairs},${key}=${val}"
            else
              env_pairs="${key}=${val}"
            fi
          fi
        fi
        ;;
    esac
  done < "$team_def"

  # Emit last server
  if [ "$in_server" -eq 1 ] && [ -n "$name" ]; then
    if [ "$server_count" -eq 0 ]; then
      server_names="$name"; server_commands="$command"
      server_args_list="$args"; server_envs="$env_pairs"
    else
      server_names="${server_names}"$'\n'"${name}"
      server_commands="${server_commands}"$'\n'"${command}"
      server_args_list="${server_args_list}"$'\n'"${args}"
      server_envs="${server_envs}"$'\n'"${env_pairs}"
    fi
    server_count=$((server_count + 1))
  fi

  if [ "$server_count" -eq 0 ]; then
    printf '{"mcpServers": {}}\n' > "$output_file"
    doey_mcp_log "INFO" "No MCPs in team def for window ${window_index}"
    return 0
  fi

  _mcp_build_json "$output_file" "$server_count" "$server_names" \
    "$server_commands" "$server_args_list" "$server_envs"
  doey_mcp_log "INFO" "Generated team MCP config for window ${window_index}: ${output_file}"
}

# ── Pane Config (merged team + skill) ──────────────────────────────

# Merge team-level and skill-level MCP servers for a specific pane.
# Echoes the output file path.
# Usage: doey_mcp_generate_pane_config <runtime_dir> <window_index> <pane_index> [skill_names...]
doey_mcp_generate_pane_config() {
  local runtime_dir="$1" window_index="$2" pane_index="$3"
  shift 3

  local output_file="${runtime_dir}/mcp/pane_${window_index}_${pane_index}.mcp.json"
  mkdir -p "${runtime_dir}/mcp"

  local team_config="${runtime_dir}/mcp/team_${window_index}.mcp.json"

  # Collect skill-level servers
  local skill_count=0
  local skill_names_list="" skill_commands="" skill_args="" skill_envs=""
  local project_root="${DOEY_PROJECT_ROOT:-$(pwd)}"

  local skill_name
  for skill_name in "$@"; do
    local skill_dir="${project_root}/.claude/skills/${skill_name}"
    [ ! -d "$skill_dir" ] && continue

    local entry
    while IFS= read -r entry || [ -n "$entry" ]; do
      [ -z "$entry" ] && continue
      local s_name s_cmd s_args s_env
      s_name="${entry%%|*}"; entry="${entry#*|}"
      s_cmd="${entry%%|*}"; entry="${entry#*|}"
      s_args="${entry%%|*}"
      s_env="${entry#*|}"
      s_cmd="$(_mcp_expand_env "$s_cmd")"
      s_args="$(_mcp_expand_env "$s_args")"

      if [ "$skill_count" -eq 0 ]; then
        skill_names_list="$s_name"; skill_commands="$s_cmd"
        skill_args="$s_args"; skill_envs="$s_env"
      else
        skill_names_list="${skill_names_list}"$'\n'"${s_name}"
        skill_commands="${skill_commands}"$'\n'"${s_cmd}"
        skill_args="${skill_args}"$'\n'"${s_args}"
        skill_envs="${skill_envs}"$'\n'"${s_env}"
      fi
      skill_count=$((skill_count + 1))
    done <<EOF
$(doey_mcp_parse_skill_frontmatter "$skill_dir")
EOF
  done

  # If team config exists, merge team servers + skill servers
  if [ -f "$team_config" ]; then
    # Read team JSON and extract server blocks (simple line-based merge)
    # Strategy: rebuild from team config content + skill entries
    local team_content
    team_content="$(cat "$team_config")"

    if [ "$skill_count" -eq 0 ]; then
      # No skill servers — just copy team config
      cp "$team_config" "$output_file"
      doey_mcp_log "INFO" "Pane ${window_index}.${pane_index}: team config only"
      printf '%s' "$output_file"
      return 0
    fi

    # Both team and skill servers exist — merge by appending skill JSON into team JSON
    # Remove trailing }}} from team config, append skill servers, close
    local base="${team_content%\}*}"  # remove last }
    base="${base%\}*}"                # remove second-to-last }

    local i=0
    while [ "$i" -lt "$skill_count" ]; do
      local name cmd args_str env_str
      name="$(printf '%s\n' "$skill_names_list" | sed -n "$((i + 1))p")"
      cmd="$(printf '%s\n' "$skill_commands" | sed -n "$((i + 1))p")"
      args_str="$(printf '%s\n' "$skill_args" | sed -n "$((i + 1))p")"
      env_str="$(printf '%s\n' "$skill_envs" | sed -n "$((i + 1))p")"

      local escaped_name escaped_cmd
      escaped_name="$(_mcp_json_escape "$name")"
      escaped_cmd="$(_mcp_json_escape "$cmd")"

      local args_json="["
      local arg_first=1 arg
      for arg in $args_str; do
        arg="$(_mcp_expand_env "$arg")"
        local escaped_arg
        escaped_arg="$(_mcp_json_escape "$arg")"
        if [ "$arg_first" -eq 1 ]; then
          arg_first=0; args_json="${args_json}\"${escaped_arg}\""
        else
          args_json="${args_json}, \"${escaped_arg}\""
        fi
      done
      args_json="${args_json}]"

      local env_json="{"
      if [ -n "$env_str" ]; then
        local env_first=1 remaining pair key val
        remaining="$env_str"
        while [ -n "$remaining" ]; do
          case "$remaining" in
            *","*) pair="${remaining%%,*}"; remaining="${remaining#*,}" ;;
            *)     pair="$remaining"; remaining="" ;;
          esac
          key="${pair%%=*}"; val="${pair#*=}"
          val="$(_mcp_expand_env "$val")"
          local escaped_val
          escaped_val="$(_mcp_json_escape "$val")"
          if [ "$env_first" -eq 1 ]; then
            env_first=0; env_json="${env_json}\"${key}\": \"${escaped_val}\""
          else
            env_json="${env_json}, \"${key}\": \"${escaped_val}\""
          fi
        done
      fi
      env_json="${env_json}}"

      base="${base}, \"${escaped_name}\": {\"command\": \"${escaped_cmd}\", \"args\": ${args_json}, \"env\": ${env_json}}"
      i=$((i + 1))
    done

    printf '%s}}\n' "$base" > "$output_file"
  else
    # No team config — skill servers only
    if [ "$skill_count" -eq 0 ]; then
      printf '{"mcpServers": {}}\n' > "$output_file"
    else
      _mcp_build_json "$output_file" "$skill_count" "$skill_names_list" \
        "$skill_commands" "$skill_args" "$skill_envs"
    fi
  fi

  doey_mcp_log "INFO" "Generated pane MCP config ${window_index}.${pane_index}: ${output_file}"
  printf '%s' "$output_file"
}

# ── Cleanup ─────────────────────────────────────────────────────────

# Kill a process with SIGTERM, wait up to 5s, then SIGKILL.
_mcp_kill_pid() {
  local pid="$1" pid_file="${2:-}"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while [ "$waited" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      doey_mcp_log "WARN" "Force-killed MCP process ${pid}"
    else
      doey_mcp_log "INFO" "Stopped MCP process ${pid}"
    fi
  fi
  [ -n "$pid_file" ] && rm -f "$pid_file"
}

# Remove MCP config and kill tracked PIDs for a specific pane.
# Usage: doey_mcp_cleanup_pane <runtime_dir> <pane_safe>
doey_mcp_cleanup_pane() {
  local runtime_dir="$1" pane_safe="$2"
  local mcp_dir="${runtime_dir}/mcp"
  local pid_dir="${mcp_dir}/pids"

  # Kill tracked PIDs
  if [ -d "$pid_dir" ]; then
    local pid_file
    for pid_file in "${pid_dir}/${pane_safe}_"*.pid; do
      [ -f "$pid_file" ] || continue
      local pid
      pid="$(cat "$pid_file" 2>/dev/null)" || continue
      [ -n "$pid" ] && _mcp_kill_pid "$pid" "$pid_file"
    done
  fi

  # Remove pane config files matching this pane
  local cfg
  for cfg in "${mcp_dir}/pane_"*".mcp.json"; do
    [ -f "$cfg" ] || continue
    local basename
    basename="$(basename "$cfg")"
    case "$basename" in
      *"${pane_safe}"*) rm -f "$cfg"; doey_mcp_log "INFO" "Removed ${cfg}" ;;
    esac
  done
}

# Cleanup all MCP for a team window.
# Usage: doey_mcp_cleanup_team <runtime_dir> <window_index>
doey_mcp_cleanup_team() {
  local runtime_dir="$1" window_index="$2"
  local mcp_dir="${runtime_dir}/mcp"
  local pid_dir="${mcp_dir}/pids"

  # Kill all PIDs for this window
  if [ -d "$pid_dir" ]; then
    local pid_file
    for pid_file in "${pid_dir}/"*".pid"; do
      [ -f "$pid_file" ] || continue
      local basename
      basename="$(basename "$pid_file")"
      case "$basename" in
        "${window_index}_"* | *"_${window_index}_"*)
          local pid
          pid="$(cat "$pid_file" 2>/dev/null)" || continue
          [ -n "$pid" ] && _mcp_kill_pid "$pid" "$pid_file"
          ;;
      esac
    done
  fi

  # Remove all config files for this window
  rm -f "${mcp_dir}/team_${window_index}.mcp.json"
  local cfg
  for cfg in "${mcp_dir}/pane_${window_index}_"*.mcp.json; do
    [ -f "$cfg" ] || continue
    rm -f "$cfg"
  done

  doey_mcp_log "INFO" "Cleaned up MCP for team window ${window_index}"
}

# Remove all MCP configs and PIDs globally for the session.
# Usage: doey_mcp_cleanup_session <runtime_dir>
doey_mcp_cleanup_session() {
  local runtime_dir="$1"
  local mcp_dir="${runtime_dir}/mcp"

  if [ ! -d "$mcp_dir" ]; then
    return 0
  fi

  # Kill all tracked PIDs
  local pid_dir="${mcp_dir}/pids"
  if [ -d "$pid_dir" ]; then
    local pid_file
    for pid_file in "${pid_dir}/"*.pid; do
      [ -f "$pid_file" ] || continue
      local pid
      pid="$(cat "$pid_file" 2>/dev/null)" || continue
      [ -n "$pid" ] && _mcp_kill_pid "$pid" "$pid_file"
    done
    rm -rf "$pid_dir"
  fi

  # Remove all config files
  rm -f "${mcp_dir}/"*.mcp.json

  doey_mcp_log "INFO" "Cleaned up all MCP for session"
}
