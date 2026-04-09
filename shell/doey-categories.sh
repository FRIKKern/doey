#!/usr/bin/env bash
# doey-categories.sh — Task category definitions with model mappings
# Source of truth for task classification categories.
# Sourced by common.sh; used in expand-templates.sh and agent templates.

set -euo pipefail

# Category definitions: DOEY_CATEGORY_<NAME>="display_name"
# Model mappings: DOEY_CATEGORY_MODEL_<NAME>="model_name"
# Descriptions: DOEY_CATEGORY_DESC_<NAME>="description"

# Quick: single-file changes, typos, small fixes
export DOEY_CATEGORY_QUICK="quick"
export DOEY_CATEGORY_MODEL_QUICK="sonnet"
export DOEY_CATEGORY_DESC_QUICK="Single-file changes, typos, small fixes"

# Deep: multi-file architecture, research, complex refactoring
export DOEY_CATEGORY_DEEP="deep"
export DOEY_CATEGORY_MODEL_DEEP="opus"
export DOEY_CATEGORY_DESC_DEEP="Multi-file architecture, research, complex refactoring"

# Visual: UI/frontend work
export DOEY_CATEGORY_VISUAL="visual"
export DOEY_CATEGORY_MODEL_VISUAL="opus"
export DOEY_CATEGORY_DESC_VISUAL="UI/frontend work"

# Infrastructure: CI/CD, config, build tooling
export DOEY_CATEGORY_INFRA="infrastructure"
export DOEY_CATEGORY_MODEL_INFRA="sonnet"
export DOEY_CATEGORY_DESC_INFRA="CI/CD, config, build tooling"

# All categories (space-separated for iteration)
export DOEY_CATEGORIES="QUICK DEEP VISUAL INFRA"

# Lookup function: get model for a category
# Usage: doey_category_model "quick" → prints "sonnet"
doey_category_model() {
    local cat_input="${1:-}"
    local cat_upper
    cat_upper=$(printf '%s' "$cat_input" | tr '[:lower:]' '[:upper:]')
    local var_name="DOEY_CATEGORY_MODEL_${cat_upper}"
    eval "printf '%s\n' \"\${${var_name}:-opus}\""
}
export -f doey_category_model
