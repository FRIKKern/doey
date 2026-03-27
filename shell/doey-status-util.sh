#!/usr/bin/env bash
set -euo pipefail

# doey-status-util.sh — Status/monitoring utility for Doey runtime files.
# Replaces inline bash patterns with a single entry point.

usage() {
    printf "Usage: doey-status-util <command> [args]\n\n"
    printf "Commands:\n"
    printf "  read    PANE_SAFE           Read status file for a pane\n"
    printf "  list    [WINDOW]            List all status files (optionally by window)\n"
    printf "  crashes [WINDOW]            List crash alert files\n"
    printf "  results [WINDOW]            List result JSON files\n"
    printf "  health  PANE_SAFE [--max-age N]  Check pane health (default max-age: 60s)\n"
    printf "  team-env WINDOW             Read team environment file\n"
    exit 1
}

# Require RUNTIME_DIR
if [ -z "${RUNTIME_DIR:-}" ]; then
    printf "Error: RUNTIME_DIR is not set\n" >&2
    exit 1
fi

if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
fi

cmd="$1"
shift

# Helper: print files with separators
_print_files() {
    local pattern="$1"
    local found=0
    # Use bash subshell for nullglob (zsh safety)
    local file_list
    file_list="$(bash -c 'shopt -s nullglob; for f in '"${pattern}"'; do printf "%s\n" "$f"; done')"
    if [ -z "$file_list" ]; then
        printf "No files found matching: %s\n" "$pattern"
        return 1
    fi
    while IFS= read -r f; do
        found=1
        printf "=== %s ===\n" "$(basename "$f")"
        cat "$f"
        printf "\n---\n"
    done <<EOF
${file_list}
EOF
    if [ "$found" -eq 0 ]; then
        printf "No files found matching: %s\n" "$pattern"
        return 1
    fi
    return 0
}

case "$cmd" in
    read)
        if [ $# -lt 1 ]; then
            printf "Usage: doey-status-util read PANE_SAFE\n" >&2
            exit 1
        fi
        pane_safe="$1"
        status_file="${RUNTIME_DIR}/status/${pane_safe}.status"
        if [ ! -f "$status_file" ]; then
            printf "Error: Status file not found: %s\n" "$status_file" >&2
            exit 1
        fi
        cat "$status_file"
        ;;

    list)
        window="${1:-}"
        if [ -n "$window" ]; then
            _print_files "${RUNTIME_DIR}/status/pane_${window}_*.status"
        else
            _print_files "${RUNTIME_DIR}/status/*.status"
        fi
        ;;

    crashes)
        window="${1:-}"
        if [ -n "$window" ]; then
            _print_files "${RUNTIME_DIR}/status/crash_pane_${window}_*"
        else
            _print_files "${RUNTIME_DIR}/status/crash_pane_*"
        fi
        ;;

    results)
        window="${1:-}"
        if [ -n "$window" ]; then
            _print_files "${RUNTIME_DIR}/results/pane_${window}_*.json"
        else
            _print_files "${RUNTIME_DIR}/results/*.json"
        fi
        ;;

    health)
        if [ $# -lt 1 ]; then
            printf "Usage: doey-status-util health PANE_SAFE [--max-age N]\n" >&2
            exit 1
        fi
        pane_safe="$1"
        shift
        max_age=60
        while [ $# -gt 0 ]; do
            case "$1" in
                --max-age)
                    if [ $# -lt 2 ]; then
                        printf "Error: --max-age requires a value\n" >&2
                        exit 1
                    fi
                    max_age="$2"
                    shift 2
                    ;;
                *)
                    printf "Unknown option: %s\n" "$1" >&2
                    exit 1
                    ;;
            esac
        done

        status_file="${RUNTIME_DIR}/status/${pane_safe}.status"
        if [ ! -f "$status_file" ]; then
            printf "Error: Status file not found: %s\n" "$status_file" >&2
            exit 1
        fi

        # Read status value
        status="UNKNOWN"
        updated=""
        while IFS= read -r line; do
            case "$line" in
                STATUS=*) status="${line#STATUS=}" ;;
                UPDATED=*) updated="${line#UPDATED=}" ;;
            esac
        done < "$status_file"

        if [ -z "$updated" ]; then
            printf "STATUS=%s AGE=unknown\n" "$status"
            exit 1
        fi

        # Parse ISO 8601 timestamp (macOS date -j compatible)
        # Strip colon from timezone if present: +01:00 → +0100
        clean_ts="$updated"
        # Handle +HH:MM or -HH:MM timezone format → +HHMM
        case "$clean_ts" in
            *[+-][0-9][0-9]:[0-9][0-9])
                tz_part="${clean_ts: -6}"
                base_part="${clean_ts%??????}"
                tz_clean="${tz_part%:*}${tz_part##*:}"
                clean_ts="${base_part}${tz_clean}"
                ;;
        esac

        # Parse with date -j -f (macOS)
        ts_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$clean_ts" "+%s" 2>/dev/null)" || {
            printf "STATUS=%s AGE=unknown\n" "$status"
            exit 1
        }

        now_epoch="$(date "+%s")"
        age=$(( now_epoch - ts_epoch ))
        if [ "$age" -lt 0 ]; then
            age=0
        fi

        printf "STATUS=%s AGE=%d\n" "$status" "$age"

        if [ "$age" -gt "$max_age" ]; then
            exit 1
        fi
        ;;

    team-env)
        if [ $# -lt 1 ]; then
            printf "Usage: doey-status-util team-env WINDOW\n" >&2
            exit 1
        fi
        window="$1"
        env_file="${RUNTIME_DIR}/team_${window}.env"
        if [ ! -f "$env_file" ]; then
            printf "Error: Team env file not found: %s\n" "$env_file" >&2
            exit 1
        fi
        cat "$env_file"
        ;;

    *)
        printf "Unknown command: %s\n" "$cmd" >&2
        usage
        ;;
esac
