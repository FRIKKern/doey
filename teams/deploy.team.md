---
name: deploy
description: "Deployment pipeline — Review, Changelog, Commit, Deploy in sequence"
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | doey-manager | Deploy Lead | opus |
| 1 | reviewer | - | Reviewer | opus |
| 2 | changelog | - | Changelog | opus |
| 3 | committer | doey-git-agent | Committer | opus |
| 4 | deployer | - | Deployer | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | reviewer | manager | review_complete |
| stop | changelog | manager | changelog_ready |
| stop | committer | manager | commit_done |
| stop | deployer | manager | deploy_complete |

## Team Briefing

Deployment pipeline team. The Deploy Lead coordinates 4 specialists in sequence:

1. **Reviewer** — Reviews all staged/unstaged changes for correctness, style, and safety. Produces a review summary
2. **Changelog** — Generates changelog entries from the diff. Updates CHANGELOG.md or equivalent
3. **Committer** — Stages and commits changes with proper conventional commit messages. Uses the Git Agent role
4. **Deployer** — Handles deployment steps: tagging, pushing, release creation, or whatever the project requires

Typical flow: Review → Changelog → Commit → Deploy. The Lead may run steps in parallel where safe (e.g., Review + Changelog simultaneously).
