# Enforce AskUserQuestion Hook

## Fresh-install gate (isolated environment only)

To verify zero-config shadow-mode default after a clean install, run in an ISOLATED environment — never on a working dev machine.

**Isolated worktree + HOME override:**
```bash
git worktree add /tmp/doey-fresh-install-test main
cd /tmp/doey-fresh-install-test
HOME=/tmp/doey-fresh-home ./install.sh
HOME=/tmp/doey-fresh-home doey   # in a throwaway project dir
# Send a plain-text question from Boss (pane 0.1)
# Verify: ls $PROJECT/.doey/violations/ask-user-question.jsonl
```

**Forbidden** (will wipe your dev state):
```bash
rm -rf ~/.config/doey ~/.local/bin/doey ~/.claude/agents/doey-*   # DO NOT RUN
```

## Per-project gitignore guidance

Violations live at `$PROJECT/.doey/violations/ask-user-question.jsonl` per project. If you don't want them committed, add `.doey/violations/` to your project's own `.gitignore`. Do not modify Doey's own `.gitignore` — it is a different repo.

*(Remaining sections added in Phase 5.)*
