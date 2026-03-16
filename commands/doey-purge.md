# Skill: doey-purge

Purge stale runtime files from old or dead Doey sessions.

## Usage
`/doey-purge`

## Prompt
You are cleaning up stale Doey runtime artifacts under `/tmp/doey/`.

### Steps

1. **Discover current session and list all runtime dirs:**
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)

   # Safe parse — no eval/source on world-writable /tmp
   SESSION_NAME="" PROJECT_NAME=""
   while IFS='=' read -r key value; do
     value="${value%\"}"
     value="${value#\"}"
     case "$key" in
       SESSION_NAME) SESSION_NAME="$value" ;;
       PROJECT_NAME) PROJECT_NAME="$value" ;;
     esac
   done < "${RUNTIME_DIR}/session.env"

   echo "=== Current session ==="
   echo "Session: $SESSION_NAME"
   echo "Runtime: $RUNTIME_DIR"
   echo ""

   echo "=== All runtime dirs under /tmp/doey/ ==="
   ls -la /tmp/doey/ 2>/dev/null || echo "(none)"
   ```

2. **Purge stale files from the CURRENT session** — remove old status, results, reports, messages, and research files while preserving session config and reservations:
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)

   PURGED=0

   # Clear status files (keep .reserved and watchdog_pane_states.json)
   for f in "${RUNTIME_DIR}/status/"*.status "${RUNTIME_DIR}/status/"notif_cooldown_* "${RUNTIME_DIR}/status/"pane_hash_*; do
     [ -f "$f" ] || continue
     rm -f "$f"
     PURGED=$((PURGED + 1))
   done

   # Clear data directories (results, reports, broadcasts, research)
   for subdir in results reports broadcasts research; do
     for f in "${RUNTIME_DIR}/${subdir}/"*; do
       [ -f "$f" ] || continue
       rm -f "$f"
       PURGED=$((PURGED + 1))
     done
   done

   # Clear messages (files and delivered/ subdirectory)
   for f in "${RUNTIME_DIR}/messages/"*; do
     if [ -d "$f" ]; then
       rm -rf "$f"
     elif [ -f "$f" ]; then
       rm -f "$f"
     else
       continue
     fi
     PURGED=$((PURGED + 1))
   done

   echo "Purged $PURGED stale files from current session"

   # Report preserved files
   echo ""
   echo "=== Preserved ==="
   [ -f "${RUNTIME_DIR}/session.env" ] && echo "  session.env"
   for f in "${RUNTIME_DIR}/"worker-system-prompt*.md; do
     [ -f "$f" ] && echo "  $(basename "$f")"
   done
   for f in "${RUNTIME_DIR}/status/"*.reserved; do
     [ -f "$f" ] && echo "  status/$(basename "$f")"
   done
   ```

3. **Detect orphaned session dirs** — runtime dirs under `/tmp/doey/` with no matching live tmux session:
   ```bash
   RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
   CURRENT_PROJECT=$(basename "$RUNTIME_DIR")

   echo "=== Orphan check ==="
   ORPHANS=""
   for dir in /tmp/doey/*/; do
     [ -d "$dir" ] || continue
     PROJECT_NAME=$(basename "$dir")
     [ "$PROJECT_NAME" = "$CURRENT_PROJECT" ] && continue
     SESSION="doey-${PROJECT_NAME}"
     if ! tmux has-session -t "$SESSION" 2>/dev/null; then
       ORPHANS="${ORPHANS} ${PROJECT_NAME}"
       echo "  ORPHANED: $dir (no tmux session '$SESSION')"
     else
       echo "  ACTIVE:   $dir"
     fi
   done

   if [ -z "$ORPHANS" ]; then
     echo "  No orphaned runtime dirs found"
   fi
   ```

4. **If orphans were found**, list them and **ask the user for confirmation** before removing. Only remove after explicit approval:
   ```bash
   # For each confirmed orphan:
   rm -rf "/tmp/doey/${ORPHAN_NAME}"
   echo "Removed /tmp/doey/${ORPHAN_NAME}"
   ```

5. **Final report** — summarize what was cleaned and what was preserved.

### Rules
- **NEVER delete `session.env`** or `worker-system-prompt*.md` for the current session
- **NEVER delete `.reserved` files** — those are permanent pane reservations
- **ALWAYS ask before deleting orphaned session dirs** — the user must confirm
- All bash code must be bash 3.2 compatible
- Use `RUNTIME_DIR` from tmux env — never hardcode paths
