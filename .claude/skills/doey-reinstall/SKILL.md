---
name: doey-reinstall
description: Reinstall Doey from source repo. Use when you need to "reinstall doey", "update doey from source", or "refresh doey installation".
---

```bash
REPO_DIR=$(cat ~/.claude/doey/repo-path 2>/dev/null)
if [ -z "$REPO_DIR" ]; then echo "ERROR: Run ./install.sh from repo first"; exit 1; fi
cd "$REPO_DIR" && git pull; bash "$REPO_DIR/install.sh"
```

Git pull fail (dirty) → warn, continue. Report: "Reinstall complete. Running sessions: `doey stop && doey`"
