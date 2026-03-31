# Task 69 — Consolidated Research Report: Charmbracelet Luxury Upgrade

**Sources:** W2.1 (doey.sh audit), W2.2 (secondary scripts), W2.3 (charmbracelet inventory), W2.4 (dependency strategy)

---

## Section 1: Current State Summary

### Scope
Doey's CLI surface spans **17 shell scripts** totaling ~9,000+ lines. The primary file `shell/doey.sh` (5101 lines) accounts for ~75% of all user-facing interactions.

### Interaction Totals (all scripts combined)

| Type | doey.sh | Secondary | Total |
|------|---------|-----------|-------|
| OUTPUT (display) | ~180 | ~120 | ~300 |
| ERROR | ~55 | ~25 | ~80 |
| PROGRESS | ~20 | ~25 | ~45 |
| PROMPT (input) | ~15 | 3 | ~18 |
| CONFIRM (y/N) | ~10 | 0 | ~10 |
| MENU (selection) | 2 | 1 | 3 |
| BANNER (ASCII art) | 2 | 2 | 4 |

### Current Styling Approach
- **6 ANSI color constants** used across doey.sh: `BRAND` (bold cyan), `SUCCESS` (green), `DIM` (gray), `WARN` (yellow), `ERROR` (red), `BOLD`
- **3 incompatible naming conventions**: `BRAND/SUCCESS/...` (doey.sh, install.sh), `C_DIM/C_CYAN/...` (info-panel.sh, settings-panel.sh), `PASS/FAIL/...` (pre-push-gate.sh)
- **Manual box-drawing** throughout (`┌─┐│└─┘`, `═══`, `───`)
- **All `read -r` / `read -rp`** for input — no validation, no styling, no fuzzy filtering
- **Step counters** via `printf "[N/M] label..."` + `"done"` — functional but not animated
- **Two ASCII art banners** (dog + DOEY block letters) rendered via heredoc

### Key Pain Points
1. Prompts are bare `read -rp` — no placeholders, no fuzzy search, no visual affordance
2. Project picker is a numbered list with manual index entry — no filtering or scroll
3. Progress indicators are static text, not animated spinners
4. Tables use manual printf column alignment — fragile, no dynamic sizing
5. Error messages are just colored printf — no structured formatting, no borders
6. Three different color constant systems create maintenance burden

---

## Section 2: Charmbracelet Tool Mapping

**gum is the only must-have.** It wraps the entire Charmbracelet ecosystem into one bash-friendly binary.

| gum Subcommand | Replaces | Doey Feature |
|----------------|----------|-------------|
| `gum confirm` | `read -rp "... (y/N) "` | Stop/kill/uninstall/purge confirms (~10 instances) |
| `gum choose` | Numbered `read -rp "  > "` menus | Project picker, stop session picker, team selection |
| `gum filter` | n/a (new capability) | Fuzzy search across projects, tasks, team defs |
| `gum input` | `read -r reply` | Text input for API tokens, project names, descriptions |
| `gum spin` | `step_start`/`step_done` printf | All 6-7 launch steps, update, reload, purge scan |
| `gum style` | Manual `printf` with ANSI + box-drawing | Section headers, banners, info boxes, error boxes |
| `gum table` | `printf "%-20s %-10s"` columns | Task list, team windows, remote servers, doctor checks, purge summary |
| `gum format` | `cat << 'HELP'` heredocs | Help text, version info (markdown rendering) |
| `gum log` | `printf "  ${SUCCESS}✓${RESET} %s"` | Doctor checks, reload status lines, structured log output |
| `gum join` | n/a (new capability) | Side-by-side info layout (version + status) |

**Secondary tool: glow** (optional) — renders markdown for `doey help`, task descriptions. Lower priority.

---

## Section 3: OPPORTUNITY MAP

### Banners & Branding

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| Startup banner (dog + DOEY) | Heredoc ASCII art, `$BRAND` cyan | `gum style --border double --align center --padding "1 4" --foreground 212` wrapping existing art | Keep current heredoc + ANSI | P2 | Low — already looks good |
| Section headers ("Doey — Projects") | `printf "  ${BRAND}...${RESET}"` | `gum style --foreground 212 --bold` | Keep current printf | P2 | Low |
| Tagline | `printf "${DIM}tagline${RESET}"` | `gum style --faint --italic` | Keep current printf | P3 | Minimal |

### Startup & Launch

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| Startup wizard | `doey-tui setup` (Go TUI) or skip | `gum choose` for team type + `gum input` for worker count | Keep doey-tui or skip wizard | P1 | High — first-run experience |
| Launch steps [1/6]-[6/6] | `step_start`/`step_done` printf | `gum spin --spinner dot --title "Step..."` per step | Keep current step_start/step_done | P0 | High — seen every launch |
| Launch summary | Multi-line printf table | `gum style --border rounded` wrapping key-value lines | Keep current printf | P1 | Medium |
| Project type detection | `printf "Detected: Go project"` | `gum log --level info "Detected" type Go` | Keep current printf | P3 | Minimal |

### Doctor & System Checks

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| Doctor header | printf brand | `gum style --bold --foreground 212 "System Check"` | Keep current | P2 | Low |
| Check lines (✓/⚠/✗) | `_doc_check()` → printf per line | `gum log --level info/warn/error` for each check | Keep current _doc_check | P1 | Medium — feels professional |
| Doctor table | Individual printf lines | `gum table` with Component/Status/Detail columns | Keep current printf lines | P1 | Medium |
| Install hints | Inline printf suggestions | `gum style --border normal --foreground 3` hint box | Keep current printf | P2 | Low |

### Prompts & Confirmations

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| y/N confirmations (~10) | `read -rp "...? (y/N) "` | `gum confirm "..."` | Keep current read | P0 | High — every destructive op |
| Free-text input (~5) | `read -r reply` | `gum input --prompt "..." --placeholder "..."` | Keep current read | P1 | Medium |
| Secret input (API token) | `read -rs token` | `gum input --password --prompt "API Token: "` | Keep current read -rs | P1 | Medium |
| Claude install offer | `read -r reply </dev/tty` | `gum confirm "Install Claude Code?"` | Keep current read | P1 | Medium |

### Menus & Selection

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| Project picker (`show_menu`) | Numbered list + `read "  > "` | `gum choose` with project names + status indicators | Keep current numbered list | P0 | High — primary entry point |
| Stop session picker | Numbered list + `read` | `gum choose` from running sessions | Keep current numbered list | P1 | Medium |
| Team def listing | printf list | `gum choose` or `gum filter` for team selection | Keep current printf | P2 | Low |

### Progress & Spinners

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| Launch steps (6-7 steps) | `[N/M] label... done` | `gum spin --spinner dot --title "label"` per step | Keep current step printf | P0 | High — every session launch |
| Worker boot progress | `\r` overwrite counter | `gum spin --spinner pulse --title "Booting N workers"` | Keep current \r counter | P1 | Medium |
| Update/clone progress | Static "Cloning..." | `gum spin --spinner globe --title "Cloning..."` | Keep current printf | P1 | Medium |
| Purge scan steps | step_start/step_done | `gum spin --spinner dot --title "Scanning..."` | Keep current step_start | P2 | Low |
| install.sh [1/7]-[7/7] | printf step counter | `gum spin` per install step | Keep current printf | P1 | Medium — first-time experience |

### Error Formatting

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| Fatal errors (~55 in doey.sh) | `printf "${ERROR}✗ msg${RESET}"` | `gum log --level fatal "msg"` or `gum style --foreground 1 --border normal` | Keep current printf | P1 | Medium |
| Usage errors | Plain printf | `gum format` with markdown code block | Keep current printf | P2 | Low |
| Validation errors | Plain printf | `gum log --level error` | Keep current printf | P2 | Low |

### Status & Tables

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| Task list | printf with color-coded status | `gum table --widths 8,20,30,10` | Keep current printf | P1 | Medium |
| Task show (detail) | Multi-line printf key-value | `gum style --border rounded` + formatted content | Keep current printf | P2 | Low |
| Team windows list | printf columns | `gum table` | Keep current printf | P2 | Low |
| Remote servers list | printf columns | `gum table` | Keep current printf | P2 | Low |
| Purge summary | Manual table with box-drawing | `gum table` | Keep current manual table | P2 | Low |
| Version display | Multi-line printf | `gum style --border rounded` info box | Keep current printf | P3 | Minimal |
| Config show | Multi-line printf | `gum table` for current values | Keep current printf | P3 | Minimal |

### Help Text

| Category | Current | Proposed (gum) | Fallback (no gum) | Pri | Impact |
|----------|---------|----------------|---------------------|-----|--------|
| `--help` output | `cat << 'HELP'` heredoc | `gum format` (markdown rendering) or pipe to `gum pager` | Keep current heredoc | P2 | Low |
| Purge usage | `cat << 'PURGE_HELP'` | `gum format` | Keep current heredoc | P3 | Minimal |
| Deploy usage | inline printf | `gum format` | Keep current printf | P3 | Minimal |

---

## Section 4: Dependency & Install Strategy

### Decision: Optional dependency with auto-install offer

**Tier:** Same as jq — optional, user opt-in, silent fallback.

| Aspect | Decision |
|--------|----------|
| Required or optional? | **Optional** — same tier as jq |
| Install method | Direct binary download (~4.5 MB) to `~/.local/bin/gum`, brew fallback |
| Version pinning | Pin to `0.17.0`, update manually when tested |
| What if missing? | Silent `HAS_GUM=false` detection, fallback to current `read`/`printf`/ANSI |
| Cross-platform | macOS (arm64, x86_64), Linux (x86_64, arm64) |
| Binary location | `~/.local/bin/gum` (same PATH as doey itself) |
| Doctor integration | `_doc_check skip "gum not installed" "using plain text fallback"` |

### Fallback Pattern (doey-ui.sh library)

```
shell/doey-ui.sh:
  HAS_GUM detection at source time
  doey_confirm()  → gum confirm || read -rp
  doey_choose()   → gum choose  || numbered list + read
  doey_input()    → gum input   || read -r
  doey_spin()     → gum spin    || printf "..." + command + "done"
  doey_header()   → gum style   || printf with ANSI
  doey_table()    → gum table   || printf columns
  doey_error()    → gum log     || printf with $ERROR
```

Key constraints: bash 3.2 compatible, identical return values from both paths, no "gum not found" warnings.

### Fresh Install Test
gum fits cleanly: single static binary → `~/.local/bin/` → no runtime deps → no config files → same pattern as doey-tui.

---

## Section 5: Prioritized Implementation Plan

### Phase 1: Foundation (doey-ui.sh wrapper library)
**Priority:** P0 — must ship first, everything depends on it
**Complexity:** Low (one new file, ~120 lines)

| Task | Files | Notes |
|------|-------|-------|
| Create `shell/doey-ui.sh` with HAS_GUM detection | New file | `command -v gum` check |
| Implement wrapper functions | `shell/doey-ui.sh` | `doey_confirm`, `doey_choose`, `doey_input`, `doey_spin`, `doey_header`, `doey_table`, `doey_error` |
| Source from doey.sh | `shell/doey.sh` | Add `source "${SCRIPT_DIR}/doey-ui.sh"` near top |
| Add gum install to install.sh | `install.sh` | `_install_gum()` with binary download, `ask_install` opt-in |
| Add gum to doctor | `shell/doey.sh` | `_doc_check` entry in `check_doctor()` |
| Unify color constants | `shell/doey-ui.sh` | Single canonical set: `BRAND`, `SUCCESS`, `DIM`, `WARN`, `ERROR`, `BOLD`, `RESET` |

### Phase 2: High-Impact Upgrades
**Priority:** P0-P1 — biggest user-visible improvements
**Complexity:** Medium (swap ~40 call sites)
**Depends on:** Phase 1

| Task | Files | gum Feature | Instances |
|------|-------|-------------|-----------|
| Replace confirmations with `doey_confirm()` | `shell/doey.sh` | `gum confirm` | ~10 `read -rp "...? (y/N)"` |
| Replace project picker with `doey_choose()` | `shell/doey.sh` (`show_menu`) | `gum choose` | 1 (but high-traffic) |
| Replace stop picker with `doey_choose()` | `shell/doey.sh` (`stop_project`) | `gum choose` | 1 |
| Replace launch steps with `doey_spin()` | `shell/doey.sh` (`_launch_session_core`, `launch_session_dynamic`) | `gum spin` | ~12 step_start/step_done pairs |
| Replace install.sh prompts | `install.sh` | `doey_confirm`, `doey_spin` | ~5 ask_install + 7 step blocks |
| Upgrade doctor output | `shell/doey.sh` (`check_doctor`) | `gum log` or `gum table` | ~12 _doc_check calls |

### Phase 3: Medium-Impact Polish
**Priority:** P1-P2
**Complexity:** Medium
**Depends on:** Phase 1

| Task | Files | gum Feature | Instances |
|------|-------|-------------|-----------|
| Upgrade error messages to `doey_error()` | `shell/doey.sh` | `gum log --level error` | ~55 error printfs |
| Upgrade task list to `doey_table()` | `shell/doey.sh` (`task_command`) | `gum table` | 1 |
| Upgrade team windows list | `shell/doey.sh` (`list_team_windows`) | `gum table` | 1 |
| Upgrade remote servers list | `shell/doey.sh` (`doey_remote` list) | `gum table` | 1 |
| Upgrade update/reload spinners | `shell/doey.sh` | `gum spin` | ~5 progress sites |
| Upgrade purge summary | `shell/doey.sh` (`_purge_summary`) | `gum table` | 1 |
| Upgrade help text | `shell/doey.sh` (`--help`) | `gum format` or `gum pager` | 3 heredoc help blocks |
| Source doey-ui.sh from install.sh | `install.sh` | Reuse wrappers | ~10 sites |

### Phase 4: Low-Priority Polish
**Priority:** P2-P3
**Complexity:** Low
**Depends on:** Phase 1

| Task | Files | gum Feature | Notes |
|------|-------|-------------|-------|
| Styled launch summary box | `shell/doey.sh` | `gum style --border rounded` | Post-launch info box |
| Styled version display | `shell/doey.sh` | `gum style --border rounded` | Version info box |
| Styled config show | `shell/doey.sh` | `gum table` | Config values display |
| pre-push-gate.sh results | `shell/pre-push-gate.sh` | `gum table` | Check results table |
| context-audit.sh output | `shell/context-audit.sh` | `gum log` | Audit issue lines |

### Out of Scope (keep as-is)
- **info-panel.sh / settings-panel.sh** — Full TUI apps, already have doey-tui Go replacement path
- **tmux-statusbar.sh / pane-border-status.sh** — Output consumed by tmux, not terminals
- **doey-tunnel.sh / doey-remote-provision.sh** — Log/remote contexts, not interactive
- **doey-statusline.sh** — Single-line status, tmux-consumed
- **ASCII art banners** — Already look good, low ROI to change

---

## Estimated Total Effort

| Phase | New/Changed Lines | Call Sites Modified | Risk |
|-------|-------------------|---------------------|------|
| Phase 1 | ~150 new (doey-ui.sh) + ~30 (install.sh) + ~5 (doey.sh source line) | 0 (additive only) | Low |
| Phase 2 | ~80 changed | ~40 | Medium — touches core launch path |
| Phase 3 | ~120 changed | ~65 | Low — non-critical paths |
| Phase 4 | ~40 changed | ~10 | Minimal |

**Total:** ~400 lines changed/added across 4 files, ~115 call sites upgraded.
