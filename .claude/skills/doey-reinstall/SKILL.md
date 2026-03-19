---
name: doey-reinstall
description: Reinstall Doey from source repo
---

```bash
REPO_DIR=$(cat ~/.claude/doey/repo-path 2>/dev/null)
if [ -z "$REPO_DIR" ]; then echo "ERROR: Run ./install.sh from repo first"; exit 1; fi
cd "$REPO_DIR" && git pull; bash "$REPO_DIR/install.sh"
```

If git pull fails (uncommitted changes), warn but continue with install.
Report: "Reinstall complete. Running sessions need: `doey stop && doey`"
