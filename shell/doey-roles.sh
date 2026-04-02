#!/usr/bin/env bash
# doey-roles.sh — Centralized role definitions
# Rename any role = edit this file only. All shell scripts source this.
set -euo pipefail

# Display names (user-facing strings)
DOEY_ROLE_COORDINATOR="Taskmaster"
DOEY_ROLE_TEAM_LEAD="Subtaskmaster"
DOEY_ROLE_BOSS="Boss"
DOEY_ROLE_WORKER="Worker"
DOEY_ROLE_FREELANCER="Freelancer"
DOEY_ROLE_INFO_PANEL="Info Panel"
DOEY_ROLE_TEST_DRIVER="Test Driver"

# Internal IDs (stable, never change — used in status files, env vars, logic)
DOEY_ROLE_ID_COORDINATOR="coordinator"
DOEY_ROLE_ID_TEAM_LEAD="team_lead"
DOEY_ROLE_ID_BOSS="boss"
DOEY_ROLE_ID_WORKER="worker"
DOEY_ROLE_ID_FREELANCER="freelancer"
DOEY_ROLE_ID_INFO_PANEL="info_panel"
DOEY_ROLE_ID_TEST_DRIVER="test_driver"

# File naming patterns (for agent files, skill dirs, hook files)
DOEY_ROLE_FILE_COORDINATOR="doey-taskmaster"
DOEY_ROLE_FILE_TEAM_LEAD="doey-subtaskmaster"
DOEY_ROLE_FILE_BOSS="doey-boss"
DOEY_ROLE_FILE_WORKER="doey-worker"
DOEY_ROLE_FILE_FREELANCER="doey-freelancer"

# Export all for subshells
export DOEY_ROLE_COORDINATOR DOEY_ROLE_TEAM_LEAD DOEY_ROLE_BOSS DOEY_ROLE_WORKER DOEY_ROLE_FREELANCER DOEY_ROLE_INFO_PANEL DOEY_ROLE_TEST_DRIVER
export DOEY_ROLE_ID_COORDINATOR DOEY_ROLE_ID_TEAM_LEAD DOEY_ROLE_ID_BOSS DOEY_ROLE_ID_WORKER DOEY_ROLE_ID_FREELANCER DOEY_ROLE_ID_INFO_PANEL DOEY_ROLE_ID_TEST_DRIVER
export DOEY_ROLE_FILE_COORDINATOR DOEY_ROLE_FILE_TEAM_LEAD DOEY_ROLE_FILE_BOSS DOEY_ROLE_FILE_WORKER DOEY_ROLE_FILE_FREELANCER
