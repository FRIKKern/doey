#!/bin/bash
set -euo pipefail

# Print summary table of watchdog pane state JSON files.

STATE_DIR="/tmp/doey/claude-code-tmux-team/status"

file_list=""
for f in "$STATE_DIR"/watchdog_pane_states_W*.json; do
  [ -f "$f" ] && file_list="${file_list} ${f}"
done

if [ -z "$file_list" ]; then
  echo "No pane state files found in $STATE_DIR"
  exit 0
fi

printf "%-8s %-6s %-12s\n" "Window" "Pane" "State"
printf "%-8s %-6s %-12s\n" "------" "----" "-----"

python3 -c "
import json, sys, os, re

total = busy = idle = other = 0
rows = []
for fpath in sys.argv[1:]:
    m = re.search(r'_W(\d+)\.json', os.path.basename(fpath))
    window = 'W' + m.group(1) if m else '?'
    with open(fpath) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        continue
    for idx, state in sorted(data.items(), key=lambda x: int(x[0]) if x[0].isdigit() else 0):
        rows.append((window, idx, state))
        total += 1
        sl = state.lower()
        if sl in ('busy', 'working'):
            busy += 1
        elif sl in ('idle', 'ready', 'finished', 'unchanged'):
            idle += 1
        else:
            other += 1

for window, pane, state in rows:
    print('%-8s %-6s %-12s' % (window, pane, state))
print()
print('%d workers: %d busy, %d idle, %d other' % (total, busy, idle, other))
" $file_list
