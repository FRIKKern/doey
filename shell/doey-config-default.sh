#!/usr/bin/env bash
# doey-config-default.sh — Default configuration template for Doey
#
# This file can be used as either:
#   - Global config:  ~/.config/doey/config.sh  (applies to all projects)
#   - Project config: <project>/.doey/config.sh  (overrides global per-project)
#
# Config hierarchy (last wins):
#   1. Hardcoded defaults (in doey.sh)
#   2. Global config (~/.config/doey/config.sh)
#   3. Project config (.doey/config.sh)
#
# Copy to the appropriate location and uncomment what you want to change.
# All variables use the DOEY_ prefix and are commented out by default.
# The values shown are the built-in defaults.

# =============================================================================
# Grid & Teams
# =============================================================================

# Number of worker columns in the initial grid layout (workers = cols × 2)
# DOEY_INITIAL_WORKER_COLS=2

# Number of team windows to create at startup
# DOEY_INITIAL_TEAMS=2

# Number of teams that start in isolated git worktrees
# DOEY_INITIAL_WORKTREE_TEAMS=0

# Number of freelancer teams (no manager, independent workers available to all teams)
# DOEY_INITIAL_FREELANCER_TEAMS=1

# Maximum number of worker panes across all teams
# DOEY_MAX_WORKERS=20

# =============================================================================
# Auth & Launch Timing
# =============================================================================

# Seconds between launching each worker instance (prevents auth rate-limit on startup)
# Lower only if your account has high rate limits and you need faster boots.
# DOEY_WORKER_LAUNCH_DELAY=3

# Seconds between launching each team window
# DOEY_TEAM_LAUNCH_DELAY=15

# Seconds to wait before launching the Window Manager in a new team
# DOEY_MANAGER_LAUNCH_DELAY=3

# Seconds the Window Manager waits after launch before briefing
# DOEY_MANAGER_BRIEF_DELAY=8

# =============================================================================
# Dynamic Grid Behavior
# =============================================================================

# Seconds of idle time before a worker column is collapsed
# DOEY_IDLE_COLLAPSE_AFTER=60

# Seconds of idle time before a worker pane is removed entirely
# DOEY_IDLE_REMOVE_AFTER=300

# Milliseconds to wait after paste for the terminal to settle
# DOEY_PASTE_SETTLE_MS=500

# =============================================================================
# Panel & Monitoring
# =============================================================================

# Seconds between info panel / settings panel refresh cycles
# DOEY_INFO_PANEL_REFRESH=300

# =============================================================================
# Models
# =============================================================================

# Model for Window Manager instances (orchestrator — needs strong reasoning)
# DOEY_MANAGER_MODEL=opus

# Model for Worker instances (task execution)
# DOEY_WORKER_MODEL=opus

# Model for Session Manager (cross-team orchestration)
# DOEY_SESSION_MANAGER_MODEL=opus

# =============================================================================
# Team Definitions (Advanced)
# =============================================================================
#
# Define custom teams with specific configurations. When DOEY_TEAM_COUNT is
# set, it overrides DOEY_INITIAL_TEAMS and DOEY_INITIAL_WORKTREE_TEAMS.
# If no DOEY_TEAM_* vars are set, default behavior applies.
#
# Format: DOEY_TEAM_<N>_<PROPERTY>=value
#
# Available properties:
#
#   TYPE ............. "local", "worktree", "freelancer", or "premade"
#                      (default: local)
#                      Worktree teams get an isolated git branch.
#                      Freelancer teams have no manager — all panes are
#                      independent workers available to any team.
#                      Premade teams use a .team.md definition file.
#
#   DEF .............. Team definition name (required for premade teams)
#                      Must match a file in ~/.local/share/doey/teams/.
#                      Run `doey teams` to list available definitions.
#
#   WORKERS .......... Number of worker panes (default: from grid calculation)
#                      Each worker runs one Claude instance.
#
#   NAME ............. Human-readable team name (default: "Team <N>")
#                      Shown in settings panel and pane borders.
#
#   ROLE ............. Team specialization hint (default: none)
#                      Injected into worker system prompts. Examples:
#                      "backend", "frontend", "testing", "docs"
#
#   WORKER_MODEL ..... Model for workers in this team (default: DOEY_WORKER_MODEL)
#                      Overrides the global worker model for this team only.
#
#   MANAGER_MODEL .... Model for the manager (default: DOEY_MANAGER_MODEL)
#                      Overrides the global manager model for this team only.
#
# Example — two specialized teams:
#
# DOEY_TEAM_COUNT=2
#
# DOEY_TEAM_1_TYPE=local
# DOEY_TEAM_1_WORKERS=6
# DOEY_TEAM_1_NAME="Backend"
# DOEY_TEAM_1_ROLE=backend
# DOEY_TEAM_1_WORKER_MODEL=opus
# DOEY_TEAM_1_MANAGER_MODEL=opus
#
# DOEY_TEAM_2_TYPE=worktree
# DOEY_TEAM_2_WORKERS=4
# DOEY_TEAM_2_NAME="Frontend"
# DOEY_TEAM_2_ROLE=frontend
# DOEY_TEAM_2_WORKER_MODEL=sonnet
# DOEY_TEAM_2_MANAGER_MODEL=opus
#
# Example — local team + premade visual verification:
#
# DOEY_TEAM_COUNT=2
#
# DOEY_TEAM_1_TYPE=local
# DOEY_TEAM_1_WORKERS=4
#
# DOEY_TEAM_2_TYPE=premade
# DOEY_TEAM_2_DEF=visual
#
# Example — two premade specialist teams:
#
# DOEY_TEAM_COUNT=2
#
# DOEY_TEAM_1_TYPE=premade
# DOEY_TEAM_1_DEF=visual
#
# DOEY_TEAM_2_TYPE=premade
# DOEY_TEAM_2_DEF=seo

# =============================================================================
# Project-Specific Overrides
# =============================================================================
# These settings are most useful in per-project .doey/config.sh files.
# They let you tune team size and timing per-project without affecting
# your global defaults.
#
# Examples:
#   # Minimal team for a simple project
#   DOEY_INITIAL_WORKER_COLS=1
#   DOEY_INITIAL_TEAMS=1
#
#   # Larger team for a monorepo
#   DOEY_INITIAL_WORKER_COLS=3
#   DOEY_INITIAL_TEAMS=4
#   DOEY_INITIAL_WORKTREE_TEAMS=2
#   DOEY_MAX_WORKERS=30
