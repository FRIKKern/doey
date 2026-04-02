---
name: doey-reset
description: Factory reset Doey — restore default settings, reset config and agents. Use when you need to "factory reset doey", "restore defaults", "reset config and agents", "reset doey to defaults", or "reset doey settings".
---

Reset Doey to factory defaults: regenerate templates, reinstall agents, and restore default config.

**Important:** This does NOT touch tasks (`.doey/tasks/`), plans, runtime state (`/tmp/doey/`), or git state.

## Steps

### 1. Resolve project directory

```bash
set -euo pipefail
PROJECT_DIR="${DOEY_PROJECT_DIR:-$(cat ~/.claude/doey/repo-path 2>/dev/null || true)}"
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: Cannot find Doey repo. Run ./install.sh from repo first."
  exit 1
fi
echo "Project: $PROJECT_DIR"
```

### 2. Regenerate templates from .md.tmpl sources

```bash
set -euo pipefail
PROJECT_DIR="${DOEY_PROJECT_DIR:-$(cat ~/.claude/doey/repo-path 2>/dev/null)}"
bash "$PROJECT_DIR/shell/expand-templates.sh"
```

### 3. Reinstall agent definitions

```bash
set -euo pipefail
PROJECT_DIR="${DOEY_PROJECT_DIR:-$(cat ~/.claude/doey/repo-path 2>/dev/null)}"
mkdir -p ~/.claude/agents
AGENT_COUNT=0
for f in "$PROJECT_DIR"/agents/*.md; do
  [ -f "$f" ] || continue
  cp "$f" ~/.claude/agents/
  AGENT_COUNT=$((AGENT_COUNT + 1))
done
echo "Installed $AGENT_COUNT agent(s) to ~/.claude/agents/"
```

### 4. Reset project config to defaults

```bash
set -euo pipefail
PROJECT_DIR="${DOEY_PROJECT_DIR:-$(cat ~/.claude/doey/repo-path 2>/dev/null)}"
mkdir -p "$PROJECT_DIR/.doey"
cp "$PROJECT_DIR/shell/doey-config-default.sh" "$PROJECT_DIR/.doey/config.sh"
echo "Reset config: $PROJECT_DIR/.doey/config.sh"
```

### 5. Report results

Summarize what was reset:
- Templates regenerated (count from step 2 output)
- Agents reinstalled (count from step 3)
- Config restored to defaults (path from step 4)

Tell the user: "Factory reset complete. Running sessions need `doey stop && doey` to pick up changes."
