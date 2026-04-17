# Fresh Install — Agents Missing (Root Cause + Minimal Fix Set)

Research for task 598, subtask 1 — sibling to tasks 596 (trust-prompt) and 597 (systemic fixes).

## 1. Executive summary

Most likely root cause: silent failures in the install→launch chain. Specifically:

1. `install.sh:338-341` runs `shell/expand-templates.sh` with both `>/dev/null 2>&1` AND trailing `|| true`. Any template-expansion failure is invisible AND non-fatal.
2. `install.sh:343` then copies whatever `agents/*.md` files happen to exist — partial or stale. The shape of failure reported by the user ("no agents available") is fully explained if expansion died *on a fresh clone where `.md.tmpl → .md` had never been produced yet* (or where a prior git clean wiped them).
3. The launcher (`shell/doey.sh:689-691`, `_check_prereqs` in `shell/doey-session.sh:1734`) only gates on `tmux` + `claude`. It never verifies that the agent set exists before spawning Claude Code panes with `--agent doey-boss`, `--agent doey-subtaskmaster`, etc. So the session launches into a blank state silently.
4. Compounded by `generate_team_agent` (`shell/doey-team-mgmt.sh:62-74`) which *silently no-ops* when the source agent file is absent — the caller still gets a team-clone name back, and Claude Code is launched with a `--agent` flag pointing at a non-existent file.

Recommended minimal fix set (see §5):

- **Preflight guard** in `shell/doey-session.sh::_check_prereqs()` using the authoritative required set derived from `doey-roles.sh`. Fail loud, prescribe `doey install --agents`.
- **Repair command** `doey install --agents` routed into a new `doey_install_agents()` function that re-runs the agent portion of `install.sh` (expand templates, copy, manifest).
- **Doctor check upgrade** in `shell/doey-doctor.sh:238-246`: replace the single-file probe with an "Agents installed: N/M present" rollup that names missing agents.

## 2. How agent install works today

Trace of `install.sh` agent path, top to bottom:

- **Directory creation** — `install.sh:314-317` creates `~/.claude/agents` (among others).
- **Template expansion** — `install.sh:339-341`:
  ```bash
  if [ -x "$SCRIPT_DIR/shell/expand-templates.sh" ]; then
    bash "$SCRIPT_DIR/shell/expand-templates.sh" >/dev/null 2>&1 || true
  fi
  ```
  Silent failure. `shell/expand-templates.sh` (lines 75-108) iterates `$PROJECT_DIR/agents/*.md.tmpl`, runs a `sed` expression built from every exported `DOEY_ROLE_*` / `DOEY_CATEGORY_*` env var (line 52-59), expands `{{include:name}}` lines via `expand_includes()` (line 13-31, reads `agents/_fragments/`), and writes the output to `*.md`. Requirements:
  - `doey-roles.sh` and `doey-categories.sh` must be sourceable AND must `export` vars (they do — `doey-roles.sh:52-60`).
  - All referenced fragments must resolve (`agents/_fragments/` — unknown fragment → exit 2 at line 21-22).
  - The `sed` value-escape on line 55 uses `sed 's/[&/\]/\\&/g'` — correct for basic role values.
- **Copy** — `install.sh:343`:
  ```bash
  install_md_files "$SCRIPT_DIR/agents" ~/.claude/agents "2/7" "agent definitions"
  ```
  `install_md_files` (lines 36-46):
  - `shopt -s nullglob` + glob `*.md` only (NOT `.md.tmpl`). If expansion failed and no `.md` exist for some agents, they are silently skipped.
  - Hard fail only if `_files[@]` is *entirely empty* (line 41 `die`). A partial agent set is NOT detected.
- **Orphan cleanup** — `install.sh:27-33` only removes `doey-*.md` files not in src. Harmless, no bearing on the bug.
- **Manifest hash** — `install.sh:348`:
  ```bash
  bash -c 'cat ~/.claude/agents/doey-*.md 2>/dev/null' | _compute_hash > ~/.claude/doey/agents.hash
  ```
  Writes a freshness hash. **This hash does not validate completeness** — it only changes when agent *contents* diverge from install-time. A fresh install with 3 agents and a later install with 26 agents both get "matching" hashes if the contents are identical to what was there at install time.

**Observed installed state on dev machine** (for reference): 64 files in `~/.claude/agents/` — 26 `doey-*.md` sources + seo/visual/settings/test-driver + a large set of `tN-*` team clones minted by `generate_team_agent`. Source repo has 77 entries in `/home/doey/doey/agents/` (26 `.md` + 26 `.md.tmpl` + other pairs + `_fragments/`).

## 3. Failure modes

Realistic paths to "no agents / partial agents after `doey`":

| # | Failure mode | Where it strikes | Detection today |
|---|---|---|---|
| F1 | `expand-templates.sh` fails on a fresh clone (missing fragment, missing role var, sed quirk) | `install.sh:340` — errors swallowed by `>/dev/null 2>&1 \|\| true` | None. Install prints `[2/7] Installing agent definitions (N)` with the N at whatever level `.md` happened to exist |
| F2 | Fresh clone where `.md.tmpl` exists but `.md` does NOT (never expanded) | Copy step at `install.sh:343` — copies 0 or partial `.md` | `install_md_files` dies only on *empty* set, not partial |
| F3 | User ran `git clean -fdx` and templates + generated both gone → zero `.md` | `install.sh:41` die fires | Loud, but only for total emptiness |
| F4 | Install completes, then a Claude Code update wipes `~/.claude/agents/` | Out-of-band; speculative but plausible given prior repo references to "Agent freshness" drift | Hash check warns only on diff, not absence |
| F5 | Partial install died between `[2/7]` and `[5/7]` (e.g. network hiccup, disk full) | `install.sh` uses `set -e` at line 3 so `die` exits — but if interrupted, partial state persists | None — next `doey` launch does not re-check |
| F6 | User on an old machine who hasn't rerun install since agents/roles were added (e.g. `doey-masterplanner`, `doey-doey-expert`) | Launcher spawns with `--agent doey-doey-expert`, Claude Code fails silently | `check_agent_freshness` at `doey-update.sh:636-647` warns "Installed agents are out of date — run: doey update" IF `agents.hash` matches neither — but the warning is one line, easy to miss |
| F7 | `generate_team_agent` called for `doey-subtaskmaster` when file missing → creates no `tN-subtaskmaster.md` but still echoes the name back | `doey-team-mgmt.sh:62-74` — the `[ -f "$src" ]` guard is a silent skip | None |
| F8 | User's `~/.claude/agents/` permissions broken (owned by root after a sudo mistake) | `cp` in `install_md_files` fails → `die` fires — loud | Caught at install time |
| F9 | `doey` invoked from non-doey project that was registered *before* agents existed | Uses pre-existing `~/.claude/agents/` directory; ok if install.sh was ever run for this user | — |

F1 + F2 + F4 are the likely culprits for the user report. F6 is the "quiet drift" mode.

## 4. Required agents

Deriving the minimal set that MUST exist in `~/.claude/agents/` for `doey` to launch a session without silent `--agent <missing>` failures.

From `shell/doey-roles.sh` (the single source of truth) — every `DOEY_ROLE_FILE_*` constant maps to an agent file basename:

| Constant | File | Used where |
|---|---|---|
| `DOEY_ROLE_FILE_BOSS` | `doey-boss.md` | `shell/doey-session.sh:143` — spawned in Dashboard window |
| `DOEY_ROLE_FILE_COORDINATOR` | `doey-taskmaster.md` | Core Team spawn (via team def `teams/core.team.md`) |
| `DOEY_ROLE_FILE_TASK_REVIEWER` | `doey-task-reviewer.md` | `shell/doey-session.sh:195` |
| `DOEY_ROLE_FILE_DEPLOYMENT` | `doey-deployment.md` | `shell/doey-session.sh:201` |
| `DOEY_ROLE_FILE_DOEY_EXPERT` | `doey-doey-expert.md` | Core Team 4th pane (via team def) |
| `DOEY_ROLE_FILE_TEAM_LEAD` | `doey-subtaskmaster.md` | `shell/doey-session.sh:962`, `shell/doey-team-mgmt.sh:782,1028` — every worker team window |
| `DOEY_ROLE_FILE_WORKER` | `doey-worker.md` | Workers resolved via team def (`teams/*.team.md`) |
| `DOEY_ROLE_FILE_FREELANCER` | `doey-freelancer.md` | `add_dynamic_team_window` freelancer path |
| `DOEY_ROLE_FILE_PLANNER` | `doey-masterplanner.md` | `doey masterplan` flow — BUT note: **no `doey-masterplanner.md` exists in repo** (see §6 risks). Repo has `doey-planner.md.tmpl`. Role-file constant vs. actual filename divergence. |

Worker team compositions referenced in `teams/*.team.md` (see `shell/doey-team-mgmt.sh:_parse_team_def`) also need:
- `doey-worker-deep.md`, `doey-worker-quick.md`, `doey-worker-research.md` — referenced by default team definitions.
- `doey-critic.md`, `doey-architect.md`, `doey-masterplan-critic.md` — referenced by masterplan/planning teams.

**Canonical minimum required for `doey` to start a Dashboard + Core Team + one Worker Team** (recommended preflight set):

```
doey-boss
doey-taskmaster
doey-task-reviewer
doey-deployment
doey-doey-expert
doey-subtaskmaster
doey-worker
doey-worker-deep
doey-worker-quick
doey-worker-research
doey-freelancer
```

11 files. Anything beyond this can be demoted to a warning.

## 5. Proposed minimal fix set

### 5a. Preflight guard in launcher

**File:** `shell/doey-session.sh`
**Location:** immediately after the `claude` check inside `_check_prereqs()` — after line 1845 (the closing `fi` of the Claude Code block) and before the `if [ "$missing" = true ]` block at line 1847.

**Sketch:**

```bash
  # Preflight: required Doey agents must be installed.
  _doey_preflight_agents() {
    local agents_dir="$HOME/.claude/agents"
    local required=(
      doey-boss
      doey-taskmaster
      doey-task-reviewer
      doey-deployment
      doey-doey-expert
      doey-subtaskmaster
      doey-worker
      doey-worker-deep
      doey-worker-quick
      doey-worker-research
      doey-freelancer
    )
    local missing_agents=""
    local total=0 present=0 a
    for a in "${required[@]}"; do
      total=$((total + 1))
      if [ -f "${agents_dir}/${a}.md" ]; then
        present=$((present + 1))
      else
        missing_agents="${missing_agents:+${missing_agents} }${a}"
      fi
    done
    if [ "$present" -lt "$total" ]; then
      printf '\n'
      doey_error "Doey agents missing (${present}/${total} installed)"
      doey_info "Expected in ~/.claude/agents/. Missing: ${missing_agents}"
      printf '\n'
      printf "  ${BOLD}Fix:${RESET}  ${BRAND}doey install --agents${RESET}  ${DIM}(re-copies agent files only)${RESET}\n"
      printf "        ${DIM}or${RESET}  ${BRAND}doey update${RESET}               ${DIM}(full reinstall)${RESET}\n\n"
      return 1
    fi
    return 0
  }

  if ! _doey_preflight_agents; then
    missing=true
  fi
```

- Exit code: inherits existing `_check_prereqs` contract — sets `missing=true` which exits `1` at line 1849.
- Error message text: as shown above; uses existing `doey_error`/`doey_info` helpers (already in scope — `doey-ui.sh`).
- Bash 3.2: uses `missing_agents` as a string (no `declare -A` / `-n`), array append OK.

### 5b. Repair command

**File to create:** none (reuse flow in `install.sh`). Add handler in `shell/doey.sh`.

**Subcommand spec:** `doey install [--agents]`

- `doey install` alone → alias to `doey update` (exists today).
- `doey install --agents` → copy-only repair. Idempotent. No config, no hooks, no CLI binaries, no skills touched.

**File:** `shell/doey.sh`
**Location:** insert a new `install)` case adjacent to the `update|reinstall)` case around line 270.

**Sketch:**

```bash
  install)
    shift
    _inst_mode="full"
    case "${1:-}" in
      --agents) _inst_mode="agents" ;;
      ""|--full) _inst_mode="full" ;;
      *) printf 'Usage: doey install [--agents]\n' >&2; exit 2 ;;
    esac
    if [ "$_inst_mode" = "agents" ]; then
      _doey_install_agents_only
      exit $?
    fi
    update_system
    exit 0
    ;;
```

And a new function in `shell/doey-update.sh` (sibling to `check_agent_freshness`):

```bash
# Copy agent files only. Idempotent. Exits 0 on success, 1 on failure.
# Runs expand-templates.sh THEN copies agents/*.md to ~/.claude/agents/.
# Does not touch config, hooks, skills, CLI binaries, or state other
# than ~/.claude/doey/agents.hash.
_doey_install_agents_only() {
  local repo_dir
  repo_dir="$(cat "$HOME/.claude/doey/repo-path" 2>/dev/null || true)"
  if [ -z "$repo_dir" ] || [ ! -d "$repo_dir/agents" ]; then
    printf 'Error: repo path not registered or agents/ missing\n' >&2
    printf '       Run: doey update\n' >&2
    return 1
  fi
  mkdir -p "$HOME/.claude/agents"
  if [ -x "$repo_dir/shell/expand-templates.sh" ]; then
    if ! bash "$repo_dir/shell/expand-templates.sh"; then
      printf 'Error: template expansion failed — see errors above\n' >&2
      return 1
    fi
  fi
  local src _copied=0 f
  src="$repo_dir/agents"
  shopt -s nullglob
  for f in "$src"/*.md; do
    [ -f "$f" ] || continue
    cp "$f" "$HOME/.claude/agents/" && _copied=$((_copied + 1))
  done
  shopt -u nullglob
  if [ "$_copied" -eq 0 ]; then
    printf 'Error: no agent .md files found in %s/\n' "$src" >&2
    return 1
  fi
  bash -c "cat $HOME/.claude/agents/doey-*.md 2>/dev/null" | _freshness_hash \
    > "$HOME/.claude/doey/agents.hash"
  printf '  ✓ Installed %d agent definitions to ~/.claude/agents/\n' "$_copied"
}
```

- Idempotent: `cp` over existing files, same hash written, no prompts.
- Does NOT touch `~/.claude/settings.json` (fresh-install invariant preserved).
- Uses `_freshness_hash` already in the same file.
- Surfaces template expansion errors loudly (unlike `install.sh:340` which swallows them).

### 5c. Doctor check upgrade

**File:** `shell/doey-doctor.sh`
**Location:** replace the single-file probe loop in lines 240-246 with a rollup check.

**Sketch:** replace

```bash
  for _f in "$HOME/.claude/agents/doey-subtaskmaster.md:Agents" \
            "$_doey_repo/.claude/skills/doey-dispatch/SKILL.md:Skills" \
            "$HOME/.local/bin/doey:CLI"; do
    _label="${_f##*:}"; _f="${_f%:*}"
    if [[ -f "$_f" ]]; then _doc_check ok "$_label installed" "${_f/#$HOME/~}"
    else _doc_check fail "$_label missing" "${_f/#$HOME/~}"; fi
  done
```

with

```bash
  # Agents — check the required set, not just one file.
  local _required_agents="doey-boss doey-taskmaster doey-task-reviewer doey-deployment doey-doey-expert doey-subtaskmaster doey-worker doey-worker-deep doey-worker-quick doey-worker-research doey-freelancer"
  local _agents_total=0 _agents_present=0 _agents_missing="" _a
  for _a in $_required_agents; do
    _agents_total=$((_agents_total + 1))
    if [ -f "$HOME/.claude/agents/${_a}.md" ]; then
      _agents_present=$((_agents_present + 1))
    else
      _agents_missing="${_agents_missing:+${_agents_missing}, }${_a}"
    fi
  done
  if [ "$_agents_present" -eq "$_agents_total" ]; then
    _doc_check ok "Agents installed" "${_agents_present}/${_agents_total} present"
  elif [ "$_agents_present" -eq 0 ]; then
    _doc_check fail "Agents installed" "0/${_agents_total} — run: doey install --agents"
  else
    _doc_check fail "Agents installed" "${_agents_present}/${_agents_total} — missing: ${_agents_missing}"
  fi

  # Skills & CLI (unchanged)
  for _f in "$_doey_repo/.claude/skills/doey-dispatch/SKILL.md:Skills" \
            "$HOME/.local/bin/doey:CLI"; do
    _label="${_f##*:}"; _f="${_f%:*}"
    if [[ -f "$_f" ]]; then _doc_check ok "$_label installed" "${_f/#$HOME/~}"
    else _doc_check fail "$_label missing" "${_f/#$HOME/~}"; fi
  done
```

- Text: `Agents installed    26/26 present` or `Agents installed    3/11 — missing: doey-worker, doey-worker-deep, doey-freelancer, ...`
- Uses existing `_doc_check` helper; wires into the 2/6 "Installation" step already printing.
- Bash 3.2: space-separated string iteration, no associative arrays.

## 6. Risks / edge cases

1. **Symlinked install (dev mode)** — The dev repo has `~/.local/share/doey/teams/` populated by install; `~/.claude/agents/` is populated by `cp`, not a symlink. `doey install --agents` should re-`cp` safely over existing content. Verified by the existing manifest: `install.sh:27-33 clean_orphans` + plain `cp` — no symlink handling needed.
2. **Dev running from repo** — `repo-path` is saved to `~/.claude/doey/repo-path` (install.sh:327). `_doey_install_agents_only` reads that. Fallback: if path is `/tmp/*` or `/var/folders/*`, install.sh refuses to save it (line 325-327). In that edge, the new `_doey_install_agents_only` should print a clear error pointing at `doey update`.
3. **Permissions** — user owns `~/.claude/agents/` normally. If not, the preflight catches it (files missing) and the repair emits a `cp` error — we should let `cp`'s stderr through (no `2>/dev/null`) so the user sees permission denied.
4. **Race with running Doey session** — Agents are read by Claude Code only at pane launch; overwriting `*.md` during a live session is safe for *new* workers spawned after the overwrite. No file locking required. Existing workers don't re-read their agent file.
5. **`doey-masterplanner.md` divergence** — `doey-roles.sh:36` declares `DOEY_ROLE_FILE_PLANNER="doey-masterplanner"` but the repo has `doey-planner.md`/`.tmpl`, not `doey-masterplanner.md`. Any call site that references the PLANNER constant by file name would fail. Worth verifying in Phase 2 whether this is a latent bug or the constant is unused in the spawn path. (Quick grep: only `doey-roles.sh` and template files appear to use `DOEY_ROLE_FILE_PLANNER` as a string — likely unused by `--agent` flags today.) **Keep out of scope for this task; note for a follow-up.**
6. **Partial template expansion** — after the fix, `_doey_install_agents_only` runs `expand-templates.sh` without error suppression. If a template is broken, `doey install --agents` fails loudly. That's correct behavior, but it means the preflight guard (which just checks file presence) and the repair command (which enforces expansion success) have different gate semantics. Acceptable.
7. **`generate_team_agent` silent skip** (F7 in §3) — technically out of scope for the 3 deliverables, but leaving it unfixed means a half-installed agents dir still launches team windows with broken `--agent tN-...` references. Suggest a 1-line hardening in Phase 2: return non-zero from `generate_team_agent` when `src` is missing, and have callers fail-fast.
8. **Install-time freshness hash is misleading** — as noted in §2, `agents.hash` does not encode *completeness*, only byte-identity of whatever was there at install time. After the fix set lands, the hash becomes less critical (preflight + doctor check cover absence) but it should probably be augmented to also record the required-agents count, so "Agent freshness" warnings in doctor are accurate. **Out of scope.**

## 7. Out of scope (defer to follow-up tasks)

- Silent `generate_team_agent` skip (§6.7). Follow-up: "Fail fast when base agent missing during team spawn".
- `doey-masterplanner` vs `doey-planner` naming divergence in `doey-roles.sh`. Follow-up: "Reconcile PLANNER role file constant".
- Install-time `>/dev/null 2>&1` on `expand-templates.sh`. Follow-up: "Surface install-time template errors" (should strip `>/dev/null 2>&1 || true` and let `set -e` die loudly — intertwined with this research's fix 5a so could be bundled).
- Parallel preflight for skills (`.claude/skills/` — project-level; never "missing" in a repo-shipped context) and hooks (`~/.config/doey/config.sh` is optional). Skills are loaded on-demand so absence ≠ session-broken. Hooks live in-repo, not in `~/.claude/`. Both are lower risk than agents. Only flag if Phase 2 proves otherwise.
- `doey agents check` subcommand (`shell/doey-agents.sh`) already does a thorough 3-layer drift inventory. It is NOT wired into launch or doctor. Follow-up could consolidate: make the doctor check call `doey_agents_check --quiet` instead of reimplementing. For this task, the inline rollup in 5c is simpler and keeps doctor independent of the agents-check infra.
