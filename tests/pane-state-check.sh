#!/bin/bash
set -euo pipefail

# Pane state reporting script
# Reads watchdog pane state JSON files and prints a summary table.

STATE_DIR="/tmp/doey/claude-code-tmux-team/status"
PATTERN="watchdog_pane_states_W*.json"

file_count=0
file_list=""
for f in "$STATE_DIR"/$PATTERN; do
  if [ -f "$f" ]; then
    file_count=$((file_count + 1))
    file_list="${file_list} ${f}"
  fi
done

if [ "$file_count" -eq 0 ]; then
  echo "No pane state files found in $STATE_DIR"
  exit 0
fi

printf "%-8s %-6s %-30s %-12s\n" "Window" "Pane" "Title" "State"
printf "%-8s %-6s %-30s %-12s\n" "------" "----" "-----" "-----"

python3 -c "
import json, sys, os, re

files = sys.argv[1:]
total = 0
busy = 0
idle = 0
other = 0
rows = []

for fpath in files:
    # Extract window ID from filename: watchdog_pane_states_W1.json -> W1
    base = os.path.basename(fpath)
    m = re.search(r'_W(\d+)\.json', base)
    window = 'W' + m.group(1) if m else '?'
    with open(fpath) as f:
        data = json.load(f)
    # Actual format: {\"pane_index\": \"STATE\", ...} e.g. {\"1\": \"UNCHANGED\"}
    if isinstance(data, dict):
        for pane_idx, state in sorted(data.items(), key=lambda x: int(x[0]) if x[0].isdigit() else 0):
            rows.append((window, pane_idx, '-', state))
            total += 1
            sl = state.lower()
            if sl in ('busy', 'working'):
                busy += 1
            elif sl in ('idle', 'ready', 'finished', 'unchanged'):
                idle += 1
            else:
                other += 1

for window, pane, title, state in rows:
    print('%-8s %-6s %-30s %-12s' % (window, pane, title, state))

print()
print('%d workers total: %d busy, %d idle, %d other' % (total, busy, idle, other))
" $file_list
