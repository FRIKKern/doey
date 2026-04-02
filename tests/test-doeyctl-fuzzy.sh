#!/usr/bin/env bash
set -euo pipefail

# Regression tests for doey-ctl fuzzy input tolerance (task 146).
# Bash 3.2 compatible — no associative arrays, no bash 4+ features.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="/tmp/doey-ctl"
PASS=0
FAIL=0
TOTAL=0

# --- Build ---
echo "Building doey-ctl..."
export PATH="/usr/local/go/bin:$PATH"
(cd "$PROJECT_ROOT/tui" && go build -o "$CTL" ./cmd/doey-ctl/) || {
    echo "FATAL: failed to build doey-ctl"
    exit 1
}

# --- Temp fixture ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/.doey/tasks"
cat > "$TMPDIR/.doey/tasks/1.task" << 'EOF'
TASK_ID=1
TASK_TITLE=Test task one
TASK_STATUS=pending
TASK_CREATED=1700000000
TASK_TYPE=task
TASK_SCHEMA_VERSION=3
TASK_CREATED_BY=testuser
EOF

cat > "$TMPDIR/.doey/tasks/2.task" << 'EOF'
TASK_ID=2
TASK_TITLE=Test task two
TASK_STATUS=active
TASK_CREATED=1700000001
TASK_TYPE=task
TASK_SCHEMA_VERSION=3
TASK_CREATED_BY=testuser
EOF

PD="-project-dir"

# --- Test helper ---
run_test() {
    local name="$1"; shift
    local expect_exit="$1"; shift
    local expect_output="$1"; shift  # grep -i pattern for stdout+stderr
    TOTAL=$((TOTAL + 1))
    local output; local exit_code=0
    output=$("$@" 2>&1) || exit_code=$?
    if [ "$exit_code" -ne "$expect_exit" ]; then
        echo "FAIL: $name (exit $exit_code, expected $expect_exit)"
        echo "  output: $(echo "$output" | head -3)"
        FAIL=$((FAIL + 1))
        return
    fi
    if [ -n "$expect_output" ] && ! echo "$output" | grep -qi "$expect_output"; then
        echo "FAIL: $name (output missing: $expect_output)"
        echo "  got: $(echo "$output" | head -3)"
        FAIL=$((FAIL + 1))
        return
    fi
    echo "PASS: $name"
    PASS=$((PASS + 1))
}

echo ""
echo "=== A) Flag variations on task update ==="

run_test "update --id --status convenience flags" \
    0 "" \
    "$CTL" task update "$PD" "$TMPDIR" --id 1 --status done

run_test "update -field -value original syntax" \
    0 "" \
    "$CTL" task update "$PD" "$TMPDIR" -field status -value active 1

echo ""
echo "=== B) Field normalization ==="

run_test "TASK_STATUS prefix stripped" \
    0 "" \
    "$CTL" task update "$PD" "$TMPDIR" -field TASK_STATUS -value done 1

run_test "Status case normalization" \
    0 "" \
    "$CTL" task update "$PD" "$TMPDIR" -field Status -value active 1

echo ""
echo "=== C) ID normalization ==="

run_test "numeric ID works" \
    0 "Title" \
    "$CTL" task get "$PD" "$TMPDIR" 1

run_test "#1 hash-prefix not supported" \
    1 "" \
    "$CTL" task get "$PD" "$TMPDIR" '#1'

echo ""
echo "=== D) Convenience forms on other commands ==="

run_test "task get positional ID" \
    0 "Title" \
    "$CTL" task get "$PD" "$TMPDIR" 1

run_test "task get --id flag" \
    0 "Title" \
    "$CTL" task get "$PD" "$TMPDIR" --id 1

echo ""
echo "=== E) Argument ordering ==="

run_test "flags before positional: --status done 2" \
    0 "" \
    "$CTL" task update "$PD" "$TMPDIR" --status done 2

run_test "flags after positional rejected: 2 --status active" \
    1 "field.*required\|status.*required" \
    "$CTL" task update "$PD" "$TMPDIR" 2 --status active

echo ""
echo "=== F) Subcommand fuzzy matching ==="

run_test "task updat suggests update" \
    1 "did you mean.*update" \
    "$CTL" task updat

run_test "task subtask updat suggests update" \
    1 "did you mean.*update" \
    "$CTL" task subtask updat

run_test "task creat suggests create" \
    1 "did you mean.*create" \
    "$CTL" task creat

echo ""
echo "=== G) Helpful error messages ==="

run_test "task update no args shows help hint" \
    1 "Try:" \
    "$CTL" task update

run_test "task subtask update no args shows help hint" \
    1 "Try:" \
    "$CTL" task subtask update

echo ""
echo "=== H) Help output ==="

run_test "task --help exits 0 with Usage" \
    0 "Usage\|Subcommands" \
    "$CTL" task --help

run_test "task -h exits 0 with Usage" \
    0 "Usage\|Subcommands" \
    "$CTL" task -h

run_test "task subtask --help exits 0" \
    0 "Usage\|Subcommands" \
    "$CTL" task subtask --help

run_test "task update --help exits 0 with Examples" \
    0 "Usage\|Examples" \
    "$CTL" task update --help

echo ""
echo "=== I) Subtask operations ==="

run_test "subtask add positional" \
    0 "" \
    "$CTL" task subtask add "$PD" "$TMPDIR" 1 "test subtask"

run_test "subtask list" \
    0 "test subtask" \
    "$CTL" task subtask list "$PD" "$TMPDIR" 1

run_test "subtask update positional" \
    0 "" \
    "$CTL" task subtask update "$PD" "$TMPDIR" 1 1 done

# --- Summary ---
echo ""
echo "==============================="
echo "Results: $PASS/$TOTAL tests passed"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED: $FAIL test(s)"
    exit 1
fi
echo "ALL PASSED"
