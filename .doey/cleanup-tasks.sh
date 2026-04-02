#!/usr/bin/env bash
set -euo pipefail

# cleanup-tasks.sh — Normalize .task files to high quality standard
# Usage: cleanup-tasks.sh [file.task]   (one file or all in .doey/tasks/)

TASKS_DIR="/home/doey/doey/.doey/tasks"
BACKUP_DIR="/tmp/doey/task-backup"

# Counters
files_processed=0
fields_stripped=0
reports_removed=0
statuses_synced=0
decisions_cleaned=0
timestamps_deduped=0
dupes_removed=0
schema_set=0
trailing_status_removed=0

mkdir -p "$BACKUP_DIR"

cleanup_file() {
    local src="$1"
    local basename
    basename="$(basename "$src")"
    local task_id="${basename%.task}"

    # Skip non-numeric filenames
    case "$task_id" in
        *[!0-9]*) echo "SKIP: $basename (non-numeric ID)"; return 0 ;;
    esac

    # Backup
    cp "$src" "$BACKUP_DIR/$basename.bak"

    local tmp
    tmp="$(mktemp)"

    # Read file into temp for processing
    cp "$src" "$tmp"

    # --- (a) Sync TASK_STATUS from DB ---
    local db_status=""
    if db_status="$(doey-ctl task get "$task_id" 2>/dev/null | grep '^Status:' | sed 's/^Status:[[:space:]]*//')"; then
        if [ -n "$db_status" ]; then
            local file_status=""
            file_status="$(grep '^TASK_STATUS=' "$tmp" | head -1 | sed 's/^TASK_STATUS=//')" || true
            if [ -n "$file_status" ] && [ "$file_status" != "$db_status" ]; then
                # Replace first TASK_STATUS line
                sed -i "0,/^TASK_STATUS=/{s/^TASK_STATUS=.*/TASK_STATUS=$db_status/}" "$tmp"
                statuses_synced=$((statuses_synced + 1))
            elif [ -z "$file_status" ]; then
                # No TASK_STATUS line — add after TASK_ID
                sed -i "/^TASK_ID=/a TASK_STATUS=$db_status" "$tmp"
                statuses_synced=$((statuses_synced + 1))
            fi
        fi
    fi

    # --- (b) Strip empty fields ---
    local empty_fields="TASK_TAGS TASK_ACCEPTANCE_CRITERIA TASK_HYPOTHESES TASK_BLOCKERS TASK_RELATED_FILES TASK_NOTES TASK_CREATED_BY TASK_SUBTASKS TASK_ASSIGNED_TO TASK_DECISION_LOG"
    for field in $empty_fields; do
        if grep -q "^${field}=\$" "$tmp"; then
            sed -i "/^${field}=\$/d" "$tmp"
            fields_stripped=$((fields_stripped + 1))
        fi
    done

    # --- (b2) Clean TASK_SUBTASKS noise entries ---
    # Remove subtask entries that are raw CLI args (e.g., "--title test subtask --project-dir")
    if grep -q '^TASK_SUBTASKS=' "$tmp"; then
        local raw_subs=""
        raw_subs="$(grep '^TASK_SUBTASKS=' "$tmp" | head -1 | sed 's/^TASK_SUBTASKS=//')"
        if [ -n "$raw_subs" ]; then
            local cleaned_subs=""
            local sub_dropped=0
            local old_ifs="$IFS"
            # Subtasks are \n-separated
            local expanded_subs
            expanded_subs="$(printf '%s' "$raw_subs" | sed 's/\\n/\n/g')"
            while IFS= read -r sub_entry; do
                case "$sub_entry" in
                    *"--title"*"--project-dir"*) sub_dropped=$((sub_dropped + 1)); continue ;;
                    "") continue ;;
                esac
                if [ -z "$cleaned_subs" ]; then
                    cleaned_subs="$sub_entry"
                else
                    cleaned_subs="${cleaned_subs}\\n${sub_entry}"
                fi
            done <<SUBTASKS
$expanded_subs
SUBTASKS
            IFS="$old_ifs"
            if [ "$sub_dropped" -gt 0 ]; then
                local tmp_sub
                tmp_sub="$(mktemp)"
                local wrote_sub=0
                while IFS= read -r line || [ -n "$line" ]; do
                    case "$line" in
                        TASK_SUBTASKS=*)
                            if [ "$wrote_sub" -eq 0 ]; then
                                if [ -n "$cleaned_subs" ]; then
                                    printf '%s\n' "TASK_SUBTASKS=$cleaned_subs" >> "$tmp_sub"
                                fi
                                wrote_sub=1
                            fi
                            ;;
                        *) printf '%s\n' "$line" >> "$tmp_sub" ;;
                    esac
                done < "$tmp"
                mv "$tmp_sub" "$tmp"
                fields_stripped=$((fields_stripped + sub_dropped))
            fi
        fi
    fi

    # --- (c) Clean decision logs: remove raw CLI arg lines ---
    # Entries in TASK_DECISION_LOG are \n-separated within the value.
    # Strategy: rewrite entire file, replacing the TASK_DECISION_LOG line
    if grep -q '^TASK_DECISION_LOG=' "$tmp"; then
        local raw_log=""
        raw_log="$(grep '^TASK_DECISION_LOG=' "$tmp" | head -1 | sed 's/^TASK_DECISION_LOG=//')"
        if [ -n "$raw_log" ]; then
            local expanded_log
            expanded_log="$(printf '%s' "$raw_log" | sed 's/\\n/\n/g')"
            local cleaned_log=""
            local dropped=0
            while IFS= read -r entry; do
                case "$entry" in
                    *"--type decision --author"*) dropped=$((dropped + 1)); continue ;;
                    *"--type progress"*) dropped=$((dropped + 1)); continue ;;
                    *"--type report:completion --author"*) dropped=$((dropped + 1)); continue ;;
                    *"--title test subtask --project-dir"*) dropped=$((dropped + 1)); continue ;;
                    "") continue ;;
                esac
                if [ -z "$cleaned_log" ]; then
                    cleaned_log="$entry"
                else
                    cleaned_log="${cleaned_log}\\n${entry}"
                fi
            done <<DECLOG
$expanded_log
DECLOG
            decisions_cleaned=$((decisions_cleaned + dropped))

            if [ "$dropped" -gt 0 ]; then
                # Rewrite file line by line, replacing TASK_DECISION_LOG
                local tmp2
                tmp2="$(mktemp)"
                local wrote_declog=0
                while IFS= read -r line || [ -n "$line" ]; do
                    case "$line" in
                        TASK_DECISION_LOG=*)
                            if [ "$wrote_declog" -eq 0 ]; then
                                if [ -n "$cleaned_log" ]; then
                                    printf '%s\n' "TASK_DECISION_LOG=$cleaned_log" >> "$tmp2"
                                fi
                                # else: all noise, skip the line entirely
                                wrote_declog=1
                            fi
                            # skip duplicate TASK_DECISION_LOG lines
                            ;;
                        *)
                            printf '%s\n' "$line" >> "$tmp2"
                            ;;
                    esac
                done < "$tmp"
                mv "$tmp2" "$tmp"
            fi
        fi
    fi

    # --- (d) Remove noise TASK_REPORT_N blocks ---
    # Find report numbers that have "completed with N tool calls, 0 files changed"
    local report_nums_to_remove=""
    local n=1
    while [ "$n" -le 50 ]; do
        local body_line=""
        body_line="$(grep "^TASK_REPORT_${n}_BODY=" "$tmp" 2>/dev/null)" || true
        if [ -z "$body_line" ]; then
            # No more reports at this index — but there could be gaps, check a few more
            if [ "$n" -gt 10 ]; then
                break
            fi
            n=$((n + 1))
            continue
        fi
        # Check if body matches noise pattern: "completed with N tool calls, 0 files changed"
        if echo "$body_line" | grep -q 'completed with [0-9]* tool calls, 0 files changed'; then
            report_nums_to_remove="$report_nums_to_remove $n"
        fi
        n=$((n + 1))
    done

    for rn in $report_nums_to_remove; do
        sed -i "/^TASK_REPORT_${rn}_TYPE=/d" "$tmp"
        sed -i "/^TASK_REPORT_${rn}_TITLE=/d" "$tmp"
        sed -i "/^TASK_REPORT_${rn}_BODY=/d" "$tmp"
        sed -i "/^TASK_REPORT_${rn}_AUTHOR=/d" "$tmp"
        sed -i "/^TASK_REPORT_${rn}_TIMESTAMP=/d" "$tmp"
        reports_removed=$((reports_removed + 1))
    done

    # --- (f) Deduplicate TASK_TIMESTAMPS ---
    if grep -q '^TASK_TIMESTAMPS=' "$tmp"; then
        local ts_line=""
        ts_line="$(grep '^TASK_TIMESTAMPS=' "$tmp" | tail -1 | sed 's/^TASK_TIMESTAMPS=//')"
        if [ -n "$ts_line" ]; then
            # Parse pipe-separated entries
            local first_created="" last_completed="" other_entries=""
            local old_ifs="$IFS"
            IFS='|'
            for entry in $ts_line; do
                case "$entry" in
                    created=*)
                        if [ -z "$first_created" ]; then
                            first_created="$entry"
                        else
                            timestamps_deduped=$((timestamps_deduped + 1))
                        fi
                        ;;
                    completed=*)
                        last_completed="$entry"
                        ;;
                    *)
                        if [ -n "$entry" ]; then
                            if [ -z "$other_entries" ]; then
                                other_entries="$entry"
                            else
                                other_entries="${other_entries}|${entry}"
                            fi
                        fi
                        ;;
                esac
            done
            IFS="$old_ifs"

            # Count original completed= entries
            local orig_completed_count=0
            local check_ifs="$IFS"
            IFS='|'
            for entry in $ts_line; do
                case "$entry" in
                    completed=*) orig_completed_count=$((orig_completed_count + 1)) ;;
                esac
            done
            IFS="$check_ifs"
            if [ "$orig_completed_count" -gt 1 ]; then
                timestamps_deduped=$((timestamps_deduped + orig_completed_count - 1))
            fi

            # Rebuild
            local new_ts="$first_created"
            if [ -n "$other_entries" ]; then
                new_ts="${new_ts}|${other_entries}"
            fi
            if [ -n "$last_completed" ]; then
                new_ts="${new_ts}|${last_completed}"
            fi

            if [ "$new_ts" != "$ts_line" ]; then
                # Rewrite line by line to avoid sed escaping issues
                local tmp_ts
                tmp_ts="$(mktemp)"
                local wrote_ts=0
                while IFS= read -r line || [ -n "$line" ]; do
                    case "$line" in
                        TASK_TIMESTAMPS=*)
                            if [ "$wrote_ts" -eq 0 ]; then
                                printf '%s\n' "TASK_TIMESTAMPS=$new_ts" >> "$tmp_ts"
                                wrote_ts=1
                            fi
                            ;;
                        *) printf '%s\n' "$line" >> "$tmp_ts" ;;
                    esac
                done < "$tmp"
                mv "$tmp_ts" "$tmp"
            fi
        fi
        # Remove duplicate TASK_TIMESTAMPS lines (keep last)
        local ts_count
        ts_count="$(grep -c '^TASK_TIMESTAMPS=' "$tmp")" || true
        if [ "$ts_count" -gt 1 ]; then
            # Keep only the last TASK_TIMESTAMPS line
            local last_ts
            last_ts="$(grep '^TASK_TIMESTAMPS=' "$tmp" | tail -1)"
            sed -i '/^TASK_TIMESTAMPS=/d' "$tmp"
            echo "$last_ts" >> "$tmp"
            dupes_removed=$((dupes_removed + 1))
        fi
    fi

    # --- (g) Remove duplicate fields (keep later/more complete one) ---
    local dup_fields="TASK_CURRENT_PHASE TASK_TOTAL_PHASES TASK_STATUS TASK_TEAM TASK_TYPE TASK_OWNER TASK_ASSIGNED_TO TASK_DISPATCH_MODE TASK_UPDATED TASK_SCHEMA_VERSION TASK_SUBTASKS TASK_RESULT TASK_REVIEW_TIMESTAMP"
    for field in $dup_fields; do
        local count
        count="$(grep -c "^${field}=" "$tmp")" || true
        if [ "$count" -gt 1 ]; then
            # Keep only the last occurrence via line-by-line rewrite
            local last_val
            last_val="$(grep "^${field}=" "$tmp" | tail -1)"
            local tmp_dup
            tmp_dup="$(mktemp)"
            local wrote_field=0
            # First pass: collect all lines except this field
            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                    "${field}="*) ;;  # skip all occurrences
                    *) printf '%s\n' "$line" >> "$tmp_dup" ;;
                esac
            done < "$tmp"
            # Insert the last value after TASK_ID line
            local tmp_dup2
            tmp_dup2="$(mktemp)"
            local inserted=0
            while IFS= read -r line || [ -n "$line" ]; do
                printf '%s\n' "$line" >> "$tmp_dup2"
                if [ "$inserted" -eq 0 ]; then
                    case "$line" in
                        TASK_ID=*)
                            printf '%s\n' "$last_val" >> "$tmp_dup2"
                            inserted=1
                            ;;
                    esac
                fi
            done < "$tmp_dup"
            if [ "$inserted" -eq 0 ]; then
                printf '%s\n' "$last_val" >> "$tmp_dup2"
            fi
            mv "$tmp_dup2" "$tmp"
            rm -f "$tmp_dup"
            dupes_removed=$((dupes_removed + 1))
        fi
    done

    # --- (h) Set TASK_SCHEMA_VERSION=3 ---
    if grep -q '^TASK_SCHEMA_VERSION=' "$tmp"; then
        local cur_ver
        cur_ver="$(grep '^TASK_SCHEMA_VERSION=' "$tmp" | head -1 | sed 's/^TASK_SCHEMA_VERSION=//')"
        if [ "$cur_ver" != "3" ]; then
            sed -i "s/^TASK_SCHEMA_VERSION=.*/TASK_SCHEMA_VERSION=3/" "$tmp"
            schema_set=$((schema_set + 1))
        fi
    else
        # Add as first line
        sed -i '1i TASK_SCHEMA_VERSION=3' "$tmp"
        # Fix: sed may add a leading space
        sed -i '1s/^ //' "$tmp"
        schema_set=$((schema_set + 1))
    fi

    # --- (i) Remove trailing bare status=done lines ---
    if grep -q '^status=done' "$tmp"; then
        sed -i '/^status=done$/d' "$tmp"
        trailing_status_removed=$((trailing_status_removed + 1))
    fi
    if grep -q '^status=' "$tmp"; then
        # Also catch status=<anything> that's not TASK_STATUS
        sed -i '/^status=/d' "$tmp"
        trailing_status_removed=$((trailing_status_removed + 1))
    fi

    # --- (j) Remove trailing blank lines, keep one trailing newline ---
    # Remove all trailing blank lines
    while [ -s "$tmp" ]; do
        local last_line
        last_line="$(tail -1 "$tmp")"
        if [ -z "$last_line" ]; then
            # Remove last empty line
            sed -i '$ { /^$/d }' "$tmp"
        else
            break
        fi
    done
    # Ensure file ends with newline
    if [ -s "$tmp" ]; then
        local last_char
        last_char="$(tail -c 1 "$tmp")"
        if [ -n "$last_char" ]; then
            echo "" >> "$tmp"
        fi
    fi

    # Also remove blank lines within the file that are between fields
    # (but preserve blank lines that are part of multi-line TASK_DESCRIPTION)
    # Only remove standalone blank lines that appear between TASK_ field lines
    # Be conservative: only remove blank lines that are followed by a TASK_ or EOF
    # Actually, let's only remove consecutive blank lines (reduce to max 1)
    sed -i '/^$/{ N; /^\n$/d }' "$tmp"

    # Atomic write
    mv "$tmp" "$src"
    files_processed=$((files_processed + 1))
    echo "OK: $basename"
}

# Main
if [ $# -gt 0 ]; then
    # Single file mode
    if [ ! -f "$1" ]; then
        echo "ERROR: File not found: $1" >&2
        exit 1
    fi
    cleanup_file "$1"
else
    # Process all .task files
    for f in "$TASKS_DIR"/*.task; do
        [ -f "$f" ] || continue
        cleanup_file "$f"
    done
fi

echo ""
echo "=== Cleanup Summary ==="
echo "Files processed:        $files_processed"
echo "Empty fields stripped:   $fields_stripped"
echo "Noise reports removed:   $reports_removed"
echo "Statuses synced from DB: $statuses_synced"
echo "Decision log entries cleaned: $decisions_cleaned"
echo "Timestamps deduplicated: $timestamps_deduped"
echo "Duplicate fields removed: $dupes_removed"
echo "Schema version set:      $schema_set"
echo "Trailing status removed: $trailing_status_removed"
