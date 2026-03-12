# Skill: doey-reinstall

Reinstall the Doey system from the source repo.

## Usage
`/doey-reinstall`

## Prompt
Reinstall Doey by pulling latest changes and re-running the installer.

### Steps

1. **Find repo:**
   ```bash
   REPO_DIR=$(cat ~/.claude/doey/repo-path 2>/dev/null)
   ```
   If missing: tell user to run `./install.sh` from repo first. Stop.

2. **Pull latest:**
   ```bash
   cd "$REPO_DIR" && git pull
   ```
   If git pull fails (uncommitted changes), warn but continue.

3. **Run installer:**
   ```bash
   bash "$REPO_DIR/install.sh"
   ```

4. **Report:** "Reinstall complete. New sessions use updated files. Running sessions need: `doey stop && doey`"
