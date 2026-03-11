# Skill: doey-reinstall

Reinstall the Doey system from the source repo to pick up any changes.

## Usage
`/doey-reinstall`

## Prompt
You need to reinstall the Doey system. This pulls the latest changes from git and re-runs the installer to update all agent definitions, slash commands, and the CLI script.

### Steps

1. Find the source repo location:
   ```bash
   REPO_DIR=$(cat ~/.claude/doey/repo-path 2>/dev/null)
   ```

2. If the file is missing or the directory doesn't exist, tell the user:
   - "Could not find the claude-code-tmux-team repo. Run `./install.sh` from the repo once to register its location."
   - Stop here.

3. Pull latest changes:
   ```bash
   cd "$REPO_DIR" && git pull
   ```
   If git pull fails (e.g., uncommitted changes), warn the user but continue with the install anyway — they may have local modifications they want to deploy.

4. Run the installer:
   ```bash
   bash "$REPO_DIR/install.sh"
   ```

5. After successful install, tell the user:
   - "Reinstall complete. New sessions will use the updated files."
   - "Running sessions need a restart: `doey stop && doey`"
