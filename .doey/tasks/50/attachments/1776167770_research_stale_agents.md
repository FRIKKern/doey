# Research: Stale Agent Detection

**Task:** 50 | **Date:** 2026-04-14 | **Author:** Worker d-t4-w1

---

## Summary

Agents are installed by `install.sh` (step 2/7) via `install_md_files()` which copies all `agents/*.md` to `~/.claude/agents/`. Template expansion (`expand-templates.sh`) runs **before** the copy, generating `.md` from `.md.tmpl` files in the repo. There are currently **38 agent files** and **38 matching templates**. A version file (`~/.claude/doey/version`) already records the git commit hash at install time. The recommended detection strategy is a **manifest hash** baked at install time and checked at startup, which is the only approach that correctly handles template expansion and achieves sub-100ms latency.

---

## Findings

### 1. Agent Install Flow

**File:** `install.sh:314-321`

```bash
# Expand role templates before installing agents
if [ -x "$SCRIPT_DIR/shell/expand-templates.sh" ]; then
  bash "$SCRIPT_DIR/shell/expand-templates.sh" >/dev/null 2>&1 || true
fi

install_md_files "$SCRIPT_DIR/agents" ~/.claude/agents "2/7" "agent definitions"
```

**Sequence:**
1. `expand-templates.sh` runs first (line 315-317), converting all `agents/*.md.tmpl` -> `agents/*.md` using `DOEY_ROLE_*` and `DOEY_CATEGORY_*` env var substitutions + `{{include:<name>}}` fragment inlining
2. `install_md_files()` (line 36-46) copies all `agents/*.md` files to `~/.claude/agents/`
3. `clean_orphans()` (line 27-33) removes any `doey-*.md` files in the destination that don't exist in the source

**Other files installed by install.sh:**
- Shell scripts to `~/.local/bin/` (step 5/7, lines 354-393) — ~30+ scripts
- Team definitions to `~/.local/share/doey/teams/` (step 3/7, lines 323-335)
- Skills are project-level (`.claude/skills/`) — counted but not copied (step 4/7)
- Version file to `~/.claude/doey/version` (lines 306-312)
- Repo path to `~/.claude/doey/repo-path` (lines 301-304)
- Default config to `~/.config/doey/config.sh` (lines 397-400, only if missing)
- Go binaries built from `tui/` (step 6/7)

### 2. Current Update/Upgrade Behavior

**File:** `shell/doey-update.sh` (sourced by `shell/doey.sh:64`)

**Subcommand:** `doey update` (alias: `doey reinstall`) — `shell/doey.sh:259-266`

Two paths:
- **Contributor path** (`_update_contributor`, line 64): `git pull --ff-only` on repo dir, then re-exec and run `install.sh`
- **Normal user path** (`_update_normal`, line 169): `git clone --depth 1` to temp dir, run `install.sh`

**Auto-update check:** `check_for_updates()` at `doey-update.sh:622-658`
- Runs on every smart launch (`doey.sh:674`)
- Checks `~/.claude/doey/last-update-check` timestamp (24h cache)
- Background `git fetch` + `rev-list --count HEAD..origin/main`
- Caches result in `~/.claude/doey/last-update-check.available`
- Shows warning if behind: "Update available (N commit(s) behind)"

**Key insight:** `check_for_updates()` already runs at exactly the right place in the startup flow and is non-blocking (background fetch). A stale-agent check could live adjacent to or within this function.

### 3. Detection Strategy Analysis

#### 3a. Checksums (md5/sha256 of installed vs repo files)

**Approach:** Hash each `~/.claude/agents/doey-*.md` and compare to repo `agents/*.md`.

**Pros:**
- Content-accurate — detects any divergence
- Simple implementation

**Cons:**
- **Cannot compare repo source directly** — repo has `.md.tmpl` files, installed files are expanded output. Would need to run `expand-templates.sh` first (~200ms for sed + awk on 38 files), which defeats the speed goal
- Requires iterating 38 files and computing hashes — estimated 50-80ms on macOS (md5 is ~1ms/file for small files)
- If user manually edits an installed agent, it would flag as stale (false positive)

**Verdict:** Only works if you compare against expanded output, but that requires running `expand-templates.sh` at startup which is too slow.

#### 3b. Timestamps (mtime comparison)

**Approach:** Compare mtime of installed files vs repo files.

**Pros:**
- Very fast — `stat` is sub-millisecond per file

**Cons:**
- **Template expansion changes mtime** — `expand-templates.sh` generates `.md` files from `.md.tmpl`, so the `.md` files in the repo have volatile mtimes that change on every expansion
- `git clone` and `git pull` change mtimes
- `cp` in `install_md_files()` sets mtime to copy time, not source time
- Completely unreliable for this use case

**Verdict:** Unusable.

#### 3c. Version Hash Manifest

**Approach:** At install time, compute a composite hash of all installed agent content and write it to a manifest file. At startup, re-read installed agents and compare hash.

**Pros:**
- **Sub-5ms** — read one small file, compare one string
- Handles template expansion correctly (hash is computed after expansion + copy)
- No dependency on repo directory at startup
- Can extend to cover shell scripts, skills, etc.

**Cons:**
- Requires `install.sh` to write the manifest (one-line addition)
- If user manually edits an installed agent, it would flag as stale (same as checksums — but this is actually correct behavior since we want to detect drift)

**Better variant — git commit hash comparison:**
- The version file (`~/.claude/doey/version`) already stores the install-time git commit hash
- At startup, compare `version=` in the version file against `git rev-parse --short HEAD` of the repo
- If they differ, agents (and everything else) may be stale
- **Cost:** One `cat` + one `git rev-parse` = ~10-20ms
- **Already partially implemented:** `check_for_updates()` does exactly this via `git fetch` + `rev-list`

**Verdict: RECOMMENDED.** Two sub-options:
- **Option A (fast, ~5ms):** Composite content hash in manifest, check at startup
- **Option B (simpler, ~15ms):** Compare version file commit hash to repo HEAD — if different, show warning. This is essentially what `check_for_updates` already does, but local-only (no network fetch needed).

### 4. Startup Flow

**File:** `shell/doey.sh`

```
Line 1-28:   Header comments
Line 30-89:  Source all module files (doey-helpers, doey-update, doey-doctor, etc.)
Line 92:     _doey_load_config
Line 94-112: Default config variables
Line 133:    __doey_source_only guard (for test sourcing)
Line 135:    grid="dynamic" default
Line 139-148: Parse global flags (--quick, --no-wizard)
Line 150-669: Case statement — subcommand dispatch
Line 671:    # ── Smart Launch ──
Line 673:    _check_prereqs          <-- prereq check
Line 674:    check_for_updates       <-- EXISTING update check (this is the insertion point)
Line 676-689: find project, launch/attach
```

**Recommended insertion point:** Between `_check_prereqs` (line 673) and `check_for_updates` (line 674), OR as a fast check inside `check_for_updates()` itself (lines 622-658 in `doey-update.sh`).

**Function:** `check_for_updates()` at `doey-update.sh:622`

This function already:
1. Reads `~/.claude/doey/repo-path`
2. Checks if repo `.git` exists
3. Does a background git fetch
4. Caches results

A stale-agent check could be added as a **fast local-only check** at the top of this function, before the network fetch. The local check runs synchronously (~10ms), the fetch stays async.

### 5. Template Expansion

**File:** `shell/expand-templates.sh`

**Key facts:**
- Every agent `.md` file has a corresponding `.md.tmpl` file (38 of each)
- Templates use `{{DOEY_ROLE_*}}` and `{{DOEY_CATEGORY_*}}` placeholders
- Templates use `{{include:<name>}}` for fragment inlining from `agents/_fragments/`
- Expansion is run by `install.sh` (line 315-317) before copying agents
- The generated `.md` files are checked into git (they're generated but committed)
- `expand-templates.sh --check` can verify if templates are up to date (line 82-95)

**Impact on detection:**
- Since generated `.md` files are committed to git, the git commit hash inherently reflects the expanded state
- Comparing installed files to repo `.md` files works (not `.md.tmpl`)
- But after a `git pull`, the `.md` files in the repo might be stale if someone forgot to run `expand-templates.sh` before committing — this is already guarded by a pre-commit hook

**Conclusion:** Comparing repo `agents/*.md` to installed `~/.claude/agents/doey-*.md` is valid because the `.md` files are committed. The version hash approach (Option B) sidesteps this entirely.

### 6. doey doctor

**File:** `shell/doey-doctor.sh`

**Current checks (relevant):**
- Line 234-239: Checks if `doey-subtaskmaster.md` exists in `~/.claude/agents/` (basic existence only)
- Line 322-342: Checks Go binary freshness via `_go_binary_stale()` (compares binary mtime to source dir mtime)
- Line 283-288: Checks version file existence

**No agent freshness check exists.** The doctor checks:
- Agent existence (one file only)
- Go binary staleness (mtime-based)
- Version file existence

**Where a staleness check fits in doctor:**
After the "Installed files" section (line 234-239), add an agent freshness check. Could reuse the same manifest/hash mechanism from the startup check. Approximately at line 242 (after the agents/skills/CLI existence checks).

---

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `install.sh` | 314-321 | Agent install flow (expand + copy) |
| `install.sh` | 306-312 | Version file write |
| `install.sh` | 36-46 | `install_md_files()` — generic copy + orphan clean |
| `shell/doey.sh` | 671-674 | Smart Launch — startup flow, insertion point |
| `shell/doey-update.sh` | 622-658 | `check_for_updates()` — existing auto-update check |
| `shell/doey-update.sh` | 231-241 | `update_system()` — dispatches contributor vs normal |
| `shell/expand-templates.sh` | 76-109 | Template expansion loop |
| `shell/doey-doctor.sh` | 167-482 | `check_doctor()` — health check (no agent freshness) |
| `shell/doey-doctor.sh` | 234-239 | Agent existence check (single file) |
| `shell/doey-doctor.sh` | 322-342 | Go binary staleness check (model for agents) |
| `~/.claude/doey/version` | — | Installed version: `version=874bcd3`, `date=...`, `repo=...` |

---

## Implementation Plan

### Option A: Manifest Hash (RECOMMENDED)

**Speed:** ~5ms at startup. **Accuracy:** Exact content match. **Complexity:** Low.

#### Step 1: Write manifest at install time (`install.sh`)

After `install_md_files` (line 319), compute a composite hash of all installed agents:

```bash
# After install_md_files "$SCRIPT_DIR/agents" ~/.claude/agents "2/7" "agent definitions"
# Write agent manifest hash
(cd ~/.claude/agents && cat doey-*.md 2>/dev/null | md5 -q) > ~/.claude/doey/agents.hash
```

Also hash shell scripts:

```bash
(cd ~/.local/bin && cat doey*.sh doey 2>/dev/null | md5 -q) > ~/.claude/doey/shell.hash
```

#### Step 2: Check at startup (`shell/doey-update.sh`, inside or adjacent to `check_for_updates`)

```bash
check_agent_freshness() {
  local hash_file="$HOME/.claude/doey/agents.hash"
  [ -f "$hash_file" ] || return 0  # No manifest = skip (pre-manifest install)
  local installed_hash current_hash
  installed_hash="$(cat "$hash_file")"
  current_hash="$(cd ~/.claude/agents && cat doey-*.md 2>/dev/null | md5 -q)"
  if [ "$installed_hash" != "$current_hash" ]; then
    printf "  ${WARN}Warning:${RESET} Installed agents differ from install manifest\n"
    printf "  ${DIM}Run: doey update${RESET}\n"
  fi
}
```

Call from `doey.sh` at line 674 area.

#### Step 3: Add to `doey doctor` (`shell/doey-doctor.sh`)

After line 239, add:

```bash
# Agent freshness
local _agent_hash_file="$HOME/.claude/doey/agents.hash"
if [[ -f "$_agent_hash_file" ]]; then
  local _installed_hash _current_hash
  _installed_hash="$(cat "$_agent_hash_file")"
  _current_hash="$(cd ~/.claude/agents && cat doey-*.md 2>/dev/null | md5 -q)"
  if [[ "$_installed_hash" == "$_current_hash" ]]; then
    _doc_check ok "Agent freshness" "all agents match install manifest"
  else
    _doc_check warn "Agent freshness" "agents modified since install — run: doey update"
  fi
else
  _doc_check skip "Agent freshness" "no manifest (pre-manifest install)"
fi
```

### Option B: Git Commit Hash Comparison (SIMPLER)

**Speed:** ~15ms at startup. **Accuracy:** Detects any repo change (not agent-specific). **Complexity:** Minimal.

#### Implementation

In `check_for_updates()` at `doey-update.sh:622`, add a local-only fast check before the network fetch:

```bash
# Fast local staleness check (no network)
local version_file="$state_dir/version"
if [[ -f "$version_file" ]]; then
  local installed_ver repo_ver
  installed_ver=$(grep '^version=' "$version_file" | cut -d= -f2)
  repo_ver=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)
  if [[ -n "$repo_ver" ]] && [[ "$installed_ver" != "$repo_ver" ]]; then
    printf "  ${WARN}Stale install${RESET} ${DIM}(installed %s, repo at %s — run: doey update)${RESET}\n" \
      "$installed_ver" "$repo_ver"
  fi
fi
```

**Pros:** Almost zero new code. Works for everything (agents, scripts, all installed files).
**Cons:** Doesn't detect if installed files were manually edited. Over-reports (any repo commit, even non-agent changes, triggers warning).

---

## Recommendation

**Use Option A (manifest hash)** for the following reasons:
1. It detects actual content drift, not just version mismatch
2. It's faster (~5ms vs ~15ms)
3. It can be extended to cover shell scripts independently
4. It doesn't over-report (only triggers when agents actually differ)
5. It works even without a repo dir (normal user installs from temp dir)

Combine with Option B as a secondary check in `doey doctor` for comprehensive coverage.

---

## Risks

1. **`md5` command portability**: macOS uses `md5 -q`, Linux uses `md5sum | cut -d' ' -f1`. Must handle both. Alternative: use `shasum -a 256` which exists on both.
2. **Glob expansion in zsh**: `cat doey-*.md` in zsh with `nomatch` set will error if no files match. Must use `bash -c '...'` or `2>/dev/null` guard per CLAUDE.md.
3. **Pre-manifest installs**: Users who installed before the manifest feature exists won't have the hash file. Must degrade gracefully (skip check, not error).
4. **Manual agent edits**: If a user intentionally edits `~/.claude/agents/doey-*.md`, the check will warn. This is acceptable — manual edits are unsupported and will be overwritten by `doey update` anyway.
5. **install.sh ordering**: The hash must be written AFTER `install_md_files` copies files, not before. Current placement (line 319) is correct insertion point.

---

## Dispatch-Ready Implementation Prompts

### Worker Prompt: Implement manifest hash (Option A)

> **Task:** Implement agent staleness detection via install-time manifest hash.
>
> **Changes required (3 files):**
>
> 1. **`/Users/frikk.jarl/Documents/GitHub/doey/install.sh`** — After line 321 (`for f in "${_files[@]}"; do detail "$(basename "$f" .md)"; done`), add manifest hash generation. Use `shasum -a 256` for portability. Write hash to `~/.claude/doey/agents.hash`. Also write `~/.claude/doey/shell.hash` after shell script installation (after line 393).
>
> 2. **`/Users/frikk.jarl/Documents/GitHub/doey/shell/doey-update.sh`** — Add function `check_agent_freshness()` before `check_for_updates()` (before line 622). Function reads `~/.claude/doey/agents.hash`, computes current hash of `~/.claude/agents/doey-*.md`, compares. Prints warning if different. Graceful skip if no hash file. Must be portable (macOS `shasum` vs Linux `sha256sum` — use `shasum -a 256` which works on both). Call it from `doey.sh` at line 674 area.
>
> 3. **`/Users/frikk.jarl/Documents/GitHub/doey/shell/doey-doctor.sh`** — After line 239 (agent existence check), add agent freshness check using same hash comparison. Use `_doc_check ok/warn/skip` pattern.
>
> **Constraints:** Bash 3.2 compatible. No `declare -A`. Use `shasum -a 256` not `md5`. Glob must be zsh-safe (wrap in `bash -c '...'` if needed). Total startup cost must be <10ms.

### Worker Prompt: Implement version comparison (Option B)

> **Task:** Add local repo-vs-install version comparison to startup.
>
> **Changes required (2 files):**
>
> 1. **`/Users/frikk.jarl/Documents/GitHub/doey/shell/doey-update.sh`** — At the top of `check_for_updates()` (line 622), after reading `repo_dir`, add a fast local check: read `version=` from `~/.claude/doey/version`, compare to `git -C "$repo_dir" rev-parse --short HEAD`. If different, print one-line warning. Must not block (no network). ~15ms budget.
>
> 2. **`/Users/frikk.jarl/Documents/GitHub/doey/shell/doey-doctor.sh`** — After line 288 (version file check), add a version-vs-repo comparison check. Use `_doc_check` pattern.
>
> **Constraints:** Bash 3.2 compatible. Graceful if version file or repo-path missing. No new dependencies.
