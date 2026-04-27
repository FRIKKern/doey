# Makefile — Doey developer entry points.
#
# Phase 9 close (masterplan-20260426-203854): wires the plan-view
# render-golden harness into a CI-blocking smoke gate plus an opt-in
# matrix sweep, with a discoverable refresh path for intentional
# golden updates.

REPO_DIR    := $(shell pwd)
TUI_DIR     := $(REPO_DIR)/tui
GO          ?= go

# Smoke gate: the single Phase 5 golden — fixture=consensus, width=120,
# profile=truecolor, GOOS=linux. Any other (fixture,width,profile,os)
# tuple skips inside the Go test, so the entire matrix collapses to one
# byte-compare on Linux CI.
SMOKE_RUN   := -run '^TestGoldenConsensus120Truecolor$$'

# Full plan-view golden suite (consensus, header pill, reviewer cards).
# Phase 9 keeps these inside the same -run filter; new fixtures added
# in future phases will be picked up automatically.
MATRIX_RUN  := -run '^TestGolden'

.PHONY: help smoke-render-golden test-render-matrix refresh-render-goldens \
        test-bash-compat test-plan-pane-contract test-fresh-install \
        test-tmux-passthrough

help:
	@echo "Doey — common targets"
	@echo "  smoke-render-golden    Phase 5 plan-view golden (CI-blocking)"
	@echo "  test-render-matrix     opt-in: full plan-view golden matrix"
	@echo "  refresh-render-goldens regenerate goldens (intentional updates only)"
	@echo "  test-bash-compat       bash 3.2 compatibility lint"
	@echo "  test-plan-pane-contract validator sweep over fixtures"
	@echo "  test-fresh-install     fresh-install validation (set DOEY_FRESH_INSTALL_TEST_DESTRUCTIVE=1 for full sweep)"
	@echo "  test-tmux-passthrough  detached tmux smoke for doey-masterplan-tui"

# ── plan-view render goldens ──────────────────────────────────────────

smoke-render-golden:
	@echo ">>> running plan-view smoke golden (consensus,120,truecolor,linux)"
	@cd $(TUI_DIR) && \
	  if ! $(GO) test ./internal/planview/ $(SMOKE_RUN) -count=1; then \
	    echo ""; \
	    echo ">>> FAIL: golden mismatch. If intentional, run: make refresh-render-goldens"; \
	    exit 1; \
	  fi
	@echo ">>> OK: smoke golden matches"

test-render-matrix:
	@echo ">>> running plan-view golden matrix (opt-in)"
	@cd $(TUI_DIR) && \
	  RENDER_FIXTURE=$${RENDER_FIXTURE:-all} \
	  RENDER_WIDTH=$${RENDER_WIDTH:-all} \
	  RENDER_PROFILE=$${RENDER_PROFILE:-all} \
	  $(GO) test ./internal/planview/ $(MATRIX_RUN) -count=1
	@if [ "$$(uname -s)" = "Darwin" ]; then \
	  echo ">>> Darwin host detected — macOS goldens would run here once Phase 9 fans out the matrix."; \
	fi

refresh-render-goldens:
	@echo ">>> rewriting plan-view goldens (intentional updates only)"
	@cd $(TUI_DIR) && $(GO) test ./internal/planview/ $(MATRIX_RUN) -update -count=1
	@echo ">>> OK: goldens regenerated. Review the diff before committing."

# ── shell tests ───────────────────────────────────────────────────────

test-bash-compat:
	@bash $(REPO_DIR)/tests/test-bash-compat.sh

test-plan-pane-contract:
	@bash $(REPO_DIR)/tests/test-plan-pane-contract.sh

test-fresh-install:
	@bash $(REPO_DIR)/tests/test-fresh-install.sh

test-tmux-passthrough:
	@bash $(REPO_DIR)/tests/test-tmux-passthrough.sh
